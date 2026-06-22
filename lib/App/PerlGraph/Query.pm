package App::PerlGraph::Query;
use v5.36;
our $VERSION = q{0.047};
use Moo;
use App::PerlGraph::Model qw(package_of is_public);

# Read-only graph queries over a Store. Symbols may be bare names ('run') or
# qualified ('Foo::run').
has store => (is => 'ro', required => 1);

sub _defs ($self, $symbol) {
    my $s = $self->store;
    return $symbol =~ /::/ ? $s->nodes_by_qname($symbol) : $s->nodes_by_name($symbol);
}

sub search ($self, $query, $limit = 50) { $self->store->search($query, $limit) }

# Semantic search: rank symbols by embedding similarity to the query (meaning, not
# keyword). Needs embeddings (`pcg index --embed`) and a local provider to embed the
# query. Returns { results => [nodes+_score] } or { error => ... } so the caller can
# explain the missing piece and fall back to keyword search.
sub semantic ($self, $query, $limit = 20) {
    require App::PerlGraph::Embed;
    my $s = $self->store;
    my %emb = $s->all_embeddings;
    return { error => 'no_embeddings' } unless %emb;          # never ran `index --embed`
    my $qv = App::PerlGraph::Embed->embed([$query]);
    return { error => 'no_provider' } unless $qv && @$qv;     # can't embed the query right now
    $qv = $qv->[0];
    my @ranked = sort { $b->{score} <=> $a->{score} || $a->{id} cmp $b->{id} }   # id tie-break -> reproducible across runs/platforms
                 map  { +{ id => $_, score => App::PerlGraph::Embed::dot($qv, $emb{$_}) } } keys %emb;
    @ranked = @ranked[0 .. $limit - 1] if @ranked > $limit;
    return { results => [ map { my $n = $s->node($_->{id}); $n ? { %$n, _score => $_->{score} } : () } @ranked ] };
}

sub callees ($self, $symbol) {
    my $s = $self->store;
    my @out;
    for my $def ($self->_defs($symbol)) {
        for my $e ($s->outgoing_edges($def->{id}, 'calls')) {
            next unless $e->{target};
            my $t = $s->node($e->{target}) or next;
            $t->{_provenance} = $e->{provenance};
            push @out, $t;
        }
    }
    return @out;
}

sub callers ($self, $symbol) {
    my $s = $self->store;
    my @out;
    for my $def ($self->_defs($symbol)) {
        for my $e ($s->incoming_edges($def->{id}, 'calls')) {
            my $f = $s->node($e->{source}) or next;
            $f->{_provenance} = $e->{provenance};
            push @out, $f;
        }
    }
    return @out;
}

sub impact ($self, $symbol, $depth = 5) {
    my $s = $self->store;
    my %seen;
    my @q = map { $_->{id} } $self->_defs($symbol);
    my @result;
    while (@q && $depth-- > 0) {
        my @next;
        for my $id (@q) {
            for my $e ($s->incoming_edges($id, 'calls', 'references')) {
                next if $seen{ $e->{source} }++;
                my $n = $s->node($e->{source}) or next;
                $n->{_provenance} = $e->{provenance};
                push @result, $n;
                push @next, $e->{source};
            }
        }
        @q = @next;
    }
    return @result;
}

# Shortest call path from $from to $to: a forward BFS over calls/references
# edges, seeded from every node matching $from, stopping at the first node
# matching $to. Returns the node chain [from .. to] (each hop past the first
# tagged with _via, the edge kind that reached it) or an empty list if $to is
# unreachable. Mirrors impact(), which walks the same edges in reverse.
sub path ($self, $from, $to) {
    my $s = $self->store;
    my %target = map { $_->{id} => 1 } $self->_defs($to);
    my @starts = $self->_defs($from);
    return () unless %target && @starts;

    my (%seen, %prev, %via);
    for my $n (@starts) {
        return ($n) if $target{ $n->{id} };   # a symbol trivially reaches itself
        $seen{ $n->{id} } = 1;
    }
    my @q = sort keys %seen;   # stable seed order -> deterministic chain among equal-length ties
    my $hit;
    BFS: while (@q) {
        my @next;
        for my $id (@q) {
            for my $e ($s->outgoing_edges($id, 'calls', 'references')) {
                my $t = $e->{target} // next;
                next if $seen{$t}++;
                $prev{$t} = $id; $via{$t} = $e->{kind};
                if ($target{$t}) { $hit = $t; last BFS }
                push @next, $t;
            }
        }
        @q = @next;
    }
    return () unless defined $hit;

    my @ids = ($hit);
    unshift @ids, $prev{ $ids[0] } while defined $prev{ $ids[0] };
    return map { my $n = $s->node($_); $n->{_via} = $via{$_} if $via{$_}; $n } @ids;
}

