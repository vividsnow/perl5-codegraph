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
done_testing;
