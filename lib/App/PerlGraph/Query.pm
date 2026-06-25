package App::PerlGraph::Query;
use v5.36;
our $VERSION = q{0.065};
use Moo;
use App::PerlGraph::Model qw(package_of is_public is_universal);
use App::PerlGraph::Grammar qw(NODE_CALL NODE_CALL_AMBIG NODE_CALL_OP NODE_METHOD_CALL NODE_LIST_EXPR F_ARGUMENTS F_FUNCTION F_METHOD F_INVOCANT);

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

# Structural refactoring smells over the call graph -- the named, actionable cousins of
# hotspots (which just ranks fan-in/out/complexity). Three classic ones, all graph-only:
#   - feature_envy: a method that makes >= FE_MIN calls into a SINGLE other class and NONE
#                   into its own -- it lives in the wrong place (refactor: move it to that
#                   class). Counts RESOLVED call edges only (one per distinct callee), so
#                   opaque $obj->method layering doesn't trigger it -- but a deliberate thin
#                   wrapper/facade can still match, so it's a candidate to verify.
#   - god_class:    a class with >= GC_METHODS methods AND >= GC_FANIN distinct external
#                   callers -- doing too much and depended on widely (refactor: split it).
#   - long_params:  a sub whose signature declares >= LP_MIN parameters (a leading $self/
#                   $class invocant dropped) -- (refactor: introduce a parameter object).
#                   Signature-based, so old-style my(...)=@_ subs are invisible, like checkargs.
sub smells ($self, %opt) {
    my $limit = $opt{limit} || 20;
    my $s = $self->store;
    my $FE_MIN     = $opt{fe_min}     // 4;     # feature-envy: min calls into one foreign class
    my $GC_METHODS = $opt{gc_methods} // 20;    # god-class: min methods
    my $GC_FANIN   = $opt{gc_fanin}   // 15;    # god-class: min distinct external callers
    my $LP_MIN     = $opt{lp_min}     // 5;     # long-parameter-list: min params (invocant aside)
    # `main` (the script/test namespace -- every .t shares it) and indexed CPAN deps are not
    # classes you'd refactor, and `main` aggregates unrelated subs across files into one bogus
    # bucket, so exclude both from the analysis (callees and candidates alike).
    my @subs  = grep { (($_->{metadata} // {})->{cpan} ? 0 : 1)
                    && package_of($_->{qualified_name} // $_->{name} // '') ne 'main' }
                $s->all_nodes(qw(function method));
    my %byid  = map { $_->{id} => $_ } @subs;

    my (%foreign, %own, %fanin, %meth_count);     # src->{class}=n ; src->n ; class->{src}=1 ; class->n
    $meth_count{ package_of($_->{qualified_name} // $_->{name} // '') }++ for @subs;
    for my $e ($s->edges_of_kind('calls')) {
        my $src = $byid{ $e->{source} // '' } or next;
        my $tgt = $byid{ $e->{target} // '' } or next;
        my $sc  = package_of($src->{qualified_name} // '');
        my $tc  = package_of($tgt->{qualified_name} // '');
        next unless length $sc && length $tc;
        if ($sc eq $tc) { $own{ $src->{id} }++ }
        else { $foreign{ $src->{id} }{$tc}++; $fanin{$tc}{ $src->{id} } = 1 }
    }

    my @envy;
    for my $m (@subs) {
        next if $own{ $m->{id} };                                  # touches its own class -> not envious
        my $f = $foreign{ $m->{id} } or next;
        my ($best) = sort { $f->{$b} <=> $f->{$a} || $a cmp $b } keys %$f;
        next unless $f->{$best} >= $FE_MIN;
        push @envy, { node => $m, class => package_of($m->{qualified_name} // ''),
                      envied => $best, foreign => $f->{$best} };
    }
    @envy = sort { $b->{foreign} <=> $a->{foreign}
                || ($a->{node}{qualified_name} // '') cmp ($b->{node}{qualified_name} // '') } @envy;

    my @god;
    for my $c (keys %meth_count) {
        my $fin = scalar keys %{ $fanin{$c} // {} };
        next unless $meth_count{$c} >= $GC_METHODS && $fin >= $GC_FANIN;
        push @god, { class => $c, methods => $meth_count{$c}, fanin => $fin };
    }
    @god = sort { $b->{methods} <=> $a->{methods} || $b->{fanin} <=> $a->{fanin} || $a->{class} cmp $b->{class} } @god;

    my @long;
    for my $m (@subs) {
        my @p = _sig_params($m->{signature} // '');
        shift @p if @p && $p[0] =~ /\A\$(?:self|class)\z/;         # the invocant isn't a passed parameter
        next unless @p >= $LP_MIN;
        push @long, { node => $m, count => scalar @p, params => [@p] };
    }
    @long = sort { $b->{count} <=> $a->{count}
                || ($a->{node}{qualified_name} // '') cmp ($b->{node}{qualified_name} // '') } @long;

    @envy = @envy[0 .. $limit - 1] if @envy > $limit;       # cap each category at the limit
    @god  = @god [0 .. $limit - 1] if @god  > $limit;
    @long = @long[0 .. $limit - 1] if @long > $limit;
    return { feature_envy => \@envy, god_class => \@god, long_params => \@long,
             thresholds => { fe_min => $FE_MIN, gc_methods => $GC_METHODS, gc_fanin => $GC_FANIN, lp_min => $LP_MIN } };
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

# Source -> sink TAINT PATHS: trace a call path from a user-input SOURCE to an injectable
# SINK. Sharper than pcg_sinks (which only does route->sink reachability): the sources are
# broader -- a route handler (endpoint) OR any sub that calls a request accessor (param /
# params / cookie(s) / upload(s) / header(s) / query_parameters / body_parameters /
# route_parameters) -- and only DYNAMIC sinks
# (whose command/SQL string is built from a variable -- the injectable ones) are targets, with
# the actual call PATH shown. It is call-graph reachability, NOT value-flow: it proves user
# input can REACH the sink's sub, not that the specific tainted value lands in the sink's
# argument -- so a hit is a path to VERIFY (a `local` hit, source and sink in the SAME sub, is
# the highest-confidence). $ENV / @ARGV / STDIN sources are not yet detected (a known gap).
my %TAINT_SOURCE_CALLS = map { $_ => 1 } qw(
    param params cookie cookies upload uploads header headers
    query_parameters body_parameters route_parameters);
sub taint ($self, %opt) {
    my $s = $self->store;
    my %sink;                                                 # sub id -> [ {type,name} ] (DYNAMIC sinks only)
    for my $e ($s->edges_of_kind('sink')) {
        my $m = $e->{metadata} // {};
        next unless defined $e->{source} && $m->{dynamic};
        push @{ $sink{ $e->{source} } }, { type => $m->{sink} // '?', name => $m->{name} // '?' };
    }
    return { paths => [], sinks => 0, sources => 0 } unless %sink;

    my %source;                                               # sub id -> { kind, detail }
    for my $route ($s->all_nodes('route')) {                  # endpoints: user input enters here
        my ($he) = grep { (($_->{metadata} // {})->{via} // '') eq 'route' } $s->outgoing_edges($route->{id}, 'references');
        $source{ $he->{target} } //= { kind => 'endpoint', detail => $route->{name} // 'route' } if $he && $he->{target};
    }
    for my $ref ($s->all_unresolved) {                        # subs that read a request accessor
        my $nm = $ref->{reference_name} // '';
        $source{ $ref->{from_node_id} } //= { kind => 'request', detail => $nm }
            if $TAINT_SOURCE_CALLS{$nm} && $ref->{from_node_id};
    }
    return { paths => [], sinks => scalar keys %sink, sources => 0 } unless %source;

    my @paths;                                                # forward BFS from each source to the nearest sinks
    for my $src (sort keys %source) {
        my %seen = ($src => 1); my @q = ([ $src ]); my $depth = 40; my %hit;
        while (@q && $depth-- > 0) {
            my @next;
            for my $path (@q) {
                my $id = $path->[-1];
                push @paths, { source => $source{$src}, ids => [ @$path ], sinks => $sink{$id},
                               local => ($id eq $src ? 1 : 0) }
                    if $sink{$id} && !$hit{$id}++;
                for my $e ($s->outgoing_edges($id, 'calls', 'references')) {
                    push @next, [ @$path, $e->{target} ] if $e->{target} && !$seen{ $e->{target} }++;
                }
            }
            @q = @next;
        }
    }
    for my $p (@paths) {                                      # resolve ids -> qnames once, at the end
        $p->{path}     = [ map { my $n = $s->node($_); $n ? ($n->{qualified_name} // $n->{name} // '?') : '?' } @{ $p->{ids} } ];
        $p->{src_sub}  = $p->{path}[0];
        $p->{sink_sub} = $p->{path}[-1];
        delete $p->{ids};
    }
    @paths = sort { $b->{local} <=> $a->{local} || @{ $a->{path} } <=> @{ $b->{path} }
                 || $a->{src_sub} cmp $b->{src_sub} || $a->{sink_sub} cmp $b->{sink_sub} } @paths;
    my $limit = $opt{limit} || 50;
    @paths = @paths[0 .. $limit - 1] if @paths > $limit;
    return { paths => \@paths, sinks => scalar keys %sink, sources => scalar keys %source };
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

# Broken method calls: `$recv->method` sites where the receiver's class is KNOWN
# (in-repo, with a fully in-repo MRO and no AUTOLOAD escape hatch) yet defines no such
# method anywhere in that MRO -- typos and calls into renamed/removed API, which static
# Perl misses until runtime. The closed-MRO + no-AUTOLOAD + not-universal/lifecycle gate
# keeps false positives near zero (`has`/`field` accessors ARE captured); the residue is
# dynamic method injection (runtime *glob installs, `handles` delegation), exactly what
# `pcg index --runtime` resolves -- so findings are honest heuristic candidates to verify.
# Skip-list: object-system base methods we don't model as nodes for a plain `-base` class.
my %CHECKCALLS_SKIP = map { $_ => 1 }
    qw(new import unimport BUILD BUILDARGS BUILDALL DEMOLISH DESTROY AUTOLOAD CLONE
       meta does DOES dump tap attr with_roles);
sub checkcalls ($self) {
    my $s = $self->store;
    require App::PerlGraph::Resolver;
    my $r = App::PerlGraph::Resolver->new(store => $s);
    my @pkgs = $s->all_nodes(qw(package class));
    my %in_repo = map { (($_->{qualified_name} // '') => 1) }              # closed-MRO test, once; a `--deps`-indexed
                  grep { !(($_->{metadata} // {})->{cpan}) } @pkgs;        # CPAN dep is INCOMPLETE (XS methods unseen) -> external
    my %is_role = map { (($_->{qualified_name} // '') => 1) }              # a role is composed into unknown
                  grep { (($_->{metadata} // {})->{role}) } @pkgs;         # consumers, so its $self method set is open
    my (%seen, @out);
    for my $ref ($s->all_unresolved) {
        next unless ($ref->{reference_kind} // '') eq 'method_call';
        my $m = $ref->{reference_name};
        next if $m =~ /::/ || is_universal($m) || $CHECKCALLS_SKIP{$m};   # SUPER::/qualified, can/isa, lifecycle
        my $cls = $r->receiver_class($ref)              or next;          # only when we KNOW the receiver's class
        next if $is_role{$cls};                                          # $self in a role is the consumer, not the role
        my @mro = $r->mro($cls)                         or next;
        next if grep { !$in_repo{$_} } @mro;                             # any MRO class (incl. $cls) external -> unsure
        next if $r->method_in_mro($cls, $m);                             # the method DOES exist -> fine
        next if $r->method_in_mro($cls, 'AUTOLOAD');                     # AUTOLOAD in the MRO -> dynamic dispatch
        my $caller = $ref->{from_node_id} ? $s->node($ref->{from_node_id}) : undef;
        my $cn = $caller ? ($caller->{qualified_name} // $caller->{name} // '?') : '?';
        next if $seen{"$cls\x1f$m\x1f$cn\x1f@{[ $ref->{line} // 0 ]}"}++;
        push @out, { class => $cls, method => $m, caller => $cn, file => $ref->{file_path}, line => $ref->{line} };
    }
    return [ sort { $a->{class} cmp $b->{class} || $a->{method} cmp $b->{method}
                 || ($a->{file} // '') cmp ($b->{file} // '') || ($a->{line} // 0) <=> ($b->{line} // 0) } @out ];
}

# Wrong-arity calls: resolved calls to an in-repo function/method whose SIGNATURE fixes
# its arity, where the call site passes a statically-countable number of args that doesn't
# fit -- a static BUG FINDER (sibling to checkcalls) for a violation Perl only catches at
# runtime. Re-parses each calling file to count the positional args at the call site; a
# splat arg (@list / %h / a list-returning call) is indeterminate and skipped, and a
# method call's implicit invocant is counted toward @_. Only subs with an explicit
# signature and a determinate call site are checked, so findings are precise but not
# exhaustive (a `my (...) = @_` / `shift` sub has no signature to check against).
sub checkargs ($self, $root) {
    my $s = $self->store;
    my %qn_count;                                        # a qname defined by >1 node is resolution-ambiguous
    $qn_count{ $_->{qualified_name} // '' }++ for $s->all_nodes(qw(function method));
    my %arity;                                           # callee id -> { min, max, sig, node, short, qn, method }
    for my $fn ($s->all_nodes(qw(function method))) {
        my $sig = $fn->{signature};
        next unless defined $sig && length $sig;
        my ($min, $max) = _sig_arity($sig);
        next unless defined $min;                        # variadic (a slurpy @/%) / unparseable -> can't check
        my $qn = $fn->{qualified_name} // $fn->{name} // '';
        next if ($qn_count{$qn} // 0) > 1;               # e.g. main::setup in two scripts -> which one is unclear
        $arity{ $fn->{id} } = { min => $min, max => $max, sig => $sig, node => $fn,
                                short => (split /::/, $qn)[-1], qn => $qn, pkg => package_of($qn) };
    }
    return [] unless %arity;
    # The graph dedups multiple call sites caller->callee into ONE edge, so use the edge
    # only as a resolution hint -- "this caller calls this fixed-arity sub" -- then re-parse
    # and check EVERY matching call site in the caller's line range. A function site matches
    # by full name when qualified (precise) else short name; a `$self->m` method site matches
    # only a callee in the SAME package (the common intra-class case), so a `$x->foo` call is
    # never mis-checked against an unrelated same-named `Other::foo`.
    my %calls;                                           # caller id -> { f|fq|m } -> name -> [ callee, ... ]
    for my $cid (keys %arity) {
        my $a = $arity{$cid};
        for my $e ($s->incoming_edges($cid, 'calls')) {
            push @{ $calls{ $e->{source} }{f}{ $a->{short} } }, $a;
            push @{ $calls{ $e->{source} }{fq}{ $a->{qn} } }, $a;
            push @{ $calls{ $e->{source} }{m}{ $a->{short} } }, $a;
        }
    }
    my %file_callers;                                    # file -> [ caller node ]
    for my $caller_id (keys %calls) {
        my $cn = $s->node($caller_id) or next;
        push @{ $file_callers{ $cn->{file_path} } }, $cn if $cn->{file_path};
    }
    require App::PerlGraph::Parser;
    require Path::Tiny;
    my $parser = App::PerlGraph::Parser->new;
    my (%seen, @out);
    for my $file (sort keys %file_callers) {
        my $disk = Path::Tiny::path($root)->child($file);
        next unless $disk->is_file;
        my $tree  = eval { $parser->parse_string($disk->slurp_raw) } or next;
        my @sites = _call_sites($tree);                  # { name, method, line, argc }
        for my $caller (@{ $file_callers{$file} }) {
            my ($lo, $hi) = ($caller->{start_line} // 0, $caller->{end_line} // ~0);
            my $cpkg  = package_of($caller->{qualified_name} // $caller->{name} // '');
            my $named = $calls{ $caller->{id} };
            for my $site (@sites) {
                next unless defined $site->{argc} && $site->{line} >= $lo && $site->{line} <= $hi;
                # a method site matches a same-package callee ONLY when the invocant is $self/$class
                # (the intra-class case); a `$other->m` / `$_->m` receiver has an unknown type, so don't
                # assume it targets a same-named method in the caller's own package (a common false positive).
                my $cands = $site->{method}       ? ($site->{self} ? [ grep { $_->{pkg} eq $cpkg } @{ $named->{m}{ $site->{name} } // [] } ] : [])
                          : $site->{full} =~ /::/ ? $named->{fq}{ $site->{full} }
                          :                         $named->{f}{ $site->{name} };
                $cands && @$cands or next;
                next if @$cands > 1;                     # caller calls two same-named fixed-arity subs -> ambiguous
                my $c   = $cands->[0];
                my $got = $site->{argc} + ($site->{method} ? 1 : 0);  # a `->method` call passes an implicit invocant
                next if $got >= $c->{min} && (!defined $c->{max} || $got <= $c->{max});
                my $callee = $c->{node}{qualified_name} // $c->{node}{name};
                next if $seen{"$file\x1f$site->{line}\x1f$callee"}++;
                push @out, {
                    callee   => $callee,
                    sig      => $c->{sig},
                    expected => (defined $c->{max} ? ($c->{min} == $c->{max} ? "$c->{min}" : "$c->{min}-$c->{max}") : "$c->{min}+"),
                    got      => $got,
                    caller   => ($caller->{qualified_name} // $caller->{name} // '?'),
                    file     => $file, line => $site->{line},
                };
            }
        }
    }
    return [ sort { ($a->{file} // '') cmp ($b->{file} // '') || ($a->{line} // 0) <=> ($b->{line} // 0)
                 || $a->{callee} cmp $b->{callee} } @out ];
}

# Parse a signature's arity -> (min required, max), max undef if a slurpy @/% makes it
# variadic; a `$x = default` param is optional (counts toward max, not min). undef if the
# signature isn't a simple param list.
sub _sig_arity ($sig) {
    $sig =~ s/\A\s*\(\s*//;
    $sig =~ s/\s*\)\s*\z//;
    return (0, 0) unless length $sig;
    my ($min, $max) = (0, 0);
    for my $p (_split_top_commas($sig)) {
        $p =~ s/\A\s+//;
        $p =~ s/\s+\z//;
        next unless length $p;
        return ($min, undef) if $p =~ /\A[\@%]/;          # slurpy -> variadic; the params before it set the min
        $max++;
        $min++ unless $p =~ /=/;                           # a default value makes the param optional
    }
    return ($min, $max);
}

# Split on top-level commas only (depth tracks () [] {} so `$x = foo(1, 2)` stays one param).
sub _split_top_commas ($s) {
    my @out;
    my $buf   = '';
    my $depth = 0;
    for my $ch (split //, $s) {
        if    ($ch =~ /[(\[{]/)           { $depth++;        $buf .= $ch }
        elsif ($ch =~ /[)\]}]/)           { $depth--;        $buf .= $ch }
        elsif ($ch eq ',' && $depth == 0) { push @out, $buf; $buf = '' }
        else                              {                  $buf .= $ch }
    }
    push @out, $buf if length $buf;
    return @out;
}

# Every call site in a tree: its called short name, whether it's a `->method` call, its
# start line, and its arg count (undef when not statically countable).
sub _call_sites ($tree) {
    my @sites;
    my @stack = ($tree);
    while (my $n = pop @stack) {
        my $t = $n->{type} // '';
        if ($t eq NODE_CALL || $t eq NODE_CALL_AMBIG || $t eq NODE_CALL_OP) {
            if (my $fn = $n->{fields}{ +F_FUNCTION }) {
                my $full = $fn->{text} // '';
                push @sites, { name => (split /::/, $full)[-1], full => $full, method => 0,
                               line => $n->{sl}, argc => _count_args($n->{fields}{ +F_ARGUMENTS }) };
            }
        }
        elsif ($t eq NODE_METHOD_CALL) {
            if (my $m = $n->{fields}{ +F_METHOD }) {
                my $inv = ($n->{fields}{ +F_INVOCANT } // {})->{text} // '';
                push @sites, { name => ($m->{text} // ''), method => 1,        # method sites match by short name, never `full`
                               self => ($inv =~ /\A\$(?:self|class)\z/ ? 1 : 0), # only $self/$class is the same-package case
                               line => $n->{sl}, argc => _count_args($n->{fields}{ +F_ARGUMENTS }) };
            }
        }
        push @stack, @{ $n->{children} // [] };
    }
    return @sites;
}

# Count top-level positional args; undef if any arg is list-context (its element count is
# not statically known): a @array / %hash splat, an @{...}/%{...} deref, or a call result.
sub _count_args ($args) {
    return 0 unless $args;
    my @top = (($args->{type} // '') eq NODE_LIST_EXPR)
        ? grep { ($_->{type} // '') !~ /\A[[:punct:]]+\z/ } @{ $args->{children} // [] }
        : ($args);
    my $n = 0;
    for my $a (@top) {
        my $t = $a->{type} // '';
        # indeterminate element count -> can't check arity: an @array/%hash, a deref, a slice
        # (@h{...} / @a[...]), or a list-returning call.
        return undef if $t =~ /\A(?:array|hash)\z/ || $t =~ /(?:array|hash)_deref/ || $t =~ /slice/ || $t =~ /_call_expression\z/;
        if ($t eq 'quoted_word_list') {                       # qw/a b c/ is its WORD COUNT, not one arg
            (my $w = $a->{text} // '') =~ s/\A\s*qw\s*.//s; $w =~ s/.\s*\z//s;
            $n += scalar split ' ', $w;
        }
        else { $n++ }
    }
    return $n;
}

# POD documenting a method/function that no longer exists -- doc DRIFT (distinct from
# undocumented, which is missing POD). Scans each file's POD for call-shaped entries
# (`=head2 name($args)` / `=item C<< $obj->name >>`) and flags any whose name is defined by
# NO sub in the documenting file's package(s) or their @ISA ancestors -- a method that was
# removed or renamed while its docs were left behind. Package+MRO-aware (an inherited method
# documented in a subclass is fine); auto-provided names (new/import/...) are skipped.
my %DOCCHECK_SKIP = map { $_ => 1 }
    qw(new import unimport BUILD BUILDARGS DEMOLISH DESTROY AUTOLOAD CLONE meta does DOES);
sub doccheck ($self, $root) {
    my $s = $self->store;
    require App::PerlGraph::Resolver;
    my $r = App::PerlGraph::Resolver->new(store => $s);
    my %pkg_names;                                       # package qname -> { sub/method/constant short name => 1 }
    for my $n ($s->all_nodes(qw(function method constant))) {   # constants are public API too -- documenting one isn't stale
        my $qn = $n->{qualified_name} // $n->{name} // '';
        $pkg_names{ package_of($qn) }{ (split /::/, $qn)[-1] } = 1;
    }
    my %file_pkgs;                                       # file -> [ package qname ]
    push @{ $file_pkgs{ $_->{file_path} } }, $_->{qualified_name}
        for grep { $_->{file_path} } $s->all_nodes(qw(package class));
    require Path::Tiny;
    my @out;
    for my $file (sort keys %file_pkgs) {
        my $disk = Path::Tiny::path($root)->child($file);
        next unless $disk->is_file;
        my %known;                                       # every name reachable from a package in this file
        for my $pkg (@{ $file_pkgs{$file} }) {
            $known{$_} = 1 for map { keys %{ $pkg_names{$_} // {} } } $r->mro($pkg);
        }
        for my $doc (_pod_api_names($disk->slurp_utf8)) {
            next if $known{ $doc->{name} } || $DOCCHECK_SKIP{ $doc->{name} };
            push @out, { name => $doc->{name}, file => $file, line => $doc->{line} };
        }
    }
    return [ sort { $a->{file} cmp $b->{file} || $a->{line} <=> $b->{line} } @out ];
}

# Call-shaped POD entries: =head2/=head3/=item headings that document a callable, as
# `name(...)` or `$obj->name`. Returns { name, line }. Requiring the call form (parens or
# an arrow) keeps prose section headings ("DESCRIPTION", "Configuration") from matching.
sub _pod_api_names ($text) {
    my @found;
    my $line = 0;
    for my $ln (split /\n/, $text) {
        $line++;
        next unless $ln =~ /\A=(?:head[234]|item)\s+(\S.*)\z/;
        my $p = $1;
        $p =~ s/[A-Z]<+//g;                              # strip C<< / B< / L< / I< openers
        $p =~ s/(?<!-)>+//g;                             # and their closers, but NOT the > in a -> arrow
        my $name = $p =~ /(?:\$\w+|\w+)\s*->\s*(\w+)/ ? $1     # $obj->method
                 : $p =~ /\A\s*(\w+)\s*\(/            ? $1     # name(...)
                 :                                      undef;
        push @found, { name => $name, line => $line } if defined $name;
    }
    return @found;
}

# A POD + test SKELETON (with TODOs) for one sub, derived from its signature -- the
# actionable starting point for pcg_untested / pcg_undocumented. Resolves the symbol to a
# unique function/method and returns what the renderer needs (the node, its parameters, and
# whether it's a method so the call shape uses $obj-> and drops the invocant).
sub scaffold ($self, $symbol) {
    my $s = $self->store;
    my @defs = grep { ($_->{kind} // '') =~ /\A(?:function|method)\z/ }
               ($symbol =~ /::/ ? $s->nodes_by_qname($symbol) : $s->nodes_by_name($symbol));
    return { error => "no function/method named '$symbol'" } unless @defs;
    return { error => "'$symbol' is ambiguous (@{[ scalar @defs ]} defs) -- qualify it" } if @defs > 1;
    my $n = $defs[0];
    my @params = _sig_params($n->{signature} // '');
    my $is_method = ($n->{kind} // '') eq 'method' || (@params && $params[0] =~ /\A\$(?:self|class)\z/);
    return { node => $n, params => \@params, is_method => $is_method, has_pod => ($n->{docstring} ? 1 : 0) };
}

# Parameter names from a signature, defaults dropped: "($a, $b = 5)" -> ('$a', '$b').
sub _sig_params ($sig) {
    $sig =~ s/\A\s*\(\s*//;
    $sig =~ s/\s*\)\s*\z//;
    return () unless length $sig;
    my @p;
    for my $part (_split_top_commas($sig)) {
        $part =~ s/\s*=.*\z//s;                              # drop a default value
        $part =~ s/\A\s+//;
        $part =~ s/\s+\z//;
        push @p, $part if $part =~ /\A[\$\@%]\w+\z/;
    }
    return @p;
}

# Structural code clones: subs whose BODY has an identical CST shape (the per-sub
# `dup` fingerprint -- node-type sequence with identifiers/literals abstracted away,
# so type-1 and type-2 copy-paste-with-renames match). Groups of >= 2 are reported,
# ranked by size x copies (the best extract-a-helper targets). Near-duplicates with
# small edits (type-3) are NOT grouped -- this is exact-structure, low false positive.
sub duplication ($self, %opt) {
    my $s   = $self->store;
    my $min = $opt{min_nodes} || 30;                 # ignore small bodies (a few statements)
    my %by_fp;
    for my $n ($s->all_nodes(qw(function method))) {
        my $dup = ($n->{metadata} // {})->{dup} or next;
        my ($count) = $dup =~ /\A(\d+):/;
        push @{ $by_fp{$dup} }, $n if $count && $count >= $min;
    }
    my @groups;
    for my $fp (keys %by_fp) {
        my @members = @{ $by_fp{$fp} };
        next unless @members >= 2;                    # a clone needs at least two copies
        my ($nodes) = $fp =~ /\A(\d+):/;
        push @groups, { nodes => $nodes + 0, count => scalar @members,
            members => [ sort { ($a->{qualified_name} // '') cmp ($b->{qualified_name} // '') } @members ] };
    }
    @groups = sort { $b->{nodes} * $b->{count} <=> $a->{nodes} * $a->{count}     # biggest x most-copied first
                  || $b->{nodes} <=> $a->{nodes}
                  || ($a->{members}[0]{qualified_name} // '') cmp ($b->{members}[0]{qualified_name} // '') } @groups;
    my $limit = $opt{limit} || 20;
    @groups = @groups[0 .. $limit - 1] if @groups > $limit;
    return \@groups;
}

# Suggested reviewers for a change: rank the authors of the CHANGED files by how many commits
# they've made to them (git authorship x the diff). The people who wrote the touched code
# review it best. $authors = App::PerlGraph::Git::authors; $changed = the changed code files
# (App::PerlGraph::Git::changed). Pure git -- no graph lookup -- but a Query method for symmetry.
sub suggest_reviewers ($self, $authors, $changed) {
    my (%score, %touched);
    for my $f (@$changed) {
        my $au = $authors->{$f} or next;
        for my $a (keys %$au) {
            $score{$a} += $au->{$a};
            push @{ $touched{$a} }, $f;
        }
    }
    return [ map { { author => $_, commits => $score{$_}, files => [ sort @{ $touched{$_} } ] } }
             sort { $score{$b} <=> $score{$a} || $a cmp $b } keys %score ];
}

# Exported FUNCTIONS/METHODS (@EXPORT / @EXPORT_OK) that NO other in-repo package calls or
# references -- public API you could stop exporting. "Used" counts any caller OUTSIDE the
# defining package (tests included); an export only its own package uses is dead weight on
# the API. Constants are excluded: their bareword use isn't recorded as a call edge, so we
# can't tell if they're live. Honest caveat (the renderer states it): a CPAN module's
# exports may exist for external consumers the graph can't see -- candidates, not removals.
sub dead_exports ($self) {
    my $s = $self->store;
    my @out;
    for my $n (grep { $_->{is_exported} } $s->all_nodes(qw(function method))) {
        my $pkg  = package_of($n->{qualified_name} // $n->{name} // '');
        my $live = 0;
        for my $e ($s->incoming_edges($n->{id}, 'calls', 'references')) {
            my $src = $s->node($e->{source}) or next;
            next if package_of($src->{qualified_name} // $src->{name} // '') eq $pkg;   # same-package use doesn't count
            $live = 1; last;
        }
        push @out, $n unless $live;
    }
    return [ sort { ($a->{qualified_name} // '') cmp ($b->{qualified_name} // '') } @out ];
}

# A one-call cleanup dashboard: the codebase's actionable tech-debt, each bucket paired with
# the WRITE tool that fixes it. Graph-only, so it runs anywhere. Three disjoint buckets:
#   - removable:   unreferenced, NON-exported subs `pcg rm` can delete outright (rm also
#                  cascades to the private helpers they solely used). Exported dead code is
#                  deliberately excluded here -- rm refuses exported subs -- and surfaces in:
#   - retractable: exported subs no OTHER in-repo package uses (pcg dead_exports) -- stop
#                  exporting first, then remove. Disjoint from `removable` (that is non-exported).
#   - clones:      structural duplicate groups `pcg dedupe` can collapse (the type-1 ones).
# A survey, not an apply: it names the exact follow-up commands but changes nothing itself.
sub tidy ($self, %opt) {
    my @removable = sort { ($a->{qualified_name} // '') cmp ($b->{qualified_name} // '') }
                    grep { !$_->{is_exported} } $self->unused;
    return {
        removable   => \@removable,
        retractable => $self->dead_exports,
        clones      => $self->duplication(%opt),
    };
}

# A one-call code-health snapshot for triage / release: composes the analyses into
# headline scale numbers plus the coverage and quality ratios. Graph-only (no git), so it
# runs anywhere. The renderer turns these into a concerns summary.
sub metrics ($self) {
    my $s   = $self->store;
    my $dbh = $s->dbh;
    my @funcs = $s->all_nodes(qw(function method));
    my @pkgs  = $s->all_nodes(qw(package class));
    my @api   = grep { is_public($_) } $s->all_nodes(qw(function method constant));
    my @complex = grep { (($_->{metadata} // {})->{complexity} // 0) >= 10 } @funcs;
    my $maxcx = 0;
    for my $f (@funcs) { my $c = ($f->{metadata} // {})->{complexity} // 0; $maxcx = $c if $c > $maxcx }
    my ($nodes)      = $dbh->selectrow_array('select count(*) from nodes');
    my ($edges)      = $dbh->selectrow_array('select count(*) from edges');
    my ($files)      = $dbh->selectrow_array('select count(*) from files');
    my ($unresolved) = $dbh->selectrow_array('select count(*) from unresolved_refs');
    my ($rels)       = $dbh->selectrow_array("select count(*) from edges where kind in ('calls','references')");
    my @unused   = $self->unused;
    my @untested = $self->untested;
    my @undoc    = $self->undocumented;
    my @cycles   = $self->cycles;
    my $clones   = $self->duplication(limit => scalar(@funcs) || 1);   # the true group COUNT, not the top-20 default
    my $napi = scalar(@api) || 1;                # denominator for the coverage ratios (>=1, avoids /0)
    my $tot  = ($rels // 0) + ($unresolved // 0) || 1;
    return {
        files => $files // 0, packages => scalar @pkgs, subs => scalar @funcs, public_api => scalar @api,
        nodes => $nodes // 0, edges => $edges // 0,
        unresolved => $unresolved // 0, resolved_pct => 100 * ($rels // 0) / $tot,
        complex => scalar @complex, max_complexity => $maxcx,
        cycles => scalar @cycles, unused => scalar @unused, clone_groups => scalar @$clones,
        untested => scalar @untested, tested_pct => 100 * ($napi - scalar @untested) / $napi,
        undocumented => scalar @undoc, documented_pct => 100 * ($napi - scalar @undoc) / $napi,
    };
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
