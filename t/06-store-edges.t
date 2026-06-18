use v5.36;
use Test2::V0;
use App::PerlGraph::Store;

my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
$s->insert_node({ id => 'a', kind => 'function', name => 'a', qualified_name => 'P::a', file_path => 'f' });
$s->insert_node({ id => 'b', kind => 'function', name => 'b', qualified_name => 'P::b', file_path => 'f' });

my $eid = $s->insert_edge({ source => 'a', target => 'b', kind => 'calls', provenance => 'static' });
ok $eid, 'edge inserted';
is [$s->outgoing_edges('a')]->[0]{target}, 'b', 'outgoing edge';
is [$s->incoming_edges('b')]->[0]{source}, 'a', 'incoming edge';

my $uid = $s->insert_unresolved({ from_node_id => 'a', reference_name => 'b',
    reference_kind => 'call', file_path => 'f' });
is scalar($s->all_unresolved), 1, 'one unresolved ref';
$s->resolve_ref($uid, 'b');
is scalar($s->all_unresolved), 0, 'ref consumed after resolve';
is scalar($s->outgoing_edges('a')), 1, 'resolve upserts onto the existing a->b edge (no duplicate)';

$s->upsert_file({ path => 'f', hash => 'h1', language => 'perl' });
is $s->file_hash('f'), 'h1', 'file hash stored';
done_testing;
