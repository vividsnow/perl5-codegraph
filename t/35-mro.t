use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Query;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built";

my $dir = tempdir; $dir->child('lib')->mkpath;

# 3-level chain: Leaf -> Middle -> Base
$dir->child('lib/Chain.pm')->spew_utf8(<<'PERL');
package Base;
sub base_method { 'base' }
1;
package Middle;
our @ISA = ('Base');
sub mid_method { 'mid' }
1;
package Leaf;
our @ISA = ('Middle');
sub leaf_run  { my $self = shift; $self->base_method }   # grandparent (2 levels up)
sub leaf_mid  { my $self = shift; $self->mid_method }    # direct parent (regression)
sub leaf_self { my $self = shift; $self->leaf_mid }      # same package (regression)
1;
PERL

# diamond: D -> (B, C) -> A
$dir->child('lib/Diamond.pm')->spew_utf8(<<'PERL');
package DiA;
sub am { 'a' }
1;
package DiB;
our @ISA = ('DiA');
1;
package DiC;
our @ISA = ('DiA');
sub am { 'c' }              # second-branch override: under DEFAULT (DFS) mro this is
1;                          # shadowed by DiA::am, found first via the DiB branch (not C3)
package DiD;
our @ISA = ('DiB', 'DiC');
sub d_run { my $self = shift; $self->am }   # default DFS: DiD, DiB, DiA(am!) -> DiA::am
1;
PERL

# malformed cyclic @ISA must not hang the indexer
$dir->child('lib/Cycle.pm')->spew_utf8(<<'PERL');
package CycA;
our @ISA = ('CycB');
sub a_run { my $self = shift; $self->only }
1;
package CycB;
our @ISA = ('CycA');
sub only { 'ok' }
1;
PERL

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
# (if _mro looped on the cycle, index_all would hang here)
App::PerlGraph::Indexer->new(store => $store, root => "$dir")->index_all;
my $q = App::PerlGraph::Query->new(store => $store);

sub callees_of { my %h = map { ($_->{qualified_name} // $_->{name}) => $_ } $q->callees($_[0]); \%h }

ok callees_of('Leaf::leaf_run')->{'Base::base_method'},   'method resolves through the full chain to a grandparent';
ok callees_of('Leaf::leaf_mid')->{'Middle::mid_method'},  'direct-parent resolution still works';
ok callees_of('Leaf::leaf_self')->{'Leaf::leaf_mid'},     'same-package resolution still works';
is callees_of('Leaf::leaf_run')->{'Base::base_method'}{_provenance}, 'heuristic', 'inherited self-method edge is heuristic';

ok  callees_of('DiD::d_run')->{'DiA::am'},                'diamond: default DFS mro resolves to the shared ancestor via the first branch';
ok !callees_of('DiD::d_run')->{'DiC::am'},                'diamond: second-branch override is shadowed under default DFS (not C3)';
ok callees_of('CycA::a_run')->{'CycB::only'},             'cyclic @ISA resolves without looping';

# still no guess edge for a method defined nowhere in the chain
ok !callees_of('Leaf::leaf_run')->{'Leaf::nope'},         'no guess edge for a method absent from the whole MRO';

done_testing;
