package App::PerlGraph::MCP;
use v5.36;
our $VERSION = q{0.029};
use Moo;
use Cpanel::JSON::XS ();
use App::PerlGraph ();
use App::PerlGraph::Format;
use App::PerlGraph::Query ();
use App::PerlGraph::Indexer ();

# A minimal MCP server: newline-delimited JSON-RPC 2.0 over stdio, wrapping the
# Query engine plus index/sync lifecycle tools. `dispatch` is a pure
# request->response function (so it is unit-testable); `run` is the stdio loop.

has indexer     => (is => 'ro');                          # App::PerlGraph::Indexer over the shared store
has query       => (is => 'lazy');                        # read view over indexer's store (built on demand)
has base        => (is => 'ro', default => '.');         # project root, for reading source
has server_name => (is => 'ro', default => 'pcg');
has watch       => (is => 'ro', default => 0);           # lazily re-sync before tool calls
sub _build_query ($self) {
    $self->indexer ? App::PerlGraph::Query->new(store => $self->indexer->store) : undef;
}
has in          => (is => 'ro', default => sub { \*STDIN });
has out         => (is => 'ro', default => sub { \*STDOUT });
has _json       => (is => 'lazy');
sub _build__json ($self) { Cpanel::JSON::XS->new->utf8->canonical }

use constant PROTOCOL_VERSION => '2024-11-05';
use constant INSTRUCTIONS => <<'MD';
`pcg` is a Perl code knowledge graph. Prefer these tools over grep/Read when reasoning about Perl code structure:
pcg_explore (symbols + source + relationships in one call — best first stop), pcg_search (find symbols), pcg_node (a symbol's definition + location), pcg_callers / pcg_callees (who calls X / what X calls), pcg_impact (transitive callers — blast radius), pcg_path (how A reaches B — shortest call chain), pcg_unused (dead-code candidates — subs nothing references), pcg_affected (files/tests impacted by changing given files — CI triage), pcg_deps / pcg_cycles (module dependency graph and circular dependencies), pcg_hotspots (most depended-upon / most complex symbols — review & refactor triage), pcg_risk (git churn x fan-in — frequently-changed + widely-depended-upon code), pcg_cochange (files that change together — logical coupling, incl. hidden), pcg_diff (structural diff vs a git ref), pcg_review (one-call branch/PR review: diff + blast radius + tests to run), pcg_api (a module's public surface), pcg_covers (which tests exercise a symbol), pcg_untested (public API no test reaches). Results are authoritative for statically-resolved relationships.
Lifecycle: if a read tool reports "no index", call pcg_index once to build the graph (no restart needed). After you edit Perl files, call pcg_sync so queries reflect your changes. pcg_status reports the graph's health.
Resolving the unresolvable: most "unresolved" calls are opaque `$obj->method` dispatch static analysis can't tie to a class. pcg_unresolved lists the ones that DO match real candidate methods; infer each receiver's class (read the code if needed) and call pcg_resolve -- prefer the { caller, receiver, class } form, which types a receiver once and resolves all its calls at that site. BEST: pcg_unresolved by_receiver:true does the candidate-narrowing for you -- it groups by receiver and intersects the classes defining every method called on it, so a unique intersection is a near-certain type you just confirm and pass to pcg_resolve. Those edges are marked `llm` and persist across reindex. (pcg_index deps:true first resolves many dependency calls statically.)
MD

