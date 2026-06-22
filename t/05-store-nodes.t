use v5.36;
use Test2::V0;
use App::PerlGraph::Store;

my $store = App::PerlGraph::Store->new(path => ':memory:');
$store->init;

$store->insert_node({ id => 'n1', kind => 'function', name => 'make',
    qualified_name => 'Acme::Widget::make', file_path => 'lib/Acme/Widget.pm',
    language => 'perl', start_line => 6, end_line => 6, is_exported => 1 });

my @by_name = $store->nodes_by_name('make');
is scalar(@by_name), 1, 'one node by name';
is $by_name[0]{qualified_name}, 'Acme::Widget::make', 'qname round-trips';

my @by_q = $store->nodes_by_qname('Acme::Widget::make');
is scalar(@by_q), 1, 'one node by qname';

my @hits = $store->search('make');
is $hits[0]{id}, 'n1', 'FTS search finds the node';

# symbols_like escapes LIKE metacharacters, so '_' matches literally (not as a wildcard)
$store->insert_node({ id => 'u1', kind => 'function', name => 'foo_bar', qualified_name => 'P::foo_bar', file_path => 'f', start_line => 1 });
$store->insert_node({ id => 'u2', kind => 'function', name => 'fooXbar', qualified_name => 'P::fooXbar', file_path => 'f', start_line => 2 });
my @like = $store->symbols_like('foo_bar');
is scalar(@like), 1,          'symbols_like escapes "_" so it matches literally, not as a LIKE wildcard';
is $like[0]{name}, 'foo_bar', '... and returns the right node';

done_testing;
