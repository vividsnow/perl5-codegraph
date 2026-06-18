use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Query;
use App::PerlGraph::MCP;
use App::PerlGraph::CLI;

# --interval validation is pure CLI (no parser) -> run it before the grammar guard
# so it stays covered even where tree-sitter isn't built.
{ open my $fh, '>', \my $err; local *STDERR = $fh;
  is App::PerlGraph::CLI->run('watch', '--interval'),      2, 'watch --interval with no value is a usage error';
  is App::PerlGraph::CLI->run('watch', '--interval', '0'), 2, 'watch --interval 0 is rejected (would sleep(0) busy-loop)';
  is App::PerlGraph::CLI->run('watch', '--interval', 'x'), 2, 'watch --interval non-numeric is rejected'; }

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built";

my $dir = tempdir;
$dir->child('lib')->mkpath;
$dir->child('lib/W.pm')->spew_utf8("package W;\nsub one { 1 }\n1;\n");

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
my $idx = App::PerlGraph::Indexer->new(store => $store, root => "$dir");
$idx->index_all;
my $mcp = App::PerlGraph::MCP->new(
    query => App::PerlGraph::Query->new(store => $store),
    base => "$dir", watch => 1, indexer => $idx);

ok !$store->nodes_by_qname('W::two'), 'W::two not indexed yet';

# add a sub, then a tool call -> lazy re-sync picks it up
$dir->child('lib/W.pm')->spew_utf8("package W;\nsub one { 1 }\nsub two { 2 }\n1;\n");
my $res = $mcp->dispatch({ jsonrpc => '2.0', id => 1, method => 'tools/call',
    params => { name => 'pcg_search', arguments => { query => 'two' } } });
like $res->{result}{content}[0]{text}, qr/W::two/, 'watch: tool call lazily re-synced and found new W::two';

# debounce: an immediate second change is NOT synced within the 2s window
$dir->child('lib/W.pm')->spew_utf8("package W;\nsub one { 1 }\nsub two { 2 }\nsub three { 3 }\n1;\n");
$mcp->dispatch({ jsonrpc => '2.0', id => 2, method => 'tools/call',
    params => { name => 'pcg_search', arguments => { query => 'three' } } });
ok !$store->nodes_by_qname('W::three'), 'debounce: rapid second change not synced within the window';

# without watch, no auto-sync happens
my $mcp2 = App::PerlGraph::MCP->new(query => App::PerlGraph::Query->new(store => $store));
ok !$mcp2->watch, 'watch defaults off';

# deleting a file purges its nodes (and its files row) on the next sync
$dir->child('lib/Gone.pm')->spew_utf8("package Gone;\nsub bye { 1 }\n1;\n");
$idx->sync;
ok $store->nodes_by_qname('Gone::bye'), 'new file Gone.pm indexed on sync';
$dir->child('lib/Gone.pm')->remove;
$idx->sync;
ok !$store->nodes_by_qname('Gone::bye'), 'deleted file purged from the graph on sync';
ok !(grep { /Gone\.pm$/ } $store->file_paths), 'deleted file removed from the files table';


# CLI `watch --once` runs a single sync and exits 0
my $rc;
{ open my $fh, '>', \my $out; local *STDOUT = $fh; $rc = App::PerlGraph::CLI->run('watch', '--once', "$dir") }
is $rc, 0, 'pcg watch --once runs one sync and exits 0';
done_testing;