my @TOOLS = (
    { name => 'pcg_search', handler => 'search', description => 'Search Perl symbols by name.',
      inputSchema => { type => 'object', properties => { query => { type => 'string', description => 'Symbol name or term' } }, required => ['query'] } },
    { name => 'pcg_node', handler => 'node', description => "A symbol's definition(s): verbatim source + immediate callers/callees.",
      inputSchema => { type => 'object', properties => { symbol => { type => 'string', description => 'Bare name or Foo::bar' } }, required => ['symbol'] } },
    { name => 'pcg_explore', handler => 'explore', description => 'Explore an area: matching symbols with their source and immediate relationships, in one call. Prefer this over grep/Read.',
      inputSchema => { type => 'object', properties => { query => { type => 'string', description => 'Symbol name or term to explore' } }, required => ['query'] } },
    { name => 'pcg_callers', handler => 'callers', description => 'All call sites of a function/method.',
      inputSchema => { type => 'object', properties => { symbol => { type => 'string', description => 'Symbol name' } }, required => ['symbol'] } },
    { name => 'pcg_callees', handler => 'callees', description => 'What a function/method calls.',
      inputSchema => { type => 'object', properties => { symbol => { type => 'string', description => 'Symbol name' } }, required => ['symbol'] } },
    { name => 'pcg_impact', handler => 'impact', description => 'Blast radius: transitive callers of a symbol.',
      inputSchema => { type => 'object', properties => { symbol => { type => 'string', description => 'Symbol name' } }, required => ['symbol'] } },
    { name => 'pcg_path', handler => 'path', description => 'Shortest call path from one symbol to another -- how A reaches B (or that it cannot).',
      inputSchema => { type => 'object', properties => { from => { type => 'string', description => 'Start symbol' }, to => { type => 'string', description => 'Target symbol' } }, required => ['from', 'to'] } },
    { name => 'pcg_unused', handler => 'unused', description => 'Dead-code candidates: defined subs nothing in the indexed code references. The output notes its own blind spots (dynamic/string dispatch, cross-distribution callers). Set all=true to also include exported and lifecycle subs.',
      inputSchema => { type => 'object', properties => { all => { type => 'boolean', description => 'Include exported + lifecycle subs (default false)' } } } },
    { name => 'pcg_affected', handler => 'affected', description => 'Files (or tests, with tests_only) impacted by changing the given files -- the reverse-dependency closure. Pass `files`, and/or `since REF` to take the changed files from `git diff --name-only REF` (CI triage in one call: which tests to run for the diff vs main).',
      inputSchema => { type => 'object', properties => {
          files      => { type => 'array', items => { type => 'string' }, description => 'Changed file paths' },
          tests_only => { type => 'boolean', description => 'Restrict to .t test files (default false)' },
          since      => { type => 'string', description => 'Also include files changed since this git ref (e.g. main)' },
      } } },
    { name => 'pcg_deps', handler => 'deps', description => 'Module dependency graph: which modules each package imports or inherits from. Omit `module` for the whole project, or pass one to focus.',
      inputSchema => { type => 'object', properties => { module => { type => 'string', description => 'Focus on one module (optional)' } } } },
    { name => 'pcg_cycles', handler => 'cycles', description => 'Circular module dependencies -- cycles in the import/inheritance graph.',
      inputSchema => { type => 'object', properties => {} } },
    { name => 'pcg_hotspots', handler => 'hotspots', description => 'Call-graph hotspots, four lists: the most depended-upon symbols (fan-in, each with its transitive blast radius -- change with care), the symbols that make the most calls (fan-out), the most cyclomatically-complex symbols, and the most efferently-coupled modules. Good for review/refactor triage.',
      inputSchema => { type => 'object', properties => { limit => { type => 'integer', description => 'Top N per list (default 15)' } } } },
    { name => 'pcg_risk', handler => 'risk', description => 'History-aware risk: symbols ranked by git churn (commits touching their file) x fan-in (how many depend on them). Frequently-changed AND widely-depended-upon code is the top refactor/test target. With `since`, count only churn from commits since that ref (risk on the current branch). Needs a git work tree.',
      inputSchema => { type => 'object', properties => {
          limit => { type => 'integer', description => 'Top N (default 15)' },
          since => { type => 'string', description => 'Only count churn from commits since this ref (e.g. main)' },
      } } },
    { name => 'pcg_cochange', handler => 'cochange', description => 'Logical (temporal) coupling: code files that change together in git history, ranked by Jaccard of their commit sets. Pairs marked with no static link are HIDDEN coupling the call graph cannot see (a change in one tends to need a change in the other). Needs a git work tree.',
      inputSchema => { type => 'object', properties => {
          limit       => { type => 'integer', description => 'Top N (default 15)' },
          min_support => { type => 'integer', description => 'Min shared commits (default 3)' },
          max_files   => { type => 'integer', description => 'Skip commits touching more than N code files (default 25; filters version-bump sweeps)' },
      } } },
    { name => 'pcg_diff', handler => 'diff', description => 'Structural ("semantic") diff vs a git ref: which functions/methods/constants/packages/classes were added, removed, or had their signature change between <ref> and the working tree -- with breaking changes (removed or re-signatured PUBLIC API) flagged. Ideal for reviewing a branch or PR. Needs a git work tree.',
      inputSchema => { type => 'object', properties => { ref => { type => 'string', description => 'Git ref to compare against (e.g. main, HEAD~3)' } }, required => ['ref'] } },
    { name => 'pcg_review', handler => 'review', description => 'Review a branch/PR in one call: the structural diff vs a git ref (added/removed/re-signatured symbols, breaking PUBLIC API flagged), the blast radius (count of files affected by the change), the tests to run, and -- for each breaking symbol -- how many callers still reference it. Composes the structural diff with the affected-files closure. Needs a git work tree and an index.',
      inputSchema => { type => 'object', properties => { ref => { type => 'string', description => 'Git ref to review against (e.g. main, HEAD~3)' } }, required => ['ref'] } },
    { name => 'pcg_api', handler => 'api', description => "A module's public surface: its exported and public (non-_) functions/methods/constants.",
      inputSchema => { type => 'object', properties => { module => { type => 'string', description => 'Module name' } }, required => ['module'] } },
    { name => 'pcg_covers', handler => 'covers', description => 'Which test files (transitively) exercise a symbol -- the reverse of pcg_affected(tests_only). Limited to statically-resolved calls.',
      inputSchema => { type => 'object', properties => { symbol => { type => 'string', description => 'Symbol name' } }, required => ['symbol'] } },
    { name => 'pcg_untested', handler => 'untested', description => "Untested public API: exported/public functions/methods/constants that no test file statically reaches. Omit `module` for the whole project. (A symbol exercised only via opaque \$obj->method dispatch from a test is invisible to static analysis and may appear here.)",
      inputSchema => { type => 'object', properties => { module => { type => 'string', description => 'Focus on one module (optional)' } } } },
    { name => 'pcg_unresolved', handler => 'unresolved', description => "Opaque `\$obj->method` calls static analysis could not resolve but which DO match candidate methods in the graph -- i.e. the calls you can resolve by inferring the receiver's class. Each lists its real candidates. Set by_receiver=true to instead group by (caller, receiver) and intersect the classes defining EVERY method called on that receiver -- a unique intersection is a near-certain type you can confirm and pass straight to pcg_resolve's { caller, receiver, class } form. Pair with pcg_resolve.",
      inputSchema => { type => 'object', properties => {
          name        => { type => 'string',  description => 'Restrict to this method name (optional; default mode: just its call sites; by_receiver mode: just the receivers that call it)' },
          limit       => { type => 'integer', description => 'Max items to return (default 50, highest-frequency first)' },
          by_receiver => { type => 'boolean', description => 'Group by receiver + suggest its class (the candidate-class intersection), instead of per-call' },
      } } },
    { name => 'pcg_resolve', handler => 'resolve', description => 'Record resolutions for opaque method calls (from pcg_unresolved). Two item forms, both writing `llm`-provenance edges that persist across reindex and NEVER fabricate a method the class lacks: (1) PREFERRED receiver-type form { caller, receiver, class } -- infer the receiver variable\'s class ONCE and every call on it in that caller resolves against the class\'s MRO (one entry resolves $db->query, $db->fetch, ... together); (2) explicit form { caller, method, receiver, target } -- map a single call to one Class::method. Targets/classes must be real (hallucinations are rejected).',
      inputSchema => { type => 'object', properties => {
          resolutions => { type => 'array', description => 'Resolutions to apply (each item uses the receiver-type OR the explicit form)',
              items => { type => 'object', properties => {
                  caller   => { type => 'string', description => 'Calling sub (qualified_name) -- both forms' },
                  receiver => { type => 'string', description => 'Receiver expression, e.g. $db -- both forms' },
                  class    => { type => 'string', description => 'Receiver-type form: the receiver\'s class; resolves ALL its calls at once' },
                  method   => { type => 'string', description => 'Explicit form: the single method name' },
                  target   => { type => 'string', description => 'Explicit form: resolved Class::method (one of the candidates)' },
              }, required => ['caller', 'receiver'] } },
      }, required => ['resolutions'] } },
    # --- lifecycle tools: build / refresh the graph in-session ---
    { name => 'pcg_index', handler => 'index', description => 'Build (or rebuild) the code graph for this project. Run this first if a read tool reports no index, or after large changes. Set runtime=true to also LOAD AND RUN the project code (forked + timeout-guarded) for dynamic-dispatch resolution. Set deps=true to also index the public API of the CPAN modules the project uses (from @INC, without running them), so calls into dependencies resolve.',
      inputSchema => { type => 'object', properties => {
          runtime => { type => 'boolean', description => 'Also run runtime enrichment -- executes the project code; default false' },
          deps    => { type => 'boolean', description => 'Also index used CPAN modules\' public API from @INC (no code run); default false' },
      } } },
    { name => 'pcg_sync', handler => 'sync', description => 'Incrementally refresh the graph after you edit files (re-resolves changed files and their dependents). Call this after changing Perl code so subsequent queries reflect it.',
      inputSchema => { type => 'object', properties => {} } },
    { name => 'pcg_status', handler => 'status', description => 'Graph health: node/edge counts and the edge provenance breakdown, or whether the graph has been built yet.',
      inputSchema => { type => 'object', properties => {} } },
);

