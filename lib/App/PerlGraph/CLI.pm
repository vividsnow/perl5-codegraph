package App::PerlGraph::CLI;
use v5.36;
our $VERSION = q{0.029};
use Path::Tiny qw(path);
use Cpanel::JSON::XS ();
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Parser;   # _cmd_status probes the parser directly
use App::PerlGraph::Watcher;
use App::PerlGraph::Query;
use App::PerlGraph::Format;
use App::PerlGraph::MCP;
use App::PerlGraph::Installer;

sub _db_path ($root) {
    path($root)->child('.pcg')->mkpath;
    return path($root)->child('.pcg/graph.db')->stringify;
}

sub _store ($root) {
    my $s = App::PerlGraph::Store->new(path => _db_path($root));
    $s->init;
    return $s;
}

# A read-only Query over an EXISTING graph. Unlike _store it never creates a
# .pcg/ -- a query before `pcg index` should say so, not silently make an empty
# index. Returns undef (after printing guidance) when there is no graph.
sub _query ($root) {
    my $db = path($root)->child('.pcg/graph.db');
    unless ($db->exists) {
        print STDERR "No index found in $root -- run `pcg index $root` first.\n";
        return undef;
    }
    return App::PerlGraph::Query->new(store => App::PerlGraph::Store->new(path => "$db")->init);
}

my $USAGE = <<'U';
usage: pcg <command> [args] [path]
  index [--runtime] [--deps] [--jobs N] [--max-file-size SZ]  build/refresh the graph
        (--deps: also index the public API of used CPAN modules from @INC, so calls
         into dependencies resolve; --jobs: parse workers; --max-file-size 1M: skip huge files)
  sync  [--runtime]     incremental update
  watch [--interval N] [--poll] [--json] [--once]  re-index on change (inotify on Linux,
        else poll; Ctrl-C to stop; --once syncs a single time and exits). --json emits one
        {added,changed,deleted,affected_tests} event per change for an agent to react to
  explore <query>       matching symbols with source + relationships
  node <symbol>         a symbol's source + callers/callees
  search <query>        symbol search (locations)
  callers|callees|impact <symbol>
  path <A> <B>          shortest call path from A to B
  affected [--tests] [--stdin] [--since REF] [--path DIR] <files>   files/tests impacted by a change
        (--since REF: take the changed files from `git diff --name-only REF`)
  unused [--all]        subs nothing references (dead-code candidates)
  untested [module]     public API symbols no test statically reaches
  deps [module]         module dependency graph (imports / inheritance)
  cycles                circular module dependencies
  hotspots [--limit N]  fan-in (+ blast radius), fan-out, cyclomatic-complexity, and most-coupled-module leaders
  risk [--limit N] [--since REF]   git churn x fan-in: frequently-changed + widely-depended-upon code
        (--since REF: count only churn from commits since REF -- risk on the current branch)
  cochange [--min-support N] [--limit N] [--max-files N]   files that change together (logical coupling)
  diff <ref>            structural diff vs a git ref: added/removed/re-signatured symbols (+ breaking)
  review <ref>          PR review: diff + blast radius + tests to run + breaking changes, in one report
  api <module>          a module's public/exported surface
  covers <symbol>       which tests exercise a symbol (reverse of affected --tests)
  unresolved [--name M] [--limit N] [--by-receiver]   opaque $obj->method calls with
                        candidate definitions (an agent resolves these via the MCP pcg_resolve
                        tool); --by-receiver groups by receiver + suggests its class
  export [--format dot|mermaid|json] [--around SYM] [--depth N]   render the graph
  status                node/edge/provenance counts
  serve --mcp [--watch] [path]   run the MCP server (stdio JSON-RPC; --watch auto-syncs)
  lsp [path]            run a Language Server (go-to-def / find-refs / hover, over stdio)
  install | uninstall   (de)register the MCP server with Claude Code
U

sub _usage { print STDERR $USAGE; return 2 }

