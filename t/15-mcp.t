use v5.36;
use Test2::V0;
use App::PerlGraph::Store;
use App::PerlGraph::Query;
use App::PerlGraph::MCP;
use Path::Tiny ();

# --- initialize ---
my $mcp0 = App::PerlGraph::MCP->new;   # no query / no index
my $init = $mcp0->dispatch({ jsonrpc => '2.0', id => 1, method => 'initialize', params => {} });
is $init->{result}{protocolVersion}, '2024-11-05', 'protocol version';
is $init->{result}{serverInfo}{name}, 'pcg',        'server name';
ok length($init->{result}{instructions}),           'instructions present';
is ref $init->{result}{capabilities}{tools}, 'HASH', 'tools capability is a hash';

# --- notifications get no response ---
is $mcp0->dispatch({ jsonrpc => '2.0', method => 'notifications/initialized' }), undef, 'notification: no reply';

# --- tools/list ---
my $tl = $mcp0->dispatch({ jsonrpc => '2.0', id => 2, method => 'tools/list' });
my @tools = @{ $tl->{result}{tools} };
is scalar(@tools), 28, 'twenty-eight tools (25 read + index / sync / status)';
ok( (grep { $_->{name} eq 'pcg_callers'  } @tools), 'pcg_callers listed' );
ok( (grep { $_->{name} eq 'pcg_hotspots' } @tools), 'pcg_hotspots listed' );
ok( (grep { $_->{name} eq 'pcg_untested' } @tools), 'pcg_untested listed' );
ok( (grep { $_->{name} eq 'pcg_risk'     } @tools), 'pcg_risk listed' );
ok( (grep { $_->{name} eq 'pcg_cochange' } @tools), 'pcg_cochange listed' );
ok( (grep { $_->{name} eq 'pcg_diff'     } @tools), 'pcg_diff listed' );
ok( (grep { $_->{name} eq 'pcg_review'   } @tools), 'pcg_review listed' );
ok( (grep { $_->{name} eq 'pcg_explore'  } @tools), 'pcg_explore listed' );
ok( (grep { $_->{name} eq 'pcg_unused'   } @tools), 'pcg_unused listed' );
ok( (grep { $_->{name} eq 'pcg_path'     } @tools), 'pcg_path listed' );
ok( (grep { $_->{name} eq 'pcg_affected' } @tools), 'pcg_affected listed' );
ok( (grep { $_->{name} eq 'pcg_deps'     } @tools), 'pcg_deps listed' );
ok( (grep { $_->{name} eq 'pcg_api'      } @tools), 'pcg_api listed' );
is $tools[0]{inputSchema}{type}, 'object', 'inputSchema is an object';

# --- tools/call against a real index ---
my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
$s->insert_node({ id => 'r', kind => 'function', name => 'run',  qualified_name => 'P::run',  file_path => 'f', start_line => 2 });
$s->insert_node({ id => 'h', kind => 'function', name => 'help', qualified_name => 'P::help', file_path => 'f', start_line => 5 });
$s->insert_edge({ source => 'r', target => 'h', kind => 'calls', provenance => 'static' });
# a package node + containment / import edges, for the module-level tools
$s->insert_node({ id => 'p', kind => 'package', name => 'P', qualified_name => 'P', file_path => 'f', start_line => 1 });
$s->insert_edge({ source => 'p', target => 'r', kind => 'contains', provenance => 'static' });
$s->insert_edge({ source => 'p', target => 'h', kind => 'contains', provenance => 'static' });
$s->insert_edge({ source => 'p', target => undef, kind => 'imports', provenance => 'static', metadata => { via => 'use', module => 'Dep' } });
my $mcp = App::PerlGraph::MCP->new(query => App::PerlGraph::Query->new(store => $s));

my $call = $mcp->dispatch({ jsonrpc => '2.0', id => 3, method => 'tools/call',
    params => { name => 'pcg_callers', arguments => { symbol => 'P::help' } } });
like $call->{result}{content}[0]{text}, qr/P::run/, 'pcg_callers returns the caller';
ok !$call->{result}{isError}, 'no error flag on success';

my $search = $mcp->dispatch({ jsonrpc => '2.0', id => 4, method => 'tools/call',
    params => { name => 'pcg_search', arguments => { query => 'run' } } });
like $search->{result}{content}[0]{text}, qr/P::run/, 'pcg_search round-trips';

# pcg_unused: run() is referenced by nobody (it calls help); help() has a caller
my $unused = $mcp->dispatch({ jsonrpc => '2.0', id => 8, method => 'tools/call',
    params => { name => 'pcg_unused', arguments => {} } });
like $unused->{result}{content}[0]{text}, qr/P::run/,  'pcg_unused lists an unreferenced sub';
unlike $unused->{result}{content}[0]{text}, qr/P::help/,'pcg_unused omits a sub that has a caller';
ok !$unused->{result}{isError}, 'pcg_unused: no error flag';

