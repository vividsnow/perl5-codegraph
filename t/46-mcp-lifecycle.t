use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir path);
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::MCP;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

# a project the MCP server can index/query in-process
my $dir = tempdir;
path($dir, 'A.pm')->spew("package A;\nsub go { B::help() }\n1;\n");
path($dir, 'B.pm')->spew("package B;\nsub help { 1 }\n1;\n");

# server over an EMPTY store (no graph yet) -- mirrors `pcg serve --mcp` before
# anyone has run `pcg index`.
path($dir, '.pcg')->mkpath;
my $store = App::PerlGraph::Store->new(path => path($dir, '.pcg/graph.db') . "");
$store->init;
my $idx = App::PerlGraph::Indexer->new(store => $store, root => "$dir");
my $mcp = App::PerlGraph::MCP->new(indexer => $idx, base => "$dir");

sub tcall ($name, $args = {}) {
    my $r = $mcp->dispatch({ jsonrpc => '2.0', id => 1, method => 'tools/call',
        params => { name => $name, arguments => $args } });
    return $r->{result}{content}[0]{text};
}

# the lifecycle tools are advertised
my $list = $mcp->dispatch({ jsonrpc => '2.0', id => 1, method => 'tools/list' });
my %tool = map { $_->{name} => 1 } @{ $list->{result}{tools} };
is scalar(keys %tool), 52, 'tools/list advertises 52 tools (43 read + 6 write + index/sync/status)';
ok $tool{pcg_index} && $tool{pcg_sync} && $tool{pcg_status}, 'the three lifecycle tools are present';

# a read tool BEFORE indexing -> clear guidance, not a confusing empty result
like tcall('pcg_callers', { symbol => 'B::help' }), qr/pcg_index/, 'read tool before index points at pcg_index';

# pcg_index builds the graph in-session (the bootstrap -- no restart needed)
like tcall('pcg_index'), qr/indexed \d+ file/i, 'pcg_index reports what it built';

# and now the SAME server answers read queries (shared store, no rebuild)
like tcall('pcg_callers', { symbol => 'B::help' }), qr/A::go/, 'read tool works immediately after pcg_index';
like tcall('pcg_status'), qr/nodes=\d+/, 'pcg_status reports node/edge counts';

# pcg_sync picks up an edit
path($dir, 'A.pm')->spew("package A;\nsub go { B::help(); B::extra() }\nsub other { 1 }\n1;\n");
path($dir, 'B.pm')->spew("package B;\nsub help { 1 }\nsub extra { 1 }\n1;\n");
like tcall('pcg_sync'), qr/sync/i, 'pcg_sync reports the incremental update';
like tcall('pcg_callers', { symbol => 'B::extra' }), qr/A::go/, 'a newly-added call is queryable after pcg_sync';

done_testing;
