package App::PerlGraph::Indexer;
use v5.36;
our $VERSION = q{0.001};
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
has jobs          => (is => 'ro', default => 0);   # 0 = auto-detect; 1 = serial; N = N parse workers
has max_file_size => (is => 'ro', default => 0);   # bytes; 0 = unlimited (index everything)

# shared file-selection vocabulary (the watcher reads these so it and sync agree)
our @IGNORE_DIRS = qw(.git blib _build local vendor node_modules .pcg cover_db);
our $PERL_RX     = qr/\.(?:pl|pm|t|psgi|pod|xs)$/;

sub _perl_files ($self) {
    my $rule = Path::Iterator::Rule->new;
    $rule->skip_dirs(@IGNORE_DIRS);
    $rule->name($PERL_RX);
    my @files = $rule->all($self->root);
    my $cap = $self->max_file_size or return @files;
    my @keep;
    for my $f (@files) {
        my $sz = -s $f // 0;
        # huge files in a tree are almost always generated data (Module::CoreList:
        # 18 subs, 25k data lines) -- skip them rather than spend minutes for ~no graph.
        if ($sz > $cap) { warn sprintf "pcg: skipping %s (%.1f MB > max-file-size %.1f MB)\n", $f, $sz/1e6, $cap/1e6; next }
        push @keep, $f;
    }
    return @keep;
}

# Every watchable directory at/under $from (default root), skipping ignored
# subtrees -- the inotify watcher places one watch per dir (inotify isn't
# recursive). Returns the starting dir plus its surviving descendants.
sub dirs ($self, $from = undef) {
    my $rule = Path::Iterator::Rule->new;
    $rule->skip_dirs(@IGNORE_DIRS);
    $rule->directory;
    return $rule->all($from // $self->root);
}

# Read raw bytes: tree-sitter is byte-oriented, and sha1_hex/the parser XS croak
# on wide characters (real code has UTF-8 in comments/POD/strings). Returns undef
# if the file vanished mid-scan (an editor's atomic save / a `git checkout` during
# `pcg watch`) so the scan skips it instead of crashing the watcher.
sub _read ($self, $path) {
    open my $fh, '<:raw', $path or do { require Errno; return undef if $! == Errno::ENOENT(); die "$path: $!" };
    local $/; <$fh>;
}

sub _file_changed ($self, $path) {
    my $src = $self->_read($path) // return 0;   # vanished mid-scan -> not a change this pass
    return ($self->store->file_hash($path) // '') ne sha1_hex($src);
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
        node_count => scalar @{ $r->{out}{nodes} } });
}

sub _index_file ($self, $path, %opt) {
    my $src  = $self->_read($path) // return 0;   # vanished mid-scan -> skip
    my $hash = sha1_hex($src);
    return 0 if !$opt{force} && ($self->store->file_hash($path) // '') eq $hash;   # unchanged
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
    return ($c > 1 && $nfiles >= 64) ? ($c > 8 ? 8 : $c) : 1;
}

sub index_all ($self) {
    my @files = $self->_perl_files;
    my $jobs  = $self->_effective_jobs(scalar @files);
    my $n = $jobs > 1 ? $self->_index_parallel(\@files, $jobs)
                      : do { my $c = 0; $c += $self->_index_file($_) for @files; $c };
    App::PerlGraph::Resolver->new(store => $self->store)->resolve_all;
    $self->_enrich if $self->runtime;
    return { files => scalar(@files), reindexed => $n };
}

# Parse + extract across $jobs forked workers (the parse phase is ~all of the
# index cost and is per-file independent), then insert serially in the parent
# (one SQLite writer, unchanged insert/FTS path). Unchanged files are skipped
# via the hashes read once before forking. A worker that dies has its chunk
# reprocessed serially, so no file is ever silently dropped.
sub _index_parallel ($self, $files, $jobs) {
    my %known = $self->store->file_hashes;                      # path => hash (skip unchanged)
    my @chunk; push @{ $chunk[$_ % $jobs] }, $files->[$_] for 0 .. $#$files;
    my $tmp = File::Temp->newdir('pcg-idx-XXXXXX', TMPDIR => 1);

    my @pids;
    for my $i (0 .. $jobs - 1) {
        my $pid = fork;
        if (!defined $pid) {                                    # fork failed -> serial fallback
            warn "pcg index: fork failed ($!); indexing serially\n";
            my $n = 0; $n += $self->_index_file($_) for @$files; return $n;
        }
        if (!$pid) {                                            # CHILD: parse its chunk, no DB writes
            $self->{parser} = App::PerlGraph::Parser->new;      # fresh parser, not the inherited C state
            my @out;
            for my $f (@{ $chunk[$i] // [] }) {
                my $src  = $self->_read($f) // next;
                my $hash = sha1_hex($src);
                push @out, $self->_extract_src($f, $src, $hash) unless ($known{$f} // '') eq $hash;
            }
            eval { nstore(\@out, "$tmp/$i") };
            POSIX::_exit($@ ? 1 : 0);                           # _exit: never run the inherited DB handle's destructor
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
             dependents => scalar(@deps), deleted => scalar(@deleted) };
}

# --- runtime enrichment (opt-in; loads code in a forked child, fail-soft) ---
sub _enrich ($self) {
    my $s = $self->store;
    my @pkg_nodes = $s->package_nodes;
    return unless @pkg_nodes;
    my %seen; my @packages = grep { !$seen{$_}++ } map { $_->{qualified_name} } @pkg_nodes;
    my @lib_dirs = $self->_lib_dirs(@pkg_nodes);
    my @pm_files = map { path($_)->absolute->stringify } grep { /\.pm\z/ } $s->module_files;
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
            $dirs{ path($d eq '' ? '.' : $d)->absolute->stringify } = 1;
        }
    }
    return keys %dirs;
}

sub _merge_runtime ($self, $res) {
    my $s = $self->store;
    for my $n (@{ $res->{nodes} }) {
        next if $s->nodes_by_qname($n->{qualified_name});   # already known statically
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