# pcg_path: run -> help (one calls edge)
my $path = $mcp->dispatch({ jsonrpc => '2.0', id => 9, method => 'tools/call',
    params => { name => 'pcg_path', arguments => { from => 'P::run', to => 'P::help' } } });
like $path->{result}{content}[0]{text}, qr/Path: P::run -> P::help/, 'pcg_path renders the chain';
like $path->{result}{content}[0]{text}, qr/1 hop\b/,                  'pcg_path reports hop count';

# pcg_hotspots: help() is most depended-upon (1 caller); run() makes the most calls
my $hot = $mcp->dispatch({ jsonrpc => '2.0', id => 10, method => 'tools/call',
    params => { name => 'pcg_hotspots', arguments => { limit => 5 } } });
like $hot->{result}{content}[0]{text}, qr/Most depended-upon.*`P::help`/s, 'pcg_hotspots ranks the called fn by fan-in';
like $hot->{result}{content}[0]{text}, qr/fan-out.*`P::run`/s,             'pcg_hotspots ranks the calling fn by fan-out';
ok !$hot->{result}{isError}, 'pcg_hotspots: no error flag';
ok !$path->{result}{isError}, 'pcg_path: no error flag';

# the remaining tool handlers also dispatch correctly through tools/call
sub _call ($name, $args) {
    $mcp->dispatch({ jsonrpc => '2.0', id => 100, method => 'tools/call',
        params => { name => $name, arguments => $args } })->{result}{content}[0]{text};
}
like _call('pcg_node',    { symbol => 'P::run'  }), qr/P::run/,  'pcg_node dispatches';
like _call('pcg_explain', { symbol => 'P::help' }), qr/Explain: P::help.*blast radius/s, 'pcg_explain returns a one-call dossier (blast radius incl.)';
like _call('pcg_explain', { symbol => 'No::Such' }), qr/_not found_/, 'pcg_explain on an unknown symbol -> not found (no crash)';
like _call('pcg_explore', { query  => 'run'     }), qr/P::run/,  'pcg_explore dispatches';
like _call('pcg_callees', { symbol => 'P::run'  }), qr/P::help/, 'pcg_callees dispatches';
like _call('pcg_impact',  { symbol => 'P::help' }), qr/P::run/,  'pcg_impact dispatches';
like _call('pcg_api',     { module => 'P' }),       qr/P::run/,                       'pcg_api dispatches (public surface)';
like _call('pcg_deps',    { module => 'P' }),       qr/imports.*Dep/,                 'pcg_deps dispatches (module dependencies)';
like _call('pcg_cycles',  {}),                      qr/Circular module dependencies/, 'pcg_cycles dispatches';
like _call('pcg_covers',  { symbol => 'P::help' }), qr/Tests covering P::help/,       'pcg_covers dispatches';
like _call('pcg_overview', {}),                     qr/Codebase map/,                 'pcg_overview dispatches';
like _call('pcg_sinks',    {}),                     qr/Security sinks/,               'pcg_sinks dispatches';
like _call('pcg_rename', { old => 'No::Such', new => 'x' }), qr/no function/i,        'pcg_rename dispatches (handler wiring + error path)';
like _call('pcg_search', { query => 'run', semantic => 1 }), qr/Semantic search/,      'pcg_search semantic:true routes to the semantic handler (not keyword)';
like _call('pcg_unresolved', {}),                   qr/Unresolved method calls/,       'pcg_unresolved dispatches';
like _call('pcg_resolve', { resolutions => [] }),   qr/applied 0/,                     'pcg_resolve dispatches (empty input)';
like _call('pcg_resolve', { resolutions => [{ caller => 'P::run', method => 'm', receiver => '$x', target => 'No::Such' }] }),
     qr/rejected/, 'pcg_resolve rejects a hallucinated target';
like _call('pcg_resolve', { resolutions => [{ caller => 'P::run', method => 'help' }] }),
     qr/missing/, 'pcg_resolve rejects a resolution missing required fields (MCP wiring)';

# an opaque method call with a real candidate (P::help) -> exercise the surface filters
$s->insert_unresolved({ from_node_id => 'r', reference_name => 'help', reference_kind => 'method_call',
    file_path => 'f', line => 3, candidates => { receiver => '$x' } });
like   _call('pcg_unresolved', {}),                  qr/\$x->help/, 'pcg_unresolved surfaces an opaque call with its candidate';
like   _call('pcg_unresolved', { name => 'help' }),  qr/\$x->help/, 'pcg_unresolved name filter threads through (MCP)';
unlike _call('pcg_unresolved', { name => 'nomatch' }), qr/\$x->/,   'pcg_unresolved name filter excludes non-matching';
like   _call('pcg_unresolved', { limit => 0 }),      qr/_none_/,    'pcg_unresolved limit:0 is honored (MCP)';
# by_receiver groups by receiver and suggests the candidate-class intersection (P::help -> P)
like   _call('pcg_unresolved', { by_receiver => 1 }), qr/Resolve hints.*\$x.*type as `P`/s,
       'pcg_unresolved by_receiver suggests the unique class for the receiver';

