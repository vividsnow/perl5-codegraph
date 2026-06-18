use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

my $dir = tempdir;
$dir->child('lib')->mkpath;
$dir->child('lib/A.pm')->spew_utf8("package A;\nuse B;\nsub run { B::help(); shout() }\nsub shout { 1 }\n1;\n");
$dir->child('lib/B.pm')->spew_utf8("package B;\nsub help { 'b' }\n1;\n");

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
my $idx = App::PerlGraph::Indexer->new(store => $store, root => "$dir");
$idx->index_all;

my ($run)  = $store->nodes_by_qname('A::run');
my ($help) = $store->nodes_by_qname('B::help');
my %before = map { $_->{target} => 1 } $store->outgoing_edges($run->{id}, 'calls');
ok $before{ $help->{id} }, 'cross-file edge A::run -> B::help resolved after index';

# Rewrite B.pm with two blank lines above sub help (shifts its line). help still exists.
$dir->child('lib/B.pm')->spew_utf8("package B;\n\n\nsub help { 'b' }\n1;\n");
my $stats = $idx->sync;
is $stats->{reindexed}, 1, 'only B was reindexed (A unchanged)';

my ($help2) = $store->nodes_by_qname('B::help');
is $help2->{id}, $help->{id},                    'B::help id is stable across the edit (line not in id)';
ok $help2->{start_line} > $help->{start_line},   'B::help line actually shifted';

my %after = map { $_->{target} => 1 } $store->outgoing_edges($run->{id}, 'calls');
ok $after{ $help2->{id} }, 'inbound cross-file edge SURVIVES sync (regression guard for review #1)';

my @hits = $store->search('help');
is scalar(@hits), 1, 'no duplicate FTS rows after re-index (regression guard for review #2)';
done_testing;