sub run ($class, @argv) {
    my $cmd = shift @argv // 'help';
    if ($cmd =~ /^(?:help|--help|-h)$/)        { print $USAGE; return 0 }
    if ($cmd =~ /^(?:version|--version|-v)$/)  { say "pcg (App::PerlGraph) $VERSION"; return 0 }
    my %d = (
        index   => \&_cmd_index,
        sync    => \&_cmd_sync,
        watch   => \&_cmd_watch,
        serve   => \&_cmd_serve,
        lsp     => \&_cmd_lsp,
        search  => \&_cmd_search,
        node    => \&_cmd_node,
        explore => \&_cmd_explore,
        callers => \&_cmd_callers,
        callees => \&_cmd_callees,
        impact    => \&_cmd_impact,
        path      => \&_cmd_path,
        affected  => \&_cmd_affected,
        unused    => \&_cmd_unused,
        untested  => \&_cmd_untested,
        deps      => \&_cmd_deps,
        cycles    => \&_cmd_cycles,
        hotspots  => \&_cmd_hotspots,
        risk      => \&_cmd_risk,
        cochange  => \&_cmd_cochange,
        diff      => \&_cmd_diff,
        review    => \&_cmd_review,
        api       => \&_cmd_api,
        covers    => \&_cmd_covers,
        unresolved => \&_cmd_unresolved,
        export    => \&_cmd_export,
        status    => \&_cmd_status,
        install   => \&_cmd_install,
        uninstall => \&_cmd_uninstall,
    );
    my $h = $d{$cmd} or return _usage();
    return $h->(@argv) // 0;
}

sub _cmd_index (@args) {
    my $runtime = grep { $_ eq '--runtime' } @args;
    my $deps    = grep { $_ eq '--deps' } @args;
    my ($jobs, $maxsz, @rest);
    for (my @a = grep { $_ ne '--runtime' && $_ ne '--deps' } @args; @a; ) {
        my $x = shift @a;
        if    ($x eq '--jobs')          { $jobs = shift @a; return _usage() unless defined $jobs && $jobs =~ /^[0-9]+$/ && $jobs >= 1 }
        elsif ($x eq '--max-file-size') { my $v = shift @a; return _usage() unless defined $v && $v =~ /^(\d+(?:\.\d+)?)([KMG]?)$/i;
                                          $maxsz = int($1 * { '' => 1, K => 1e3, M => 1e6, G => 1e9 }->{ uc $2 }) }
        else { push @rest, $x }
    }
    return _usage() if grep { /^--/ } @rest;          # reject unknown flags (don't treat a typo as the root)
    my ($root) = @rest;
    $root //= '.';
    my $stats = App::PerlGraph::Indexer->new(store => _store($root), root => $root,
        runtime => $runtime, deps => $deps, ($jobs ? (jobs => $jobs) : ()), ($maxsz ? (max_file_size => $maxsz) : ()))->index_all;
    say "indexed $stats->{files} files ($stats->{reindexed} (re)parsed)"
        . ($stats->{deps} ? " + $stats->{deps} CPAN deps" : "") . ($runtime ? " + runtime enrichment" : "");
    return 0;
}

sub _cmd_sync (@args) {
    my $runtime = grep { $_ eq '--runtime' } @args;
    my @rest    = grep { $_ ne '--runtime' } @args;
    return _usage() if grep { /^--/ } @rest;          # reject unknown flags (don't treat a typo as the root)
    my ($root) = @rest;
    $root //= '.';
    my $stats = App::PerlGraph::Indexer->new(store => _store($root), root => $root, runtime => $runtime)->sync;
    say "synced: $stats->{reindexed} file(s) reindexed"
        . ($stats->{dependents} ? ", $stats->{dependents} dependent(s) refreshed" : "")
        . ($stats->{deleted}    ? ", $stats->{deleted} deleted"                   : "")
        . ($runtime ? " + runtime enrichment" : "");
    return 0;
}