# Tool names, for the installer's permission allow-list (single source of truth).
sub tool_names ($class) { map { $_->{name} } @TOOLS }

sub _result ($self, $id, $result) { return { jsonrpc => '2.0', id => $id, result => $result } }
sub _error  ($self, $id, $code, $msg) { return { jsonrpc => '2.0', id => $id, error => { code => $code, message => $msg } } }

sub dispatch ($self, $req) {
    # A well-formed JSON line that isn't an object (a bare number/string/array,
    # which decode accepts via allow_nonref) is not a valid request -> ignore it
    # rather than crash the server loop on $req->{method}.
    return undef unless ref $req eq 'HASH';
    my $method = $req->{method} // '';
    my $id     = $req->{id};
    # JSON-RPC 2.0: a message with no id is a notification — never reply.
    return undef unless defined $id;
    if ($method eq 'initialize') {
        return $self->_result($id, {
            protocolVersion => PROTOCOL_VERSION,
            capabilities    => { tools => {} },
            serverInfo      => { name => $self->server_name, version => $App::PerlGraph::VERSION },
            instructions    => INSTRUCTIONS,
        });
    }
    if ($method eq 'tools/list') {
        return $self->_result($id, { tools => [
            map { +{ name => $_->{name}, description => $_->{description}, inputSchema => $_->{inputSchema} } } @TOOLS
        ] });
    }
    if ($method eq 'tools/call') { return $self->_call_tool($id, $req->{params} // {}) }
    return $self->_error($id, -32601, "Method not found: $method");
}

sub _maybe_sync ($self) {
    return unless $self->watch && $self->indexer;
    my $now = time;
    return if defined $self->{_last_sync} && $now - $self->{_last_sync} < 2;   # debounce
    $self->{_last_sync} = $now;
    eval { $self->indexer->sync };   # fail-soft: stale data beats a crashed server
}

sub _call_tool ($self, $id, $params) {
    $self->_maybe_sync;
    my $name = $params->{name} // '';
    my ($tool) = grep { $_->{name} eq $name } @TOOLS;
    return $self->_error($id, -32602, "Unknown tool: $name") unless $tool;
    my $text = eval { $self->_run_tool($tool->{handler}, $params->{arguments} // {}) };
    return $self->_result($id, { content => [{ type => 'text', text => "Error: $@" }], isError => \1 }) if $@;
    return $self->_result($id, { content => [{ type => 'text', text => $text }] });
}

sub _indexed ($self) {
    my $q = $self->query or return 0;
    my $store = eval { $q->store } or return 1;   # a query with no introspectable store -> assume usable
    return scalar @{ $store->dbh->selectcol_arrayref('select 1 from nodes limit 1') };
}

sub _status_text ($self) {
    my $q = $self->query or return "Graph not built yet -- call pcg_index.";
    return "Graph not built yet -- call pcg_index." unless $self->_indexed;
    my $s = $q->store;
    my ($n)  = $s->dbh->selectrow_array('select count(*) from nodes');
    my ($e)  = $s->dbh->selectrow_array('select count(*) from edges');
    my ($u)  = $s->dbh->selectrow_array('select count(*) from unresolved_refs');
    my ($md) = $s->dbh->selectrow_array("select count(*) from unresolved_refs where reference_kind = 'method_call'");
    my ($ut) = $s->dbh->selectrow_array("select count(*) from unresolved_refs where file_path like '%.t'");
    my $by   = $s->dbh->selectall_arrayref('select provenance, count(*) c from edges group by provenance order by provenance');
    my $prov = @$by ? "\nedges by provenance: " . join(', ', map { "$_->[0]=$_->[1]" } @$by) : "";
    my $uget = $u ? " ($md dynamic method-dispatch, @{[ $u - $md ]} bareword calls; pcg_index with runtime:true, or pcg_unresolved+pcg_resolve, resolves much of the former)" : "";
    my $split = ($u && $ut) ? "\n@{[ $u - $ut ]} unresolved in your code, $ut in tests (test calls into CPAN clients are the expected frontier)" : "";
    return "nodes=$n edges=$e unresolved=$u$uget$split$prov";
}

sub _run_tool ($self, $handler, $args) {
    my $idx = $self->indexer;

    # lifecycle tools operate even before any graph exists
    if ($handler eq 'index') {
        return "No project to index (the server was started without an indexer)." unless $idx;
        my $rt = $args->{runtime} ? 1 : 0;
        my $st = App::PerlGraph::Indexer->new(store => $idx->store, root => $self->base,
            runtime => $rt, deps => ($args->{deps} ? 1 : 0))->index_all;
        return "Indexed $st->{files} files ($st->{reindexed} (re)parsed)"
            . ($st->{deps} ? " + $st->{deps} CPAN deps" : "") . ($rt ? " + runtime enrichment" : "") . ".";
    }
    if ($handler eq 'sync') {
        return "No project to sync (the server was started without an indexer)." unless $idx;
        my $st = $idx->sync;
        return "Synced: $st->{reindexed} reindexed"
            . ($st->{dependents} ? ", $st->{dependents} dependent(s) refreshed" : "")
            . ($st->{deleted}    ? ", $st->{deleted} deleted" : "") . ".";
    }
    return $self->_status_text if $handler eq 'status';

    # read tools require a built graph -- except pcg_diff, which parses git directly
    # (no graph needed), matching the CLI `pcg diff`. pcg_review still needs the index.
    return "No index yet. Call pcg_index first to build the graph for this project."
        unless $self->_indexed || $handler eq 'diff';
    my $q = $self->query;
    my $sym = $args->{symbol} // '';
    return App::PerlGraph::Format::search($args->{query} // '', [ $q->search($args->{query} // '') ]) if $handler eq 'search';
    return App::PerlGraph::Format::callers($sym, [ $q->callers($sym) ]) if $handler eq 'callers';
    return App::PerlGraph::Format::callees($sym, [ $q->callees($sym) ]) if $handler eq 'callees';
    return App::PerlGraph::Format::impact($sym,  [ $q->impact($sym) ])  if $handler eq 'impact';
    return App::PerlGraph::Format::node_view($sym, [ $q->node_view($sym) ], $self->base) if $handler eq 'node';
    return App::PerlGraph::Format::explore($args->{query} // '', [ $q->explore($args->{query} // '') ], $self->base)
        if $handler eq 'explore';
    return App::PerlGraph::Format::unused([ $q->unused(all => $args->{all}) ]) if $handler eq 'unused';
    return App::PerlGraph::Format::path($args->{from} // '', $args->{to} // '', [ $q->path($args->{from} // '', $args->{to} // '') ])
        if $handler eq 'path';
    if ($handler eq 'affected') {
        my $files = ref $args->{files} eq 'ARRAY' ? [ @{ $args->{files} } ] : [];
        if (defined $args->{since} && length $args->{since}) {
            require App::PerlGraph::Git;
            my $git = App::PerlGraph::Git->new(root => $self->base);
            return "`since` needs a git work tree." unless $git->available;
            push @$files, @{ $git->changed($args->{since}) };
        }
        return App::PerlGraph::Format::affected($files, [ $q->affected($files, tests_only => $args->{tests_only}) ]);
    }
    return App::PerlGraph::Format::deps([ $q->deps($args->{module}) ])             if $handler eq 'deps';
    return App::PerlGraph::Format::cycles([ $q->cycles ])                          if $handler eq 'cycles';
    return App::PerlGraph::Format::hotspots($q->hotspots(defined $args->{limit} ? (limit => $args->{limit}) : ())) if $handler eq 'hotspots';
    if ($handler eq 'diff' || $handler eq 'review') {
        require App::PerlGraph::Git; require App::PerlGraph::Diff; require App::PerlGraph::Parser;
        my $git = App::PerlGraph::Git->new(root => $self->base);
        return "This needs a git work tree." unless $git->available;
        my $ref = $args->{ref}; return "a `ref` is required." unless defined $ref && length $ref;
        my $parser = eval { App::PerlGraph::Parser->new } or return "parser unavailable.";
        return App::PerlGraph::Format::diff(
            App::PerlGraph::Diff->new(root => $self->base, ref => $ref, parser => $parser)->diff, $ref)
            if $handler eq 'diff';
        require App::PerlGraph::Review;
        return App::PerlGraph::Format::review(
            App::PerlGraph::Review->new(root => $self->base, ref => $ref, parser => $parser, store => $q->store)->review);
    }
    if ($handler eq 'risk' || $handler eq 'cochange') {
        require App::PerlGraph::Git;
        my $git = App::PerlGraph::Git->new(root => $self->base);
        return "This analysis needs git history -- the project root isn't a git work tree." unless $git->available;
        return App::PerlGraph::Format::risk([ $q->risk($git->churn(defined $args->{since} ? (since => $args->{since}) : ()),
            defined $args->{limit} ? (limit => $args->{limit}) : ()) ])
            if $handler eq 'risk';
        return App::PerlGraph::Format::cochange([ $q->cochange($git->commits,
            (defined $args->{limit}       ? (limit       => $args->{limit})       : ()),
            (defined $args->{min_support} ? (min_support => $args->{min_support}) : ()),
            (defined $args->{max_files}   ? (max_files   => $args->{max_files})   : ())) ]);
    }
    return App::PerlGraph::Format::api($args->{module} // '', [ $q->api($args->{module} // '') ]) if $handler eq 'api';
    return App::PerlGraph::Format::covers($sym, [ $q->covers($sym) ])              if $handler eq 'covers';
    return App::PerlGraph::Format::untested([ $q->untested($args->{module}) ])     if $handler eq 'untested';
    if ($handler eq 'unresolved') {
        return App::PerlGraph::Format::resolve_targets([ $q->resolve_targets(
            ($args->{name}          ? (name  => $args->{name})  : ()),
            (defined $args->{limit} ? (limit => $args->{limit}) : ())) ]) if $args->{by_receiver};
        return App::PerlGraph::Format::unresolved([ $q->unresolved(
            ($args->{name}          ? (name  => $args->{name})  : ()),
            (defined $args->{limit} ? (limit => $args->{limit}) : ()),
        ) ]);
    }
    if ($handler eq 'resolve') {
        my $r = ref $args->{resolutions} eq 'ARRAY' ? $args->{resolutions} : [];
        return App::PerlGraph::Format::resolved($q->resolve($r));
    }
    die "unhandled tool: $handler\n";
}

sub run ($self) {
    my ($in, $out) = ($self->in, $self->out);
    # We do our own UTF-8 via Cpanel::JSON::XS->utf8, so byte-orient both handles
    # regardless of any ambient encoding layer (e.g. bin/pcg sets STDOUT utf8).
    binmode $in,  ':raw';
    binmode $out, ':raw';
    { my $old = select($out); $| = 1; select($old); }   # autoflush responses
    while (defined(my $line = readline $in)) {
        chomp $line;
        next unless length $line;
        my $req = eval { $self->_json->decode($line) } or next;
        my $resp = $self->dispatch($req);
        next unless defined $resp;
        print {$out} $self->_json->encode($resp), "\n";
    }
}

1;

__END__

=head1 NAME

App::PerlGraph::MCP - Model Context Protocol server over the graph

=head1 DESCRIPTION

A hand-rolled JSON-RPC 2.0 server over stdio that exposes the query API as MCP tools for AI agents.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
