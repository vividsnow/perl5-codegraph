use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Indexer;
use App::PerlGraph::Store;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
my $idx = App::PerlGraph::Indexer->new(store => $store, root => 't/corpus/dist');
my $stats = $idx->index_all;

ok $stats->{files} >= 2, 'indexed both modules';
my ($run) = $store->nodes_by_qname('Foo::run');
ok $run, 'Foo::run indexed';

my ($help)  = $store->nodes_by_qname('Foo::Bar::help');
my ($shout) = $store->nodes_by_qname('Foo::shout');
my %tgt = map { $_->{target} => 1 } $store->outgoing_edges($run->{id}, 'calls');
ok $tgt{ $help->{id} },  'cross-file call resolved Foo::run -> Foo::Bar::help';
ok $tgt{ $shout->{id} }, 'same-file call resolved run -> shout';

my $s2 = $idx->sync;
is $s2->{reindexed}, 0, 'no files reindexed when unchanged';

# extraction_version: a file extracted by an OLDER pcg (stale version) is re-extracted on
# the next sync even when its bytes are unchanged -- so an extraction upgrade takes effect.
$store->dbh->do('update files set extraction_version = 0');   # simulate an older extractor
ok $idx->sync->{reindexed} >= 1, 'a version-stale file is re-extracted on sync (upgrade takes effect)';
is $idx->sync->{reindexed}, 0,   '... and is fresh again afterwards (back to incremental)';

done_testing;
