use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::Store;
use App::PerlGraph::Resolver;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
my $out = App::PerlGraph::Extractor->new(file_path => 'A.pm')->extract($parser->parse_string(<<'PL'));
package Base;
sub greet { "hi" }
package Child;
use parent -norequire, 'Base';
sub greet { my $self = shift; $self->SUPER::greet() }
sub probe { my $self = shift; $self->can('x'); $self->isa('Base'); $self->DOES('Base'); $self->VERSION(); $self->frobnicate() }
package Orphan;
sub solo { my $self = shift; $self->SUPER::nope() }
PL
$store->insert_node($_)       for @{ $out->{nodes} };
$store->insert_edge($_)       for @{ $out->{edges} };
$store->insert_unresolved($_) for @{ $out->{refs} };
App::PerlGraph::Resolver->new(store => $store)->resolve_all;

sub callees ($caller) {
    my ($n) = $store->nodes_by_qname($caller);
    map { [ $store->node($_->{target})->{qualified_name}, $_->{provenance} ] }
        grep { $_->{target} } $store->outgoing_edges($n->{id}, 'calls');
}
my %unresolved = map { ($_->{reference_name} => 1) } $store->all_unresolved;

# $self->SUPER::greet resolves to the parent's method
my %g = map { $_->[0] => $_->[1] } callees('Child::greet');
ok $g{'Base::greet'}, '$self->SUPER::greet resolves to the parent method';

# UNIVERSAL methods are consumed, not left as phantom "unresolved" project gaps
ok !$unresolved{'can'},     'can() is recognized as UNIVERSAL (consumed, not unresolved)';
ok !$unresolved{'isa'},     'isa() is recognized as UNIVERSAL (consumed)';
ok !$unresolved{'DOES'},    'DOES() is recognized as UNIVERSAL (consumed)';
ok !$unresolved{'VERSION'}, 'VERSION() is recognized as UNIVERSAL (consumed)';
ok !$unresolved{'SUPER::greet'}, 'the resolved SUPER:: call is no longer unresolved';

# SUPER:: with no parent (empty @ISA) is a graceful no-op: stays unresolved, never crashes or fabricates
ok $unresolved{'SUPER::nope'}, 'SUPER:: with no parent stays unresolved (no fabricated edge)';
is [ map { $_->[0] } callees('Orphan::solo') ], [], 'Orphan::solo gained no fabricated call edge';

# a genuine opaque call is still left unresolved (we did not over-consume)
ok $unresolved{'frobnicate'}, 'a real opaque $self->method stays unresolved (no over-consumption)';

done_testing;
