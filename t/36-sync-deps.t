use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Query;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built";

my $dir = tempdir; $dir->child('lib')->mkpath;
$dir->child('lib/A.pm')->spew_utf8("package A;\nsub bar { 1 }\n1;\n");
$dir->child('lib/B.pm')->spew_utf8("package B;\nsub run { A::bar() }\n1;\n");

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
my $idx = App::PerlGraph::Indexer->new(store => $store, root => "$dir");
$idx->index_all;
my $q = App::PerlGraph::Query->new(store => $store);

my ($brun) = $store->nodes_by_qname('B::run');
sub call_edges  { scalar $store->outgoing_edges($brun->{id}, 'calls') }   # raw: counts dangling too
sub b_calls_bar { grep { ($_->{qualified_name} // '') eq 'A::bar' } $q->callees('B::run') }
sub unresolved_bar { grep { ($_->{reference_name} // '') eq 'A::bar' } $store->all_unresolved }

is call_edges(), 1,  'baseline: 1 resolved call edge from B::run';
ok b_calls_bar(),    'baseline: B::run -> A::bar across files';

# --- rename A::bar -> A::baz; B's source still calls A::bar() ---
$dir->child('lib/A.pm')->spew_utf8("package A;\nsub baz { 1 }\n1;\n");
my $stats = $idx->sync;

is call_edges(), 0,                   'after rename: the now-dangling B::run -> A::bar edge is removed, not orphaned';
ok !$store->nodes_by_qname('A::bar'), 'old A::bar node gone';
is $stats->{reindexed}, 1,            'reindexed counts only the changed file (A), not the forced dependent';
ok $stats->{dependents} >= 1,         'sync reports it refreshed >=1 dependent';
ok unresolved_bar(),                  'B::run -> A::bar is now honestly recorded as unresolved, not silently dropped';

# --- re-add A::bar; resolve_all reconnects B ---
$dir->child('lib/A.pm')->spew_utf8("package A;\nsub baz { 1 }\nsub bar { 1 }\n1;\n");
$idx->sync;
is call_edges(), 1, 'after re-adding A::bar: B::run -> A::bar resolves again';
ok b_calls_bar(),   'callees shows A::bar again';

# --- delete A entirely; B references a missing symbol -> no dangling edge ---
$dir->child('lib/A.pm')->remove;
$idx->sync;
is call_edges(), 0,                   'after deleting A: no dangling edge from B::run';
ok !$store->nodes_by_qname('A::bar'), 'A::bar purged with the deleted file';
ok unresolved_bar(),                  'B::run -> A::bar tracked as unresolved after the delete';

done_testing;
