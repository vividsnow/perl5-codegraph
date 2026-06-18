use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Query;
use App::PerlGraph::Format;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built";

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
App::PerlGraph::Indexer->new(store => $store, root => 't/corpus/dist')->index_all;
my $q = App::PerlGraph::Query->new(store => $store);

# node view: source + relationships
my @views = $q->node_view('Foo::run');
is scalar(@views), 1, 'one view for Foo::run';
my $md = App::PerlGraph::Format::node_view('Foo::run', [@views], 't/corpus/dist');
like $md, qr/sub run/,                      'node view includes verbatim source';
like $md, qr/callees:.*Foo::Bar::help/s,    'node view lists callees';

# explore: search hits with code
my @ev = $q->explore('run');
ok scalar(@ev), 'explore returns hits';
my $emd = App::PerlGraph::Format::explore('run', [@ev], 't/corpus/dist');
like $emd, qr/Explore: run/, 'explore header';
like $emd, qr/```perl/,      'explore embeds code blocks';
like $emd, qr/Foo::run/,     'explore mentions the matched symbol';

is scalar(grep { $_->{node}{kind} eq 'file' } $q->explore('Foo')), 0,
    'explore omits whole-file nodes (no entire-file dumps)';
done_testing;