# The call graph as { nodes => [...], edges => [...] } for export/visualization.
# Nodes are function/method/package/class/route (never `file`); edges are the
# meaningful relations calls/references/extends (structural `contains` is noise).
# With around => SYM, BFS-bounds to radius depth (default 2) in BOTH directions.
my @GRAPH_EDGES = qw(calls references extends);
sub graph ($self, %opt) {
    my $s = $self->store;
    my %keep;
    if (defined $opt{around}) {
        my $depth = $opt{depth} // 2;
        my @frontier = map { $_->{id} } $self->_defs($opt{around});
        return { nodes => [], edges => [] } unless @frontier;
        my %seen = map { $_ => 1 } @frontier;
        for (1 .. $depth) {
            my @next;
            for my $id (@frontier) {
                push @next, grep { !$seen{$_}++ }
                    map { $_->{target} // () } $s->outgoing_edges($id, @GRAPH_EDGES);
                push @next, grep { !$seen{$_}++ }
                    map { $_->{source} } $s->incoming_edges($id, @GRAPH_EDGES);
            }
            @frontier = @next;
        }
        for my $id (keys %seen) {
            my $n = $s->node($id);
            $keep{$id} = $n if $n && ($n->{kind} // '') ne 'file';
        }
    }
    else {
        %keep = map { ($_->{id} => $_) } $s->all_nodes(qw(function method package class route constant));
    }
    my @edges;
    for my $id (keys %keep) {
        for my $e ($s->outgoing_edges($id, @GRAPH_EDGES)) {
            next unless defined $e->{target} && $keep{ $e->{target} };
            push @edges, { from => $id, to => $e->{target}, kind => $e->{kind}, provenance => $e->{provenance} };
        }
    }
    # Stable edge order (by endpoint name, then kind) -> diff-friendly export output.
    my %name = map { ($_->{id} => ($_->{qualified_name} // $_->{name} // '')) } values %keep;
    @edges = sort { $name{ $a->{from} } cmp $name{ $b->{from} }
                 || $name{ $a->{to} }   cmp $name{ $b->{to} }
                 || ($a->{kind} // '')  cmp ($b->{kind} // '') } @edges;
    return { nodes => [ values %keep ], edges => \@edges };
}

# A "view" of a node: the node plus its immediate callers and callees, for the
# source-bearing node/explore commands.
sub _view ($self, $node) {
    my $qn = $node->{qualified_name};
    return {
        node    => $node,
        callers => [ defined $qn ? $self->callers($qn) : () ],
        callees => [ defined $qn ? $self->callees($qn) : () ],
    };
}

# Files affected by changing @$files: the transitive reverse closure (who
# calls/references symbols in those files), as a set of file paths. With
# tests_only, restricted to .t files -- i.e. which tests to re-run for a change.
sub affected ($self, $files, %opt) {
    my $s = $self->store;
    my @allpaths = $s->file_paths;
    my %changed;
    for my $c (@$files) {
        (my $cn = $c) =~ s{^\./}{};
        next unless length $cn;
        $changed{$_} = 1 for grep { $_ eq $c || m{(?:\A|/)\Q$cn\E\z} } @allpaths;
    }
    my (%seen, %afile, @queue);
    for my $p (keys %changed) {
        $afile{$p} = 1;
        push @queue, map { $_->{id} } grep { !$seen{$_->{id}}++ } $s->nodes_in_file($p);
    }
    my $depth = $opt{depth} // 25;
    while (@queue && $depth-- > 0) {
        my @next;
        for my $id (@queue) {
            for my $e ($s->incoming_edges($id, 'calls', 'references')) {
                next if $seen{ $e->{source} }++;
                my $src = $s->node($e->{source}) or next;
                $afile{ $src->{file_path} } = 1 if defined $src->{file_path};
                push @next, $e->{source};
            }
        }
        @queue = @next;
    }
    my @out = sort keys %afile;
    @out = grep { /\.t\z/ } @out if $opt{tests_only};
    return @out;
}

# Subs that nothing in the indexed code references -- dead-code candidates.
# Beyond having no inbound call/reference edge, two filters keep precision high:
# lifecycle/magic names are skipped, and any sub whose short name is invoked
# dynamically is spared -- `$obj->name` can't resolve to an edge but leaves an
# unresolved method_call ref of that name, so we treat the name as "in use".
# %opt: all => also include exported + lifecycle subs.
my %LIFECYCLE = map { $_ => 1 }
    qw(new import unimport BUILD BUILDARGS DEMOLISH DESTROY AUTOLOAD CLONE meta);
sub unused ($self, %opt) {
    my $s = $self->store;
    my %dynamic = map { $_ => 1 } $s->unresolved_ref_names;
    my @out;
    for my $n ($s->unreferenced_functions($opt{all})) {
        my $name = $n->{name} // '';
        next if ($n->{metadata} // {})->{cpan};   # an indexed dependency isn't your dead code
        # Moo/Moose lazy builders (_build_<attr>) are invoked by the framework.
        next if !$opt{all} && ($LIFECYCLE{$name} || $name =~ /^_build_/);
        next if $dynamic{$name};
        push @out, $n;
    }
    return @out;
}

# Call-graph hotspots, for review/refactor triage:
#  - fan_in:   most depended-upon symbols (direct callers), each annotated with its
#              transitive blast radius (reverse-reachable callers) computed for the
#              shown rows only -- cheap, and ranks true risk above raw fan-in.
#  - fan_out:  most complex symbols (most outbound calls).
#  - packages: most efferently-coupled modules (depend on the most other modules).
# Over-fetch the call lists then filter to callables (a `references` target can
# occasionally be a non-callable node).
sub hotspots ($self, %opt) {
    my $limit = $opt{limit} // 15;
    my $s = $self->store;
    my $rows_to_nodes = sub ($rows) {
        my @out;
        for my $r (@$rows) {
            my $n = $s->node($r->{id}) or next;
            next unless ($n->{kind} // '') =~ /\A(?:function|method|constant)\z/;
            push @out, { node => $n, count => $r->{n} };
            last if @out >= $limit;
        }
        return \@out;
    };
    my $fan_in = $rows_to_nodes->([ $s->top_fan_in($limit * 3) ]);
    for my $r (@$fan_in) {   # blast radius for the shown rows only (K bounded reverse-BFS runs)
        my $qn = $r->{node}{qualified_name} // $r->{node}{name};
        $r->{impact} = defined $qn ? scalar($self->impact($qn, 50)) : $r->{count};
    }
    my @coupled = sort { keys(%{ $b->{deps} }) <=> keys(%{ $a->{deps} }) || $a->{module} cmp $b->{module} }
                  grep { %{ $_->{deps} } } $self->deps;
    @coupled = @coupled[0 .. $limit - 1] if @coupled > $limit;
    return {
        fan_in   => $fan_in,
        fan_out  => $rows_to_nodes->([ $s->top_fan_out($limit * 3) ]),
        packages => [ map { { module => $_->{module}, count => scalar keys %{ $_->{deps} } } } @coupled ],
        complex  => [ map { { node => $_, cx => $_->{metadata}{complexity} } } $s->top_complex($limit) ],
    };
}

# Security sinks (command / SQL execution) and which web endpoints can reach them.
# A route's handler -> forward call closure; any reached sub with a sink edge is on
# that endpoint's attack surface. Heuristic by call name -- a placeholdered DBI call
# is safe -- so a hit is a site to VERIFY, not a confirmed bug.
sub sinks ($self, %opt) {
    my $s = $self->store;
    my %by_sub;   # sub id -> { "type:name" => {type,name,dynamic} }
    for my $e ($s->edges_of_kind('sink')) {
        next unless defined $e->{source};
        my $m = $e->{metadata} // {};
        my $slot = $by_sub{ $e->{source} }{ "$m->{sink}:$m->{name}" }
            //= { type => $m->{sink} // '?', name => $m->{name} // '?', dynamic => 0 };
        $slot->{dynamic} ||= $m->{dynamic} ? 1 : 0;   # any dynamically-built call of this name -> flag the site
    }
    my @sites = map { my $n = $s->node($_); $n ? { sub => $n->{qualified_name} // $n->{name} // '?',
                                                   sinks => [ values %{ $by_sub{$_} } ] } : () }
                sort keys %by_sub;

    my @reachable;
    for my $route ($s->all_nodes('route')) {
        my ($he) = grep { (($_->{metadata} // {})->{via} // '') eq 'route' } $s->outgoing_edges($route->{id}, 'references');
        next unless $he && $he->{target};
        my %seen = ($he->{target} => 1); my @q = ($he->{target}); my @hit; my $depth = 40;
        while (@q && $depth-- > 0) {
            my @next;
            for my $id (@q) {
                if ($by_sub{$id}) {
                    my $n = $s->node($id);
                    push @hit, map { { %$_, sub => ($n->{qualified_name} // $n->{name} // '?') } } values %{ $by_sub{$id} };
                }
                for my $e ($s->outgoing_edges($id, 'calls', 'references')) {
                    push @next, $e->{target} if $e->{target} && !$seen{ $e->{target} }++;
                }
            }
            @q = @next;
        }
        push @reachable, { route => $route, sinks => \@hit } if @hit;
    }
    return { reachable => \@reachable, sites => \@sites };
}

# A codebase orientation map for first contact with an unfamiliar project: scale,
# frameworks, entry-point scripts, the most central symbols (highest fan-in), the
# namespace breakdown, and the most-subclassed classes -- one call for "the lay of
# the land", composed from the centrality data the graph already holds.
sub overview ($self, %opt) {
    my $s = $self->store;
    my $limit = $opt{limit} // 12;
    my %kinds = $s->kind_counts;
    my ($edges)      = $s->dbh->selectrow_array('select count(*) from edges');
    my ($unresolved) = $s->dbh->selectrow_array('select count(*) from unresolved_refs');
    my $prov = $s->dbh->selectall_arrayref('select provenance, count(*) c from edges group by provenance order by c desc');

    my @scripts = sort grep { defined && /\.(?:pl|psgi)\z/ }        # executable entry points
        map { $_->{file_path} } $s->all_nodes('file');             # from file nodes (same source as the file count)

    my @central;                                                    # most depended-upon symbols
    for my $r ($s->top_fan_in($limit * 3)) {
        my $n = $s->node($r->{id}) or next;
        next unless ($n->{kind} // '') =~ /\A(?:function|method|constant)\z/;
        push @central, { node => $n, callers => $r->{n} };
        last if @central >= $limit;
    }

    my %ns;                                                         # subs grouped by top-2 namespace levels
    for my $q ($s->qnames_of('function', 'method')) {
        my @p = split /::/, $q;
        next unless @p >= 2;                                        # qname is Package::sub
        pop @p;                                                     # drop the sub -> the package
        $ns{ @p >= 2 ? "$p[0]::$p[1]" : $p[0] }++;
    }
    my @ns_top = (sort { $ns{$b} <=> $ns{$a} || $a cmp $b } keys %ns)[0 .. $limit - 1];
    my @namespaces = map { { ns => $_, subs => $ns{$_} } } grep { defined } @ns_top;

    my @inherited;                                                  # most-subclassed classes
    for my $r ($s->most_subclassed($limit)) {
        my $n = $s->node($r->{id}) or next;
        push @inherited, { node => $n, subclasses => $r->{n} };
    }

    return { kinds => \%kinds, edges => $edges, unresolved => $unresolved, prov => $prov,
             routes => ($kinds{route} // 0), scripts => \@scripts,
             central => \@central, namespaces => \@namespaces, inherited => \@inherited };
}

# LSP go-to-definition: the definition(s) a call/reference at $file line $line
# resolves to -- including through dynamic dispatch the resolver tied down.
sub definition_at ($self, $file, $line) {
    my $s = $self->store;
    my (%seen, @out);
    for my $e ($s->edges_at_source($file, $line)) {
        my $t = $s->node($e->{target}) or next;
        push @out, $t unless $seen{ $t->{id} }++;
    }
    return @out;
}

# The symbol under the cursor: a definition's own name line, else a call target on
# that line, else the enclosing sub. Backs find-references and hover.
sub symbol_at ($self, $file, $line) {
    my $s = $self->store;
    return $s->node_at_start($file, $line)
        // do { my ($e) = $s->edges_at_source($file, $line); $e ? $s->node($e->{target}) : undef }
        // $s->node_covering($file, $line);
}

# LSP find-references: every resolved call/reference site pointing at the symbol
# under the cursor. Each { file, line, col, caller }.
sub references_at ($self, $file, $line) {
    my $s = $self->store;
    my $sym = $self->symbol_at($file, $line) or return ();
    my @out;
    for my $e ($s->incoming_edges($sym->{id}, qw(calls references))) {
        my $src = $s->node($e->{source}) or next;
        push @out, { file => $src->{file_path}, line => $e->{line} // $src->{start_line},
                     col => $e->{col}, caller => $src };
    }
    return @out;
}

# History-aware risk: symbols ranked by churn (commits touching their file) x
# fan-in (how many depend on them) -- frequently-changed AND widely-depended-upon
# code is the top refactor/test target. The caller supplies the churn map (git
# file_path -> commit count), so Query stays git-agnostic and testable.
sub risk ($self, $churn, %opt) {
    my $limit = $opt{limit} // 15;
    my $s = $self->store;
    my @out;
    for my $file (keys %$churn) {
        for my $n ($s->nodes_in_file($file)) {
            next unless ($n->{kind} // '') =~ /\A(?:function|method)\z/;
            my $fan = () = $s->incoming_edges($n->{id}, 'calls', 'references');
            next unless $fan;   # only depended-upon symbols carry dependency risk
            push @out, { node => $n, churn => $churn->{$file}, fan_in => $fan, score => $churn->{$file} * $fan };
        }
    }
    @out = sort { $b->{score} <=> $a->{score}
               || ($a->{node}{qualified_name} // '') cmp ($b->{node}{qualified_name} // '') } @out;
    return @out > $limit ? @out[0 .. $limit - 1] : @out;
}

# Logical (temporal) coupling: code files that change together in git history,
# ranked by Jaccard of their commit sets (with a min support). Each pair is marked
# `linked` if the static graph already has an edge between them -- so the UNLINKED
# high-coupling pairs are the hidden dependencies the call graph can't see. Takes
# the commit transactions (each an arrayref of files), so Query stays git-agnostic.
sub cochange ($self, $transactions, %opt) {
    my $limit = $opt{limit} // 15;
    my $min   = $opt{min_support} // 3;
    my $maxf  = $opt{max_files} // 25;   # skip sweeping commits (version bumps, mass reformats) -- they couple everything spuriously
    my $code  = qr/\.(?:pm|pl|t|xs)\z/;
    my (%count, %pair);
    for my $tx (@$transactions) {
        my @f = sort grep { $_ =~ $code } @$tx;
        next if @f > $maxf;
        $count{$_}++ for @f;
        for my $i (0 .. $#f) {
            $pair{ "$f[$i]\x00$f[$_]" }++ for $i + 1 .. $#f;
        }
    }
    my @rows;
    for my $k (keys %pair) {
        my $co = $pair{$k};
        next if $co < $min;
        my ($a, $b) = split /\x00/, $k;
        push @rows, { a => $a, b => $b, support => $co, coupling => $co / ($count{$a} + $count{$b} - $co) };
    }
    @rows = sort { $b->{coupling} <=> $a->{coupling} || $b->{support} <=> $a->{support} || $a->{a} cmp $b->{a} } @rows;
    @rows = @rows[0 .. $limit - 1] if @rows > $limit;
    $_->{linked} = $self->store->files_statically_linked($_->{a}, $_->{b}) for @rows;
    return @rows;
}

# Public API symbols that no test statically reaches -- the untested public
# surface. Cheap: one forward closure from every .t file's symbols, then the
# api() surface minus what was reached. (A method exercised only via opaque
# $obj->method dispatch from a test isn't an edge, so it may surface here.)
sub untested ($self, $module = undef) {
    my $s = $self->store;
    my (%reached, @q);
    for my $f (grep { /\.t\z/ } $s->node_file_paths) {
        push @q, grep { !$reached{$_}++ } map { $_->{id} } $s->nodes_in_file($f);
    }
    my $depth = 50;
    while (@q && $depth-- > 0) {
        my @next;
        for my $id (@q) {
            for my $e ($s->outgoing_edges($id, 'calls', 'references')) {
                my $t = $e->{target} // next;
                push @next, $t unless $reached{$t}++;
            }
        }
        @q = @next;
    }
    my @modules = $module ? ($module)
        : map { $_->{qualified_name} // $_->{name} } grep { !($_->{metadata} // {})->{cpan} } $s->all_nodes(qw(package class));
    my (%seen, @out);
    for my $m (@modules) {
        push @out, grep { !$reached{ $_->{id} } && !$seen{ $_->{id} }++ } $self->api($m);
    }
    return @out;
}

# Architectural stratification of the project's modules: each module's LAYER is its
# longest dependency-path depth (layer 0 depends on nothing internal; higher layers
# build on lower). A clean architecture is a DAG; mutual/cyclic deps break the layering
# and are reported as violations.
sub layers ($self) {
    my $s = $self->store;
    my @mods = grep { !($_->{metadata} // {})->{cpan} } $s->all_nodes(qw(package class));
    my %is_proj = map { (($_->{qualified_name} // $_->{name}) => 1) } @mods;
    my %dep;   # module -> [ project modules it imports/inherits ]
    for my $m (@mods) {
        my $name = $m->{qualified_name} // $m->{name};
        $dep{$name} //= [];
        my %d;
        for my $e ($s->outgoing_edges($m->{id}, 'imports', 'extends')) {
            my $tn;
            if ($e->{target}) { my $t = $s->node($e->{target}); $tn = $t->{qualified_name} // $t->{name} if $t }
            $tn //= ($e->{metadata} // {})->{name} // ($e->{metadata} // {})->{module};
            $d{$tn} = 1 if defined $tn && $is_proj{$tn} && $tn ne $name;
        }
        push @{ $dep{$name} }, sort keys %d;
    }
    # longest-path depth, memoized, recording back-edges (into the active path) as cycles.
    my (%depth, %state, @violations);
    my $visit;
    $visit = sub ($m) {
        return $depth{$m} if ($state{$m} // 0) == 2;
        return undef      if ($state{$m} // 0) == 1;     # a node still on the stack -> a cycle
        $state{$m} = 1;
        my $max = -1;
        for my $d (@{ $dep{$m} // [] }) {
            my $dd = $visit->($d);
            if (defined $dd) { $max = $dd if $dd > $max }
            else             { push @violations, "$m -> $d" }   # cyclic dependency
        }
        $state{$m} = 2;
        return $depth{$m} = $max + 1;
    };
    $visit->($_) for sort keys %dep;
    my %by_layer;
    push @{ $by_layer{ $depth{$_} } }, $_ for sort keys %depth;
    my %seen;
    return { layers => \%by_layer, violations => [ grep { !$seen{$_}++ } @violations ] };
}

# Public API symbols (function/method/constant) carrying no POD docstring -- the same
# public surface as `untested`/`api`, filtered to those a reader gets no documentation for.
sub undocumented ($self, $module = undef) {
    my $s = $self->store;
    my @modules = $module ? ($module)
        : map { $_->{qualified_name} // $_->{name} } grep { !($_->{metadata} // {})->{cpan} } $s->all_nodes(qw(package class));
    my (%seen, @out);
    for my $m (@modules) {
        push @out, grep { !$seen{ $_->{id} }++ && !(defined $_->{docstring} && $_->{docstring} =~ /\S/) } $self->api($m);
    }
    return @out;
}

# Code ownership x importance for bus-factor: per indexed file, its primary author
# (most commits) and that author's share, ranked by how depended-upon the file is
# (cross-file inbound call/reference edges). A high-importance file dominated by one
# author is a bus-factor risk. $authors comes from App::PerlGraph::Git::authors.
sub owners ($self, $authors, %opt) {
    my $s = $self->store;
    my %nfile = map { (($_->{id} // '') => $_->{file_path}) } $s->all_nodes(qw(function method package class constant route));
    my %fanin;   # file -> number of inbound cross-file dependency edges
    for my $kind (qw(calls references)) {
        for my $e ($s->edges_of_kind($kind)) {
            next unless $e->{target};
            my ($sf, $tf) = ($nfile{ $e->{source} }, $nfile{ $e->{target} });
            $fanin{$tf}++ if defined $sf && defined $tf && $sf ne $tf;
        }
    }
    my %indexed = map { (($_ // '') => 1) } values %nfile;   # files that carry indexed symbols
    my @rows;
    for my $f (sort keys %$authors) {
        next unless $indexed{$f};
        my $au = $authors->{$f};
        my $total = 0; $total += $_ for values %$au;
        next unless $total;
        my ($top) = sort { $au->{$b} <=> $au->{$a} || $a cmp $b } keys %$au;
        push @rows, { file => $f, owner => $top, share => $au->{$top} / $total,
                      authors => scalar keys %$au, commits => $total, fanin => $fanin{$f} // 0 };
    }
    @rows = sort { $b->{fanin} <=> $a->{fanin} || $b->{share} <=> $a->{share} || $a->{file} cmp $b->{file} } @rows;
    my $limit = $opt{limit} || 20;
    @rows = @rows[0 .. $limit - 1] if @rows > $limit;
    return \@rows;
}

# { module => qname, deps => { dep_qname => edge_kind, ... } }, sorted by module.
# With $only, just that one module.
sub deps ($self, $only = undef) {
    my $s = $self->store;
    my @pkgs = $only ? (grep { ($_->{kind} // '') =~ /package|class/ } $self->_defs($only))
                     : $s->all_nodes(qw(package class));
    my @out;
    for my $pkg (sort { ($a->{qualified_name} // '') cmp ($b->{qualified_name} // '') } @pkgs) {
        my $self_q = $pkg->{qualified_name} // '';
        my %dep;
        for my $e ($s->outgoing_edges($pkg->{id}, qw(imports extends implements))) {
            my $name = $e->{target} ? ($s->node($e->{target}) // {})->{qualified_name}
                     : ($e->{metadata} // {})->{module} // ($e->{metadata} // {})->{name};
            next unless defined $name && length $name && $name ne $self_q;
            $dep{$name} //= $e->{kind};
        }
        push @out, { module => $self_q, deps => \%dep };
    }
    return @out;
}

# Circular module dependencies: cycles in the package import/inheritance graph,
# considering only intra-project edges (resolved package targets). Returns a list
# of cycles, each an arrayref of qnames in traversal order; duplicate cycles (same
# member set) are reported once.
sub cycles ($self) {
    my $s = $self->store;
    my (%adj, %name);
    for my $pkg ($s->all_nodes(qw(package class))) {
        $name{ $pkg->{id} } = $pkg->{qualified_name} // $pkg->{name};
        my %once;
        $adj{ $pkg->{id} } = [ grep { !$once{$_}++ }
            map { $_->{target} // () } $s->outgoing_edges($pkg->{id}, qw(imports extends implements)) ];
    }
    $_ = [ grep { $name{$_} } @$_ ] for values %adj;   # keep only edges to known packages

    my (%state, @stack, %on_stack, @cycles, %seen);    # state: 1=visiting 2=done
    my $dfs; $dfs = sub ($u) {
        $state{$u} = 1; push @stack, $u; $on_stack{$u} = 1;
        for my $v (@{ $adj{$u} }) {
            if ($on_stack{$v}) {
                my ($i) = grep { $stack[$_] eq $v } 0 .. $#stack;
                my @cyc = @stack[$i .. $#stack];
                push @cycles, [ map { $name{$_} } @cyc ] unless $seen{ join '|', sort @cyc }++;
            }
            elsif (!$state{$v}) { $dfs->($v) }
        }
        pop @stack; delete $on_stack{$u}; $state{$u} = 2;
    };
    $dfs->($_) for grep { !$state{$_} } sort { ($name{$a} // '') cmp ($name{$b} // '') } keys %adj;
    return @cycles;
}

# Public API surface of a module: its contained function/method/constant nodes
# that are exported or public (not _-prefixed). Each node keeps is_exported.
sub api ($self, $module) {
    my $s = $self->store;
    my @out;
    for my $pkg (grep { ($_->{kind} // '') =~ /package|class/ } $self->_defs($module)) {
        for my $e ($s->outgoing_edges($pkg->{id}, 'contains')) {
            my $n = $s->node($e->{target}) or next;
            next unless ($n->{kind} // '') =~ /function|method|constant/;
            next unless is_public($n);
            push @out, $n;
        }
    }
    return @out;
}

# Test files that (transitively) exercise $symbol: the reverse call/reference
# closure restricted to .t files -- the forward complement of affected(tests_only).
sub covers ($self, $symbol, %opt) {
    my $s = $self->store;
    my %seen; my @q = map { $_->{id} } $self->_defs($symbol);
    $seen{$_} = 1 for @q;
    my %tests;
    my $depth = $opt{depth} // 25;
    while (@q && $depth-- > 0) {
        my @next;
        for my $id (@q) {
            for my $e ($s->incoming_edges($id, 'calls', 'references')) {
                next if $seen{ $e->{source} }++;
                my $src = $s->node($e->{source}) or next;
                $tests{ $src->{file_path} } = 1 if ($src->{file_path} // '') =~ /\.t\z/;
                push @next, $e->{source};
            }
        }
        @q = @next;
    }
    my @paths = sort keys %tests;
    return @paths;
}

# Unresolved method calls an agent could resolve: those with candidate
# definitions in the graph, grouped and ranked by frequency. %opt: name, limit.
sub unresolved ($self, %opt) { $self->store->unresolved_with_candidates(%opt) }

# Receiver-centric resolve hints for the LLM. Group unresolved $obj->method calls by
# (caller, receiver), then intersect the classes that DEFINE every method called on
# that receiver: a UNIQUE intersection is a near-certain type the agent can confirm and
# resolve in one receiver-type pcg_resolve call. $self/$class are excluded (handled by
# the enclosing-class heuristic). Ranked unique-class-first, then by call volume.
sub resolve_targets ($self, %opt) {
    my $s = $self->store;
    my @refs = $s->all_unresolved;
    my %qn = $s->node_qnames(map { $_->{from_node_id} // () } @refs);
    my %recv;
    for my $ref (@refs) {
        my ($caller, $method, $rr) = $s->ref_anchor($ref, \%qn) or next;
        next unless defined $rr && $rr =~ /\A\$/ && $rr !~ /\A\$(?:self|class)\z/;
        my $g = ($recv{"$caller\x1f$rr"} //= { caller => $caller, receiver => $rr, m => {}, calls => 0 });
        $g->{m}{$method}++; $g->{calls}++;
    }
    # `name` narrows to the receivers that call that method (still showing each one's
    # full method set + class suggestion) -- e.g. "which receivers call ->connect?".
    %recv = map { ($_ => $recv{$_}) } grep { $recv{$_}{m}{ $opt{name} } } keys %recv if defined $opt{name};
    my %cand = $s->callables_by_name(map { keys %{ $_->{m} } } values %recv);
    my @out;
    for my $g (values %recv) {
        my @ms = sort keys %{ $g->{m} };
        my %inter;
        for my $i (0 .. $#ms) {                            # classes defining method $ms[$i]
            my %pkg; $pkg{ package_of($_->{qualified_name}) } = 1 for @{ $cand{ $ms[$i] } // [] };
            %inter = $i ? (map { ($_ => 1) } grep { $pkg{$_} } keys %inter) : %pkg;
            last unless %inter;                            # the running intersection went empty -> give up early
        }
        next unless %inter;                                # no single class defines all the methods -> nothing to suggest
        push @out, { caller => $g->{caller}, receiver => $g->{receiver}, calls => $g->{calls},
                     methods => \@ms, classes => [ sort keys %inter ] };
    }
    @out = sort { (@{ $b->{classes} } == 1) <=> (@{ $a->{classes} } == 1)   # unique-class suggestions first
               || $b->{calls} <=> $a->{calls} || $a->{caller} cmp $b->{caller} } @out;
    my $limit = $opt{limit} // 50;   # match unresolved()'s default + the documented pcg_unresolved limit
    return @out > $limit ? @out[0 .. $limit - 1] : @out;
}

# Apply agent/LLM resolutions. Each is { caller, method, receiver, target };
# `target` must be a real method/function node (hallucinated targets are
# rejected). Creates the call edge(s) with provenance 'llm' and records the
# (caller, method, receiver) -> target mapping so it survives a reindex.
sub resolve ($self, $resolutions) {
    my $s = $self->store;
    my @refs = $s->all_unresolved;   # fetch once (fully materialized; resolve_ref's deletes don't affect it)
    my (@applied, @rejected, $resolver);
    for my $r (@$resolutions) {
        # receiver-type form { caller, receiver, class }: resolve EVERY method call
        # on that receiver against the class's MRO at once -- only the methods the
        # class actually has (never a fabricated edge). The efficient LLM interface:
        # type a variable once instead of resolving each of its calls.
        if (defined $r->{class} && !defined $r->{target}) {
            my ($caller, $recv, $class) = @{$r}{qw(caller receiver class)};
            unless (defined $caller && defined $recv && defined $class) {
                push @rejected, { %$r, reason => 'missing caller/receiver/class' }; next;
            }
            $resolver //= do { require App::PerlGraph::Resolver; App::PerlGraph::Resolver->new(store => $s) };
            my $edges = 0; my (%cache, %learned);
            for my $ref (@refs) {
                my ($rc, $rm, $rr) = $s->ref_anchor($ref) or next;
                next unless $rc eq $caller && ($rr // '') eq $recv;
                my $tn = exists $cache{$rm} ? $cache{$rm} : ($cache{$rm} = $resolver->method_in_mro($class, $rm));
                next unless $tn;
                $s->resolve_ref($ref->{id}, $tn->{id}, 'llm');
                $learned{$rm} //= $tn->{qualified_name};
                $edges++;
            }
            $s->learn_resolution($caller, $_, $recv, $learned{$_}) for keys %learned;   # persist once per method, not per call site
            push @applied, { caller => $caller, receiver => $recv, class => $class, edges => $edges };
            next;
        }
        my ($caller, $method, $recv, $target) = @{$r}{qw(caller method receiver target)};
        unless (defined $caller && defined $method && defined $recv && defined $target) {
            push @rejected, { %$r, reason => 'missing caller/method/receiver/target' }; next;
        }
        my ($tn) = grep { ($_->{kind} // '') =~ /method|function/ } $s->nodes_by_qname($target);
        unless ($tn) { push @rejected, { %$r, reason => "no such method/function: $target" }; next }
        my $edges = 0;
        for my $ref (@refs) {
            my ($rc, $rm, $rr) = $s->ref_anchor($ref) or next;
            next unless $rm eq $method && $rc eq $caller && ($rr // '') eq $recv;
            $s->resolve_ref($ref->{id}, $tn->{id}, 'llm');
            $edges++;
        }
        $s->learn_resolution($caller, $method, $recv, $target);   # persist for reindex
        push @applied, { caller => $caller, method => $method, receiver => $recv, target => $target, edges => $edges };
    }
    return { applied => \@applied, rejected => \@rejected };
}

sub node_view ($self, $symbol) { map { $self->_view($_) } $self->_defs($symbol) }

# A one-call dossier: the node view (source + immediate callers/callees) plus its
# transitive blast radius and covering tests -- everything about a symbol at once.
sub explain ($self, $symbol) {
    my @out;
    for my $node ($self->_defs($symbol)) {
        my $v  = $self->_view($node);          # { node, callers, callees }
        my $qn = $node->{qualified_name} // $node->{name};
        $v->{impact} = defined $qn ? scalar($self->impact($qn, 50)) : 0;
        $v->{tests}  = [ defined $qn ? $self->covers($qn) : () ];
        push @out, $v;
    }
    return @out;
}

# A ready-to-paste working set for an agent: the focus symbol(s) + their immediate
# caller/callee index + covering tests + the SOURCE of every PROJECT callee (what you
# read to change the focus). $spec is a symbol, or -- if it matches no symbol -- a
# natural-language query resolved via semantic search (else keyword) to the top hits.
sub context ($self, $spec, %opt) {
    my $focus_n = $opt{focus} || 2;
    my @defs = $self->_defs($spec);
    my ($via, $query);
    unless (@defs) {                                   # treat $spec as a natural-language query
        $query = $spec;
        my $sem = $self->semantic($spec, 5);
        my @hits = ($sem->{results} && @{ $sem->{results} })
            ? (do { $via = 'semantic'; @{ $sem->{results} } })
            : (do { $via = 'search';   $self->search($spec, 5) });
        my @callable = grep { ($_->{kind} // '') =~ /function|method/ } @hits;
        @defs = @callable ? @callable : @hits;
        @defs = @defs[0 .. $focus_n - 1] if @defs > $focus_n;
    }
    return { symbol => $spec, focus => [], callees => [], tests => [], via => $via, query => $query } unless @defs;

    my (@focus, %callee_seen, @callees, %test_seen, @tests);
    for my $node (@defs) {
        my $v = $self->_view($node);
        push @focus, $v;
        for my $c (@{ $v->{callees} }) {               # project callees -> inline their source
            next unless ($c->{kind} // '') =~ /function|method/;
            next if ($c->{metadata} // {})->{cpan} || !$c->{file_path};   # skip external deps
            push @callees, $c unless $callee_seen{ $c->{id} }++;
        }
        my $qn = $node->{qualified_name} // $node->{name};
        push @tests, grep { !$test_seen{$_}++ } $self->covers($qn) if defined $qn;
    }
    return { symbol => $spec, focus => \@focus, callees => \@callees, tests => \@tests, via => $via, query => $query };
}

# Reconcile DECLARED CPAN prereqs (from $root's META.json / MYMETA.json / cpanfile /
# Makefile.PL) against the modules actually use'd/require'd in the indexed code: flags
# MISSING (used but not declared) and possibly-UNUSED (declared but never used). Core
# modules and the project's own packages are excluded from "missing".
sub prereqs ($self, $root) {
    my $s = $self->store;
    my %used;
    for my $e ($s->edges_of_kind('imports')) {
        my $m = ($e->{metadata} // {})->{module};
        $used{$m} = 1 if defined $m && length $m;
    }
    my %internal = map { (($_->{qualified_name} // '') => 1) } $s->all_nodes('package'), $s->all_nodes('class');
    my ($declared, $source) = _declared_prereqs($root);
    my $is_core = _core_checker();
    my %skip = map { $_ => 1 } qw(perl ExtUtils::MakeMaker Module::Build);   # build tooling, not a runtime dep
    my (@missing, @unused, @core);
    for my $m (sort keys %used) {
        next if $internal{$m} || $skip{$m};
        if ($is_core->($m)) { push @core, $m unless $declared->{$m}; next }
        push @missing, $m unless exists $declared->{$m};
    }
    for my $m (sort keys %$declared) {
        next if $skip{$m};
        push @unused, $m unless $used{$m} || $internal{$m};
    }
    return { source => $source, missing => \@missing, unused => \@unused, core => \@core,
             declared => scalar(keys %$declared), used => scalar(keys %used) };
}

# (module => version) declared prereqs + the file they came from, trying the structured
# JSON metadata first, then cpanfile, then a targeted scan of Makefile.PL's prereq hashes.
sub _declared_prereqs ($root) {
    require Path::Tiny; require Cpanel::JSON::XS;
    my %req;
    for my $f (qw(META.json MYMETA.json)) {
        my $p = Path::Tiny::path($root)->child($f);
        next unless $p->is_file;
        my $j = eval { Cpanel::JSON::XS->new->decode($p->slurp_raw) } or next;
        for my $phase (values %{ $j->{prereqs} || {} }) {
            my $h = $phase->{requires} or next;           # only hard 'requires', not recommends/suggests
            $req{$_} = $h->{$_} for keys %$h;
        }
        return (\%req, $f);
    }
    my $cpan = Path::Tiny::path($root)->child('cpanfile');
    if ($cpan->is_file) {
        my $txt = $cpan->slurp_utf8;
        $req{$1} = $2 // 0 while $txt =~ /(?:^|\n)\s*requires\s+['"]([\w:]+)['"](?:\s*(?:=>|,)\s*['"]?([\w.]+)['"]?)?/g;
        return (\%req, 'cpanfile') if %req;
    }
    my $mf = Path::Tiny::path($root)->child('Makefile.PL');
    if ($mf->is_file) {
        my $txt = $mf->slurp_utf8;
        while ($txt =~ /(?:PREREQ_PM|(?:TEST|CONFIGURE|BUILD)_REQUIRES)\s*=>\s*\{([^}]*)\}/gs) {
            my $body = $1;
            $req{$1} = $2 // 0 while $body =~ /['"]([\w:]+)['"]\s*=>\s*'?([\w.]+)'?/g;
        }
        return (\%req, 'Makefile.PL') if %req;
    }
    return (\%req, undef);
}

# A predicate `is_core($module)` via Module::CoreList when available, else a small
# fallback set of obvious core modules (so "missing" never flags a core dependency).
sub _core_checker {
    if (eval { require Module::CoreList; 1 }) {
        return sub ($m) { Module::CoreList::is_core($m) ? 1 : 0 };
    }
    my %core = map { $_ => 1 } qw(strict warnings POSIX Exporter Carp Scalar::Util List::Util
        Digest::SHA Data::Dumper Encode Storable File::Temp File::Spec Cwd Time::HiRes
        Getopt::Long constant overload parent base lib feature utf8 Fcntl Errno);
    return sub ($m) { $core{$m} ? 1 : 0 };
}
# explore omits whole-file nodes so it never dumps an entire file.
sub explore ($self, $query, $max = 8) {
    map { $self->_view($_) } grep { ($_->{kind} // '') ne 'file' } $self->search($query, $max);
}

1;

__END__

=head1 NAME

App::PerlGraph::Query - read-only graph queries

=head1 DESCRIPTION

Read-only structural queries over a L<App::PerlGraph::Store>, grouped by intent:
navigation (callers, callees, impact, path), orientation (overview, explore, search /
semantic, node, explain, context), API and tests (api, covers, untested, undocumented),
architecture (deps, cycles, layers, hotspots), history (risk, cochange, owners), security
(sinks), release (affected, diff, semver, review), the graph export model, and the
agent-mediated unresolved / resolve loop.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
