use v5.36;
use Test2::V0;
use App::PerlGraph::Store;
use App::PerlGraph::Resolver;

# Class->method resolution along one level of @ISA (the path Layer 2 builds on).
my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
$s->insert_node({ id => 'Base',   kind => 'class',    name => 'Base',    qualified_name => 'Base',        file_path => 'b' });
$s->insert_node({ id => 'Bg',     kind => 'method',   name => 'greet',   qualified_name => 'Base::greet', file_path => 'b' });
$s->insert_node({ id => 'Der',    kind => 'class',    name => 'Derived', qualified_name => 'Derived',     file_path => 'd' });
$s->insert_node({ id => 'caller', kind => 'function', name => 'run',     qualified_name => 'Main::run',   file_path => 'd' });

# Derived extends Base; Derived does NOT define greet.
$s->upsert_edge({ source => 'Der', target => 'Base', kind => 'extends',
    provenance => 'static', metadata => { via => 'parent', name => 'Base' } });

# Main::run calls Derived->greet  (method call, literal class receiver).
$s->insert_unresolved({ from_node_id => 'caller', reference_name => 'greet',
    reference_kind => 'method_call', file_path => 'd', candidates => { receiver => 'Derived' } });

App::PerlGraph::Resolver->new(store => $s)->resolve_all;

my %tgt = map { $_->{target} => 1 } $s->outgoing_edges('caller', 'calls');
ok $tgt{'Bg'}, 'Derived->greet resolves to inherited Base::greet via one-level @ISA';
is scalar($s->all_unresolved), 0, 'method ref consumed';
done_testing;
