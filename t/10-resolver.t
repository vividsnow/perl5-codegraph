use v5.36;
use Test2::V0;
use App::PerlGraph::Store;
use App::PerlGraph::Resolver;

my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
$s->insert_node({ id => 'P',  kind => 'package',  name => 'P',      qualified_name => 'P',             file_path => 'f' });
$s->insert_node({ id => 'Pa', kind => 'function', name => 'a',      qualified_name => 'P::a',          file_path => 'f' });
$s->insert_node({ id => 'Ph', kind => 'function', name => 'helper', qualified_name => 'P::helper',     file_path => 'f' });
$s->insert_node({ id => 'Ol', kind => 'function', name => 'log',    qualified_name => 'P::Other::log', file_path => 'g' });
$s->insert_node({ id => 'Pc', kind => 'constant', name => 'MAX',    qualified_name => 'P::MAX',        file_path => 'f' });

$s->insert_unresolved({ from_node_id => 'Pa', reference_name => 'helper',        reference_kind => 'call', file_path => 'f' });
$s->insert_unresolved({ from_node_id => 'Pa', reference_name => 'P::Other::log', reference_kind => 'call', file_path => 'f' });
$s->insert_unresolved({ from_node_id => 'Pa', reference_name => 'print',         reference_kind => 'call', file_path => 'f' });
$s->insert_unresolved({ from_node_id => 'Pa', reference_name => 'MAX',           reference_kind => 'call', file_path => 'f' });

App::PerlGraph::Resolver->new(store => $s)->resolve_all;

is scalar($s->all_unresolved), 0, 'all refs consumed';
my %tgt = map { $_->{target} => 1 } $s->outgoing_edges('Pa', 'calls');
ok $tgt{Ph}, 'same-package helper resolved';
ok $tgt{Ol}, 'qualified call resolved';
ok $tgt{Pc}, 'reference to a constant resolves to the constant node';
ok !exists $tgt{''} && !exists $tgt{undef}, 'builtin produced no edge';
done_testing;