sub _cmd_watch (@args) {
    my ($interval, $once, $poll, $json, $root) = (2, 0, 0, 0, undef);
    while (@args) {
        my $a = shift @args;
        if    ($a eq '--interval') { $interval = shift @args; return _usage() unless defined $interval && $interval =~ /^[0-9]+$/ && $interval > 0 }
        elsif ($a eq '--once')     { $once = 1 }
        elsif ($a eq '--poll')     { $poll = 1 }
        elsif ($a eq '--json')     { $json = 1 }
        elsif ($a =~ /^--/)        { return _usage() }   # unknown flag (don't treat a typo as the root, or hang in the loop)
        else  { $root = $a }
    }
    $root //= '.';
    my $idx = App::PerlGraph::Indexer->new(store => _store($root), root => $root);
    if ($once) {
        my $changed = _watch_report($idx, $idx->sync, $json);
        say "synced: no changes" if !$changed && !$json;
        return 0;
    }

    # event-driven on Linux (inotify), portable mtime-polling elsewhere / with --poll
    STDOUT->autoflush(1);   # progress must appear live even when redirected (pcg watch > log)
    my $watcher = App::PerlGraph::Watcher->new(indexer => $idx, interval => $interval, poll => $poll);
    unless ($json) {
        my $how = $watcher->backend eq 'poll' ? "poll every ${interval}s" : "inotify, " . $watcher->nwatched . " dirs";
        say "watching $root ($how; Ctrl-C to stop)";
    }
    local $SIG{INT} = sub { say "\nstopped." unless $json; exit 0 };
    while (1) {
        $watcher->wait_for_change;                       # blocks until a relevant change
        _watch_report($idx, $idx->sync, $json);
    }
}

# Report a sync to the watch stream. With $json, one JSON event per change --
# { added, changed, deleted, affected_tests } -- so a monitoring agent can react;
# otherwise a human-readable line that (unlike before) also reports deletions.
# Returns the number of changed paths (0 = nothing happened, no output).
sub _watch_report ($idx, $stats, $json) {
    my $c = $stats->{changes};
    my @touched = (@{ $c->{added} }, @{ $c->{changed} }, @{ $c->{deleted} });
    return 0 unless @touched;
    if ($json) {
        my @tests = App::PerlGraph::Query->new(store => $idx->store)->affected(\@touched, tests_only => 1);
        print Cpanel::JSON::XS->new->canonical->encode(
            { added => $c->{added}, changed => $c->{changed}, deleted => $c->{deleted}, affected_tests => \@tests }), "\n";
    }
    else {
        my @bits;
        push @bits, scalar(@{ $c->{added} })      . " added"        if @{ $c->{added} };
        push @bits, scalar(@{ $c->{changed} })    . " changed"      if @{ $c->{changed} };
        push @bits, scalar(@{ $c->{deleted} })    . " deleted"      if @{ $c->{deleted} };
        push @bits, scalar(@{ $c->{dependents} }) . " dependent(s)" if @{ $c->{dependents} };
        say scalar(localtime) . " -- synced: " . join(', ', @bits);
    }
    return scalar @touched;
}

sub _cmd_serve (@args) {
    my $watch = grep { $_ eq '--watch' } @args;
    my ($root) = grep { $_ !~ /^--/ } @args;       # skip --mcp / --watch flags
    $root //= '.';
    # Always give the server an indexer over a (possibly-empty) store: the
    # pcg_index / pcg_sync tools bootstrap and refresh the graph in-session, so
    # the server works even with no pre-existing index (no restart needed).
    my $indexer = App::PerlGraph::Indexer->new(store => _store($root), root => $root);
    App::PerlGraph::MCP->new(indexer => $indexer, base => $root, watch => $watch)->run;
    return 0;
}

sub _cmd_lsp (@args) {
    my ($root) = grep { $_ !~ /^--/ } @args;
    $root //= '.';
    my $q = _query($root) or return 1;
    require App::PerlGraph::LSP;
    App::PerlGraph::LSP->new(query => $q, root => $root)->run;
    return 0;
}

sub _cmd_search ($query = undef, $root = '.') {
    return _usage() unless defined $query;
    my $q = _query($root) or return 1;
    print App::PerlGraph::Format::search($query, [ $q->search($query) ]);
    return 0;
}

sub _cmd_node ($symbol = undef, $root = '.') {
    return _usage() unless defined $symbol;
    my $q = _query($root) or return 1;
    print App::PerlGraph::Format::node_view($symbol, [ $q->node_view($symbol) ], $root);
    return 0;
}

sub _cmd_explore ($query = undef, $root = '.') {
    return _usage() unless defined $query;
    my $q = _query($root) or return 1;
    print App::PerlGraph::Format::explore($query, [ $q->explore($query) ], $root);
    return 0;
}

sub _cmd_callers ($symbol = undef, $root = '.') {
    return _usage() unless defined $symbol;
    my $q = _query($root) or return 1;
    print App::PerlGraph::Format::callers($symbol, [ $q->callers($symbol) ]);
    return 0;
}