# status splits the unresolved count into your-code vs tests (a .t-path ref)
$s->insert_unresolved({ from_node_id => 'r', reference_name => 'help', reference_kind => 'method_call',
    file_path => 't/x.t', line => 1, candidates => { receiver => '$y' } });
like   _call('pcg_status', {}), qr/in tests/, 'pcg_status splits unresolved into your-code vs tests';

# pcg_affected: changing file 'f' affects 'f' (run calls help, both live in f)
my $aff = $mcp->dispatch({ jsonrpc => '2.0', id => 14, method => 'tools/call',
    params => { name => 'pcg_affected', arguments => { files => ['f'] } } });
like $aff->{result}{content}[0]{text}, qr/Affected by f/, 'pcg_affected dispatches';
ok !$aff->{result}{isError}, 'pcg_affected: no error flag';
# tests_only with no .t files in the closure -> _none_ (exercises the wire flag + empty render)
like _call('pcg_affected', { files => ['f'], tests_only => \1 }), qr/_none_/, 'pcg_affected tests_only renders _none_ when no tests';
# a non-array `files` argument is coerced to empty rather than crashing
like _call('pcg_affected', { files => 'oops' }), qr/_none_/, 'pcg_affected tolerates a non-array files arg';

# --- a well-formed but non-object JSON request is ignored, not fatal ---
is $mcp->dispatch(123),      undef, 'a bare-number request is ignored (no crash)';
is $mcp->dispatch([1, 2]),   undef, 'a bare-array request is ignored (no crash)';

# --- unknown JSON-RPC method -> -32601 (distinct from unknown-tool -32602) ---
my $unkm = $mcp->dispatch({ jsonrpc => '2.0', id => 15, method => 'bogus/method' });
is $unkm->{error}{code}, -32601, 'unknown JSON-RPC method returns -32601';

# --- watch fail-soft: a crashing indexer->sync must not propagate out of dispatch ---
{ package DieIdx; sub new { bless {}, shift } sub sync { die "boom\n" } }
my $mcpW = App::PerlGraph::MCP->new(
    query => App::PerlGraph::Query->new(store => $s), watch => 1, indexer => DieIdx->new);
my $r = eval { $mcpW->dispatch({ jsonrpc => '2.0', id => 16, method => 'tools/call',
    params => { name => 'pcg_search', arguments => { query => 'run' } } }) };
ok !$@,                                            '_maybe_sync swallows a crashing sync (server stays up)';
like $r->{result}{content}[0]{text}, qr/P::run/,   'tool still returns after a failed sync';

# --- unknown tool -> JSON-RPC error ---
my $bad = $mcp->dispatch({ jsonrpc => '2.0', id => 5, method => 'tools/call',
    params => { name => 'nope', arguments => {} } });
ok $bad->{error}, 'unknown tool -> JSON-RPC error';

# --- no index -> graceful text, not a crash ---
my $ni = $mcp0->dispatch({ jsonrpc => '2.0', id => 6, method => 'tools/call',
    params => { name => 'pcg_search', arguments => { query => 'x' } } });
like $ni->{result}{content}[0]{text}, qr/no index/i, 'no-index returns guidance text';

# --- a tool that throws -> isError result (not a JSON-RPC error) ---
{
    package FakeQ;
    sub new { bless {}, shift }
    sub callers { die "boom\n" }
}
my $mcpF = App::PerlGraph::MCP->new(query => FakeQ->new);
my $thrown = $mcpF->dispatch({ jsonrpc => '2.0', id => 7, method => 'tools/call',
    params => { name => 'pcg_callers', arguments => { symbol => 'X' } } });
ok $thrown->{result}{isError},                       'tool exception -> isError result';
like $thrown->{result}{content}[0]{text}, qr/boom/,  'isError carries the message';

# --- a known method sent without an id is a notification (no reply) ---
is $mcp0->dispatch({ jsonrpc => '2.0', method => 'tools/list' }), undef, 'no-id request is a notification';

# --- pcg_diff is NOT gated behind the index (it parses git directly, like the CLI) ---
# Pointed at a non-git dir with no index, it reports the git requirement -- proving it
# passed the index gate -- rather than the "no index" message the graph tools return.
my $ng = Path::Tiny->tempdir;
my $diff_txt = App::PerlGraph::MCP->new(base => "$ng")->dispatch({ jsonrpc => '2.0', id => 20,
    method => 'tools/call', params => { name => 'pcg_diff', arguments => { ref => 'HEAD' } } })->{result}{content}[0]{text};
unlike $diff_txt, qr/no index/i,     'pcg_diff is not blocked by the missing-index gate';
like   $diff_txt, qr/git work tree/, 'pcg_diff without git reports the git requirement (it passed the gate)';

done_testing;
