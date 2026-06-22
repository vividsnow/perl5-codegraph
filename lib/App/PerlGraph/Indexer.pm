package App::PerlGraph::Indexer;
use v5.36;
our $VERSION = q{0.047};
use Moo;
use Digest::SHA qw(sha1_hex);
use Path::Iterator::Rule;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::Resolver;
use App::PerlGraph::Runtime;
use App::PerlGraph::XS;
use App::PerlGraph::Model qw(node_id);
use Path::Tiny qw(path);
use Storable qw(nstore retrieve);
use File::Temp ();
use POSIX ();

has store  => (is => 'ro', required => 1);
has root   => (is => 'ro', required => 1);
has parser  => (is => 'lazy', builder => sub { App::PerlGraph::Parser->new });
has runtime => (is => 'ro', default => 0);
has deps    => (is => 'ro', default => 0);   # also index the public API of used CPAN modules (@INC)
has embed   => (is => 'ro', default => 0);   # also compute semantic-search embeddings (optional local provider)
has jobs          => (is => 'ro', default => 0);   # 0 = auto-detect; 1 = serial; N = N parse workers
has max_file_size => (is => 'ro', default => 0);   # bytes; 0 = unlimited (index everything)

# shared file-selection vocabulary (the watcher reads these so it and sync agree)
our @IGNORE_DIRS = qw(.git .vscode .idea blib _build local vendor node_modules .pcg cover_db);
our $PERL_RX     = qr/\.(?:pl|pm|t|psgi|pod|xs)$/;

# Bump when the extractor's output changes (new node/edge kinds, resolution rules)
# so a `pcg index`/`sync` after an upgrade re-extracts unchanged files instead of
# trusting their stale graph. Files carry the version they were extracted with.
use constant EXTRACTION_VERSION => 6;   # 6: sink dynamic-arg (injection-shape) flag

# The dir-pruning rule shared by file and directory scans: the named IGNORE_DIRS,
# plus any non-root subdir that is itself a git repo/worktree (its own .git) --
# submodules, vendored clones and `git worktree` copies are not this project's
# code, and indexing them duplicates or bloats the graph.
sub _rule ($self) {
    my $rule = Path::Iterator::Rule->new;
    $rule->skip_dirs(@IGNORE_DIRS);
    $rule->skip(Path::Iterator::Rule->new->directory->and(sub {
        my (undef, undef, $stash) = @_;
        return $stash->{_depth} && -e "$_/.git" ? 1 : 0;   # depth 0 = the scan root, never pruned
    }));
    return $rule;
}

# File paths are stored as the canonical key "relative to the root", so the same
# project indexed under different root spellings (`.` vs an absolute path) yields
# identical keys -- otherwise sync sees every file as deleted+new. The on-disk
# path is reconstructed by joining the root back on (see _read / _lib_dirs).
sub _perl_files ($self) {
    my $rule = $self->_rule;
    $rule->name($PERL_RX);
    my $root = path($self->root);
    my $cap  = $self->max_file_size;
    my @keep;
    for my $f ($rule->all($self->root)) {              # disk paths (root-spelled)
        if ($cap) {
            my $sz = -s $f // 0;
            # huge files in a tree are almost always generated data (Module::CoreList:
            # 18 subs, 25k data lines) -- skip rather than spend minutes for ~no graph.
            if ($sz > $cap) { warn sprintf "pcg: skipping %s (%.1f MB > max-file-size %.1f MB)\n", $f, $sz/1e6, $cap/1e6; next }
        }
        push @keep, path($f)->relative($root)->stringify;   # canonical key
    }
    return @keep;
}