sub _cmd_callees ($symbol = undef, $root = '.') {
    return _usage() unless defined $symbol;
    my $q = _query($root) or return 1;
    print App::PerlGraph::Format::callees($symbol, [ $q->callees($symbol) ]);
    return 0;
}

sub _cmd_impact ($symbol = undef, $root = '.') {
    return _usage() unless defined $symbol;
    my $q = _query($root) or return 1;
    print App::PerlGraph::Format::impact($symbol, [ $q->impact($symbol) ]);
    return 0;
}

sub _cmd_path ($from = undef, $to = undef, $root = '.') {
    return _usage() unless defined $from && defined $to;
    my $q = _query($root) or return 1;
    print App::PerlGraph::Format::path($from, $to, [ $q->path($from, $to) ]);
    return 0;
}

sub _cmd_install (@) {
    App::PerlGraph::Installer->new->install;
    say "Registered pcg with Claude Code: MCP server (~/.claude.json) + tool allow-list";
    say "+ a 'perl-codegraph' skill (~/.claude/skills/) so agents auto-use the graph on";
    say "Perl codebases. Restart Claude Code to load it.";
    return 0;
}

sub _cmd_uninstall (@) {
    App::PerlGraph::Installer->new->uninstall;
    say "Removed pcg from Claude Code config (MCP server, allow-list, and skill).";
    return 0;
}

