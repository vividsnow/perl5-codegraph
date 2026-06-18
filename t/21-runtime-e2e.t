use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

# Full index WITH runtime enrichment.
my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
App::PerlGraph::Indexer->new(store => $store, root => 't/corpus/oo', runtime => 1)->index_all;

my ($animal) = $store->nodes_by_qname('Animal');
my ($dog)    = $store->nodes_by_qname('Dog');
my ($speak)  = $store->nodes_by_qname('Animal::speak');
my ($sound)  = $store->nodes_by_qname('Animal::sound');

# real @ISA confirmed -> extends edge upgraded to symtab provenance
my %ext = map { $_->{target} => $_->{provenance} } $store->outgoing_edges($dog->{id}, 'extends');
is $ext{ $animal->{id} }, 'symtab', 'Dog -> Animal extends upgraded to symtab provenance';

# dynamic dispatch resolved by the optree enricher
my %callees = map { $_->{target} => $_->{provenance} } $store->outgoing_edges($speak->{id}, 'calls');
is $callees{ $sound->{id} }, 'optree', 'optree resolved $self->sound: Animal::speak -> Animal::sound';

# static resolves $self->sound *heuristically* (enclosing package + @ISA); runtime
# adds value by UPGRADING that edge to authoritative optree provenance (line 25).
my $static = App::PerlGraph::Store->new(path => ':memory:'); $static->init;
App::PerlGraph::Indexer->new(store => $static, root => 't/corpus/oo')->index_all;
my ($sspeak) = $static->nodes_by_qname('Animal::speak');
my %sc = map { $_->{target} => $_->{provenance} } $static->outgoing_edges($sspeak->{id}, 'calls');
is $sc{ $sound->{id} }, 'heuristic', 'static index resolves $self->sound as heuristic (runtime upgrades it to optree)';

# MOP (Moose) attribute -> field node, if Moose is installed
SKIP: {
    skip "Moose not installed", 1 unless eval { require Moose; 1 };
    my ($size) = $store->nodes_by_qname('Widget::size');
    ok $size && $size->{kind} eq 'field', 'MOP: Moose has-attribute -> field node (Widget::size)';
}
done_testing;