# Every watchable directory at/under $from (default root), skipping ignored
# subtrees -- the inotify watcher places one watch per dir (inotify isn't
# recursive). Returns the starting dir plus its surviving descendants.
sub dirs ($self, $from = undef) {
    my $rule = $self->_rule;
    $rule->directory;
    return $rule->all($from // $self->root);
}

# canonical key (relative to root) -> the on-disk path. Single source of truth
# for the mapping, reused by the watcher's mtime fingerprint.
sub _disk_path ($self, $path) { path($self->root)->child($path)->stringify }

# Read raw bytes: tree-sitter is byte-oriented, and sha1_hex/the parser XS croak
# on wide characters (real code has UTF-8 in comments/POD/strings). Returns undef
# if the file vanished mid-scan (an editor's atomic save / a `git checkout` during
# `pcg watch`) so the scan skips it instead of crashing the watcher.
sub _read ($self, $path) {
    my $disk = $self->_disk_path($path);
    open my $fh, '<:raw', $disk or do { require Errno; return undef if $! == Errno::ENOENT(); die "$disk: $!" };
    local $/; <$fh>;
}

sub _file_changed ($self, $path) {
    my $src = $self->_read($path) // return 0;   # vanished mid-scan -> not a change this pass
    return !$self->store->file_fresh($path, sha1_hex($src), EXTRACTION_VERSION);   # changed, or extracted by an older pcg
}

# Parse + extract one file into a plain { path, hash, out, lang } record -- NO
# database access, so it is safe to run in a forked worker (see _index_parallel).
sub _extract_src ($self, $path, $src, $hash) {
    my $out = $path =~ /\.xs\z/
        ? App::PerlGraph::XS->scan($path, $src)                                   # XS, not Perl
        : App::PerlGraph::Extractor->new(file_path => $path, source => $src)->extract($self->parser->parse_string($src));
    return { path => $path, hash => $hash, out => $out, lang => ($path =~ /\.xs\z/ ? 'xs' : 'perl') };
}

# Write one extraction record to the graph (replacing the file's prior nodes).
sub _store_extract ($self, $r) {
    my $s = $self->store;
    $s->delete_file_nodes($r->{path});
    $s->insert_node($_)       for @{ $r->{out}{nodes} };
    $s->insert_edge($_)       for @{ $r->{out}{edges} };
    $s->insert_unresolved($_) for @{ $r->{out}{refs} };
    $s->upsert_file({ path => $r->{path}, hash => $r->{hash}, language => $r->{lang},
        node_count => scalar @{ $r->{out}{nodes} }, extraction_version => EXTRACTION_VERSION });
}

sub _index_file ($self, $path, %opt) {
    my $src  = $self->_read($path) // return 0;   # vanished mid-scan -> skip
    my $hash = sha1_hex($src);
    return 0 if !$opt{force} && $self->store->file_fresh($path, $hash, EXTRACTION_VERSION);   # unchanged + same extractor
    # Parse/extract BEFORE mutating the graph, so a parse failure leaves the
    # file's existing nodes intact rather than stranding it (deleted but unre-added).
    $self->_store_extract($self->_extract_src($path, $src, $hash));
    return 1;
}

sub _ncpus {
    if (open my $fh, '<', '/proc/cpuinfo') { my $n = grep { /^processor\s*:/ } <$fh>; return $n || 1 }
    return 1;   # non-Linux: default serial, use --jobs N to parallelize
}

# Workers to use for $nfiles: an explicit `jobs` wins (1 = serial); auto-mode
# only parallelizes a tree big enough to outweigh fork/serialize overhead.
sub _effective_jobs ($self, $nfiles) {
    return $self->jobs if $self->jobs;
    my $c = _ncpus();
    return 1 if $c <= 1 || $nfiles < 64;   # small tree / single core: serial
    return $c > 8 ? 8 : $c;                 # cap parallelism at 8 workers
}

sub index_all ($self) {
    my @files = $self->_perl_files;
    my $jobs  = $self->_effective_jobs(scalar @files);
    my $n = $jobs > 1 ? $self->_index_parallel(\@files, $jobs)
                      : do { my $c = 0; $c += $self->_index_file($_) for @files; $c };
    my $deps = $self->deps ? $self->_index_deps : 0;   # add CPAN API nodes before resolving
    App::PerlGraph::Resolver->new(store => $self->store)->resolve_all;
    $self->_enrich if $self->runtime;
    my $emb = $self->embed ? $self->_embed_all : 0;
    return { files => scalar(@files), reindexed => $n, ($deps ? (deps => $deps) : ()), ($emb ? (embedded => $emb) : ()) };
}

# Compute semantic-search embeddings for the named symbols (function/method/package/
# class/constant) from a short "document" -- the qualified name (its identifier words
# carry meaning), signature, and docstring. Requires a local provider (App::PerlGraph::
# Embed); if none is available it warns and skips rather than failing the index. Returns
# the number of symbols embedded.
sub _embed_all ($self) {
    require App::PerlGraph::Embed;
    unless (App::PerlGraph::Embed->available) {
        warn "pcg: --embed skipped -- no local embedding provider (set PCG_EMBED_CMD or run Ollama; see docs)\n";
        return 0;
    }
    my $s = $self->store;
    my @nodes = grep { defined $_->{qualified_name} }
                map  { $s->all_nodes($_) } qw(function method package class constant);
    return 0 unless @nodes;
    my @docs = map { _embed_doc($_) } @nodes;
    my $total = 0;
    # batch so a huge codebase doesn't build one giant provider request
    for (my $i = 0; $i < @nodes; $i += 128) {
        my $hi   = $i + 127 < $#nodes ? $i + 127 : $#nodes;
        my $vecs = App::PerlGraph::Embed->embed([ @docs[$i .. $hi] ]);
        unless ($vecs) { warn "pcg: embedding provider failed mid-run; stored $total so far\n"; last }
        $s->upsert_embedding($nodes[$i + $_]{id}, $vecs->[$_]) for 0 .. $#$vecs;
        $total += @$vecs;
    }
    $s->prune_embeddings;   # drop embeddings for symbols deleted since last --embed
    return $total;
}

sub _embed_doc ($n) {
    my $doc = join ' ', grep { defined && length } $n->{qualified_name}, $n->{signature}, $n->{docstring};
    $doc =~ s/\s+/ /g;
    return $doc;
}

# --- cross-distribution indexing (--deps) ------------------------------------
# Add the PUBLIC API (package + non-_ subs/methods/constants, plus extends edges
# for the MRO) of the CPAN modules the project use's / inherits from, located in
# @INC WITHOUT loading any code. So calls into a dependency (Foo->new->bar,
# $self->inherited) resolve into real nodes instead of staying opaque. CPAN nodes
# carry metadata.cpan so the "your code" queries can skip them.
my %DEP_SKIP = map { $_ => 1 } qw(strict warnings utf8 feature lib vars overload
    constant parent base mro experimental version Exporter POSIX);

sub _index_deps ($self) {
    my $s = $self->store;
    my %project = map { ($_->{qualified_name} => 1) } $s->all_nodes('package', 'class');
    my %done; my $count = 0;
    my @queue = $self->_external_targets(\%project);
    while (@queue && $count < 1000) {                          # bound the crawl
        my $mod = shift @queue;
        next if $done{$mod}++ || $project{$mod} || $DEP_SKIP{$mod};
        my $file = $self->_find_inc($mod)       or next;       # not installed -> skip
        my $out  = $self->_extract_dep($file)   or next;       # fail-soft parse
        $count++;
        for my $n (@{ $out->{nodes} }) {
            next unless ($n->{kind} // '') =~ /\A(?:package|class|function|method|constant)\z/;
            next if ($n->{visibility} // '') eq 'private';     # public surface only
            $n->{metadata} = { %{ $n->{metadata} // {} }, cpan => 1 };
            $s->insert_node($n);
        }
        for my $e (@{ $out->{edges} }) {                       # keep inheritance (for the MRO); drop the rest
            next unless ($e->{kind} // '') =~ /\A(?:extends|implements)\z/;
            $s->insert_edge($e);
            my $p = ($e->{metadata} // {})->{name};
            push @queue, $p if defined $p && !$done{$p} && !$project{$p};
        }
    }
    return $count;
}

# Distinct external module names the project depends on: those it use's (imports
# edges) plus the classes it inherits from (extends/implements), minus its own.
sub _external_targets ($self, $project) {
    my $s = $self->store;
    my %m;
    for my $e ($s->edges_of_kind('imports')) {
        my $mod = ($e->{metadata} // {})->{module};
        $m{$mod} = 1 if defined $mod && !$project->{$mod};
    }
    for my $kind (qw(extends implements)) {
        for my $e ($s->edges_of_kind($kind)) {
            my $name = ($e->{metadata} // {})->{name};
            $m{$name} = 1 if defined $name && !$project->{$name};
        }
    }
    return keys %m;
}

has _inc_dirs => (is => 'lazy');
sub _build__inc_dirs ($self) {   # carton/local::lib first, then the running perl's @INC
    return [ grep { -d } path($self->root)->child('local/lib/perl5')->stringify, @INC ];
}

# Locate Module::Name as a file in @INC -- NO require (dependency code is never run).
sub _find_inc ($self, $mod) {
    return undef unless $mod =~ /\A\w+(?:::\w+)*\z/;
    (my $rel = $mod) =~ s{::}{/}g; $rel .= '.pm';
    for my $dir (@{ $self->_inc_dirs }) { my $f = "$dir/$rel"; return $f if -f $f }
    return undef;
}

sub _extract_dep ($self, $file) {
    my $src = eval { path($file)->slurp_raw };
    return undef unless defined $src && length($src) && length($src) <= 2_000_000;   # skip huge/generated
    my $tree = eval { $self->parser->parse_string($src) } or return undef;           # fail-soft
    return eval { App::PerlGraph::Extractor->new(file_path => $file, source => $src)->extract($tree) };
}

# Parse + extract across $jobs forked workers (the parse phase is ~all of the
# index cost and is per-file independent), then insert serially in the parent
# (one SQLite writer, unchanged insert/FTS path). Unchanged files are skipped
# via the hashes read once before forking. A worker that dies has its chunk
# reprocessed serially, so no file is ever silently dropped.
sub _index_parallel ($self, $files, $jobs) {
    my %known = $self->store->file_states;                      # path => { hash, extraction_version } (skip unchanged + same extractor)
    my @chunk; push @{ $chunk[$_ % $jobs] }, $files->[$_] for 0 .. $#$files;
    my $tmp = File::Temp->newdir('pcg-idx-XXXXXX', TMPDIR => 1);

    my @pids;
    for my $i (0 .. $jobs - 1) {
        my $pid = fork;
        if (!defined $pid) {                                    # fork failed -> serial fallback
            warn "pcg index: fork failed ($!); indexing serially\n";
            waitpid $_->[0], 0 for @pids;                       # reap workers already forked (no zombies in the long-lived MCP server)
            my $n = 0; $n += $self->_index_file($_) for @$files; return $n;
        }
        if (!$pid) {                                            # CHILD: parse its chunk, no DB writes
            # Wrap the WHOLE body: any die (parser/extract/nstore) must still reach
            # POSIX::_exit, never escape this block to run inherited parent code (under
            # the long-lived MCP server's outer eval a stray die would turn the child
            # into a rogue second server on the shared stdout). A non-zero exit just
            # makes the parent redo this chunk serially (see the reaper below).
            my $ok = eval {
                $self->{parser} = App::PerlGraph::Parser->new;  # fresh parser, not the inherited C state
                my @out;
                for my $f (@{ $chunk[$i] // [] }) {
                    my $src  = $self->_read($f) // next;
                    my $hash = sha1_hex($src);
                    my $k = $known{$f};
                    push @out, $self->_extract_src($f, $src, $hash)
                        unless $k && ($k->{hash} // '') eq $hash && ($k->{extraction_version} // 0) == EXTRACTION_VERSION;
                }
                nstore(\@out, "$tmp/$i");
                1;
            };
            POSIX::_exit($ok ? 0 : 1);                          # _exit: never run the inherited DB handle's destructor
        }
        push @pids, [$pid, $i];
    }

    my ($n, @failed) = (0);
    for my $pw (@pids) {
        my ($pid, $i) = @$pw;
        waitpid $pid, 0;
        my $ok = ($? == 0) && -e "$tmp/$i";
        my $res = $ok ? eval { retrieve("$tmp/$i") } : undef;
        if ($res) { for my $r (@$res) { $self->_store_extract($r); $n++ } }
        else      { push @failed, @{ $chunk[$i] // [] } }       # worker died/corrupt -> redo serially
    }
    if (@failed) {
        warn "pcg index: ", scalar(@failed), " file(s) reprocessed serially after a worker failure\n";
        $n += $self->_index_file($_) for @failed;
    }
    return $n;
}

sub sync ($self) {
    my $s = $self->store;
    my @files = $self->_perl_files;
    my %on_disk = map { $_ => 1 } @files;
    my @deleted = grep { !$on_disk{$_} } $s->file_paths;
    my @changed = grep { $self->_file_changed($_) } @files;
    # split new-vs-modified by whether the file was already known (before re-extraction)
    my @added    = grep { !defined $s->file_hash($_) } @changed;
    my %is_added = map { $_ => 1 } @added;
    my @modified = grep { !$is_added{$_} } @changed;

    # Capture the dependents (callers/referencers) of everything that will change
    # BEFORE mutating, so their edges still join to the soon-to-be-removed nodes.
    # Renamed/removed targets leave dangling edges; deletes drop them outright --
    # force-re-indexing the dependents re-derives both correctly via resolve_all.
    my %touched = map { $_ => 1 } @changed, @deleted;
    my @deps = grep { !$touched{$_} } $s->dependents_of(keys %touched);

    $s->forget_file($_)                for @deleted;          # purge deleted files
    $self->_index_file($_)             for @changed;          # re-extract changed files
    $self->_index_file($_, force => 1) for @deps;             # refresh dependents' edges

    my $touched_any = @changed || @deleted || @deps;
    App::PerlGraph::Resolver->new(store => $s)->resolve_all if $touched_any;
    $self->_enrich if $self->runtime && $touched_any;
    return { files => scalar(@files), reindexed => scalar(@changed),
             dependents => scalar(@deps), deleted => scalar(@deleted),
             changes => { added => \@added, changed => \@modified, deleted => \@deleted, dependents => \@deps } };
}

# --- runtime enrichment (opt-in; loads code in a forked child, fail-soft) ---
sub _enrich ($self) {
    my $s = $self->store;
    my @pkg_nodes = $s->package_nodes;
    return unless @pkg_nodes;
    my %seen; my @packages = grep { !$seen{$_}++ } map { $_->{qualified_name} } @pkg_nodes;
    my @lib_dirs = $self->_lib_dirs(@pkg_nodes);
    my @pm_files = map { path($self->root)->child($_)->absolute->stringify } grep { /\.pm\z/ } $s->module_files;
    return unless @pm_files;
    my $res = App::PerlGraph::Runtime->new(lib_dirs => \@lib_dirs)->introspect(\@pm_files, \@packages)
        or return;   # fail-soft: keep the static graph
    $self->_merge_runtime($res);
}

sub _lib_dirs ($self, @pkg_nodes) {
    my %dirs;
    for my $n (@pkg_nodes) {
        my $rel = ($n->{qualified_name} =~ s{::}{/}gr) . '.pm';
        my $fp  = $n->{file_path} // next;
        if ($fp =~ m{\Q$rel\E\z}) {
            (my $d = $fp) =~ s{/?\Q$rel\E\z}{};
            $dirs{ path($self->root)->child($d eq '' ? '.' : $d)->absolute->stringify } = 1;
        }
    }
    return keys %dirs;
}

sub _merge_runtime ($self, $res) {
    my $s = $self->store;
    for my $n (@{ $res->{nodes} }) {
        my @same = $s->nodes_by_qname($n->{qualified_name});
        # A runtime `field` (Moo/Moose attribute storage) may coexist with a
        # static accessor *method* of the same name -- different facets of one
        # attribute -- so only a static `field` represents it. For every other
        # kind, any same-qname static node already represents the symbol (e.g. a
        # static `function` is the same sub the symtab pass reports as `method`).
        if ($n->{kind} eq 'field') { next if grep { ($_->{kind} // '') eq 'field' } @same }
        else                       { next if @same }
        my ($pkgnode) = $s->nodes_by_qname($n->{package} // '');
        my $file = $pkgnode ? $pkgnode->{file_path} : undef;
        my $id = node_id({ kind => $n->{kind}, qualified_name => $n->{qualified_name}, file_path => $file });
        $s->insert_node({ id => $id, kind => $n->{kind}, name => $n->{name},
            qualified_name => $n->{qualified_name}, file_path => $file, language => 'perl',
            metadata => { provenance => $n->{provenance}, %{ $n->{metadata} // {} } } });
        $s->upsert_edge({ source => $pkgnode->{id}, target => $id, kind => 'contains',
            provenance => $n->{provenance} }) if $pkgnode;   # containment for runtime-only nodes
    }
    for my $e (@{ $res->{edges} }) {
        my ($src) = $s->nodes_by_qname($e->{source_qname}) or next;
        my ($tgt) = $s->nodes_by_qname($e->{target_qname}) or next;
        $s->upsert_edge({ source => $src->{id}, target => $tgt->{id}, kind => $e->{kind},
            provenance => $e->{provenance}, line => $e->{line}, metadata => $e->{metadata} });
    }
}

1;

__END__

=head1 NAME

App::PerlGraph::Indexer - build and incrementally update the graph from a directory

=head1 DESCRIPTION

Walks a project, parses each file (optionally across forked workers), stores the graph and runs the resolver; C<sync> does incremental updates of changed files and their dependents.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