sub _cmd_affected (@args) {
    my (%flag, @files);
    while (@args) {
        my $a = shift @args;
        if    ($a eq '--tests') { $flag{tests} = 1 }
        elsif ($a eq '--stdin') { $flag{stdin} = 1 }
        elsif ($a eq '--since') { $flag{since} = shift @args; return _usage() unless defined $flag{since} }
        elsif ($a eq '--path')  { $flag{path}  = shift @args; return _usage() unless defined $flag{path} }
        else { push @files, $a }
    }
    return _usage() if grep { /^--/ } @files;        # reject unknown flags (don't silently treat a typo as a file)
    if ($flag{stdin}) { while (my $l = <STDIN>) { chomp $l; push @files, $l if length $l } }
    if (defined $flag{since}) {   # same git path as diff/review: --relative + Perl-file filter
        require App::PerlGraph::Git;
        push @files, @{ App::PerlGraph::Git->new(root => $flag{path} // '.')->changed($flag{since}) };
    }
    return _usage() unless @files;
    my $q = _query($flag{path} // '.') or return 1;
    say for $q->affected(\@files, tests_only => $flag{tests});
    return 0;
}

sub _cmd_deps ($module = undef, $root = '.') {
    my $q = _query($root) or return 1;
    print App::PerlGraph::Format::deps([ $q->deps($module) ]);
    return 0;
}

sub _cmd_untested ($module = undef, $root = '.') {
    my $q = _query($root) or return 1;
    print App::PerlGraph::Format::untested([ $q->untested($module) ]);
    return 0;
}

sub _cmd_cycles ($root = '.') {
    my $q = _query($root) or return 1;
    print App::PerlGraph::Format::cycles([ $q->cycles ]);
    return 0;
}

sub _cmd_hotspots (@args) {
    my (%opt, @pos);
    while (@args) {
        my $a = shift @args;
        if ($a eq '--limit') { $opt{limit} = shift @args;
            return _usage() unless defined $opt{limit} && $opt{limit} =~ /^\d+$/ && $opt{limit} >= 1 }
        else { push @pos, $a }
    }
    return _usage() if grep { /^--/ } @pos;
    my $q = _query($pos[0] // '.') or return 1;
    print App::PerlGraph::Format::hotspots($q->hotspots(%opt));
    return 0;
}

sub _cmd_risk (@args) {
    my ($since, %opt, @pos);
    while (@args) {
        my $a = shift @args;
        if ($a eq '--limit') { $opt{limit} = shift @args;
            return _usage() unless defined $opt{limit} && $opt{limit} =~ /^\d+$/ && $opt{limit} >= 1 }
        elsif ($a eq '--since') { $since = shift @args;
            return _usage() unless defined $since && length $since }
        else { push @pos, $a }
    }
    return _usage() if grep { /^--/ } @pos;
    my $root = $pos[0] // '.';
    my $q = _query($root) or return 1;
    require App::PerlGraph::Git;
    my $git = App::PerlGraph::Git->new(root => $root);
    unless ($git->available) { print STDERR "Not a git repository: $root (risk needs git history).\n"; return 1 }
    print App::PerlGraph::Format::risk([ $q->risk($git->churn($since ? (since => $since) : ()), %opt) ]);
    return 0;
}

sub _cmd_review (@args) {
    return _usage() if grep { /^--/ } @args;
    my ($ref, $root) = @args;
    return _usage() unless defined $ref && length $ref;
    $root //= '.';
    my $q = _query($root) or return 1;                 # affected/callers need the index
    require App::PerlGraph::Git;
    my $git = App::PerlGraph::Git->new(root => $root);
    unless ($git->available) { print STDERR "Not a git repository: $root (review needs git).\n"; return 1 }
    my $parser = eval { App::PerlGraph::Parser->new } or do { print STDERR "parser unavailable: $@"; return 1 };
    require App::PerlGraph::Review;
    my $rv = App::PerlGraph::Review->new(root => $root, ref => $ref, parser => $parser, store => $q->store)->review;
    print App::PerlGraph::Format::review($rv);
    return 0;
}

sub _cmd_diff (@args) {
    return _usage() if grep { /^--/ } @args;
    my ($ref, $root) = @args;
    return _usage() unless defined $ref && length $ref;
    $root //= '.';
    require App::PerlGraph::Git;
    my $git = App::PerlGraph::Git->new(root => $root);
    unless ($git->available) { print STDERR "Not a git repository: $root (diff needs git).\n"; return 1 }
    my $parser = eval { App::PerlGraph::Parser->new } or do { print STDERR "parser unavailable: $@"; return 1 };
    require App::PerlGraph::Diff;
    my $d = App::PerlGraph::Diff->new(root => $root, ref => $ref, parser => $parser)->diff;
    print App::PerlGraph::Format::diff($d, $ref);
    return 0;
}

sub _cmd_cochange (@args) {
    my (%opt, @pos);
    while (@args) {
        my $a = shift @args;
        if    ($a eq '--limit')       { $opt{limit}       = shift @args; return _usage() unless defined $opt{limit}       && $opt{limit}       =~ /^\d+$/ && $opt{limit}       >= 1 }
        elsif ($a eq '--min-support') { $opt{min_support} = shift @args; return _usage() unless defined $opt{min_support} && $opt{min_support} =~ /^\d+$/ && $opt{min_support} >= 1 }
        elsif ($a eq '--max-files')   { $opt{max_files}   = shift @args; return _usage() unless defined $opt{max_files}   && $opt{max_files}   =~ /^\d+$/ && $opt{max_files}   >= 2 }
        else { push @pos, $a }
    }
    return _usage() if grep { /^--/ } @pos;
    my $root = $pos[0] // '.';
    my $q = _query($root) or return 1;
    require App::PerlGraph::Git;
    my $git = App::PerlGraph::Git->new(root => $root);
    unless ($git->available) { print STDERR "Not a git repository: $root (cochange needs git history).\n"; return 1 }
    print App::PerlGraph::Format::cochange([ $q->cochange($git->commits, %opt) ]);
    return 0;
}

sub _cmd_api ($module = undef, $root = '.') {
    return _usage() unless defined $module;
    my $q = _query($root) or return 1;
    print App::PerlGraph::Format::api($module, [ $q->api($module) ]);
    return 0;
}

sub _cmd_covers ($symbol = undef, $root = '.') {
    return _usage() unless defined $symbol;
    my $q = _query($root) or return 1;
    print App::PerlGraph::Format::covers($symbol, [ $q->covers($symbol) ]);
    return 0;
}

sub _cmd_unresolved (@args) {
    my (%opt, $by_recv, @pos);
    while (@args) {
        my $a = shift @args;
        if    ($a eq '--name')        { $opt{name}  = shift @args; return _usage() unless defined $opt{name} }
        elsif ($a eq '--limit')       { $opt{limit} = shift @args; return _usage() unless defined $opt{limit} && $opt{limit} =~ /^\d+$/ }
        elsif ($a eq '--by-receiver') { $by_recv = 1 }
        else  { push @pos, $a }
    }
    return _usage() if grep { /^--/ } @pos;
    my $q = _query($pos[0] // '.') or return 1;
    print $by_recv ? App::PerlGraph::Format::resolve_targets([ $q->resolve_targets(%opt) ])
                   : App::PerlGraph::Format::unresolved([ $q->unresolved(%opt) ]);
    return 0;
}

sub _cmd_unused (@args) {
    return _usage() if grep { /^--/ && $_ ne '--all' } @args;   # reject unknown flags
    my $all = grep { $_ eq '--all' } @args;
    my ($root) = grep { $_ !~ /^--/ } @args;
    $root //= '.';
    my $q = _query($root) or return 1;
    print App::PerlGraph::Format::unused([ $q->unused(all => $all) ]);
    return 0;
}

sub _cmd_export (@args) {
    my (%opt, @pos);
    while (@args) {
        my $a = shift @args;
        if    ($a eq '--format') { $opt{format} = shift @args; return _usage() unless defined $opt{format} }
        elsif ($a eq '--around') { $opt{around} = shift @args; return _usage() unless defined $opt{around} }
        elsif ($a eq '--depth')  { $opt{depth}  = shift @args; return _usage() unless defined $opt{depth} && $opt{depth} =~ /^\d+$/ }
        else  { push @pos, $a }
    }
    return _usage() if grep { /^--/ } @pos;          # reject unknown flags (don't treat a typo as the root)
    my $fmt = $opt{format} // 'mermaid';
    return _usage() unless $fmt =~ /^(?:dot|mermaid|json)$/;
    my $q = _query($pos[0] // '.') or return 1;
    print App::PerlGraph::Format::export($q->graph(around => $opt{around}, depth => $opt{depth}), $fmt);
    return 0;
}

sub _cmd_status ($root = '.') {
    # setup health: can we parse at all? (catches a missing grammar or a too-old
    # system libtree-sitter, which otherwise surface as a cryptic parse error)
    if (eval { App::PerlGraph::Parser->new->parse_string("1;\n"); 1 }) {
        say "parser: ok (grammar at " . ($ENV{PCG_TS_PARSER_DIR} // "$ENV{HOME}/.cache/pcg/tree-sitter-perl") . ")";
    }
    else {
        (my $err = $@) =~ s/\s+\z//;
        say "parser: NOT WORKING -- $err";
        say "  -> run ./tools/build-grammar.sh, and ensure a system libtree-sitter >= 0.25";
    }
    # graph state -- never creates the index
    my $db = path($root)->child('.pcg/graph.db');
    unless ($db->exists) { say "graph:  not indexed yet (run `pcg index $root`)"; return 0 }
    my $s = App::PerlGraph::Store->new(path => "$db")->init;
    my ($n) = $s->dbh->selectrow_array('select count(*) from nodes');
    my ($e) = $s->dbh->selectrow_array('select count(*) from edges');
    my ($u)  = $s->dbh->selectrow_array('select count(*) from unresolved_refs');
    my ($md) = $s->dbh->selectrow_array("select count(*) from unresolved_refs where reference_kind = 'method_call'");
    my ($ut) = $s->dbh->selectrow_array("select count(*) from unresolved_refs where file_path like '%.t'");
    say "graph:  nodes=$n edges=$e unresolved=$u"
        . ($u ? " ($md dynamic method-dispatch, @{[ $u - $md ]} bareword calls)" : "");
    say "  -- @{[ $u - $ut ]} in your code, $ut in tests (test calls into CPAN clients are the expected frontier)" if $ut;
    say "  (dynamic method-dispatch is opaque \$obj->method -- `pcg index --runtime` resolves much of it)" if $md;
    my $by = $s->dbh->selectall_arrayref('select provenance, count(*) c from edges group by provenance order by provenance');
    say "  edges by provenance: " . join(', ', map { "$_->[0]=$_->[1]" } @$by) if @$by;
    return 0;
}

1;

__END__

=head1 NAME

App::PerlGraph::CLI - the pcg command-line dispatcher

=head1 DESCRIPTION

Parses @ARGV and dispatches to the pcg subcommands: index, sync, watch, the
read queries (search, node, explore, callers, callees, impact, path, affected,
unused, untested, deps, cycles, hotspots, risk, cochange, diff, review, api,
covers, unresolved), export, status, serve and install/uninstall.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
