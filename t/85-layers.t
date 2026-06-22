use v5.36;
use Test2::V0;
use App::PerlGraph::Store;
use App::PerlGraph::Query;
use App::PerlGraph::Format;

my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
# A -> B -> C (a clean 3-layer chain); X <-> Y (a 2-module cycle)
$s->insert_node({ id => $_, kind => 'package', name => $_, qualified_name => $_, file_path => 'f', start_line => 1 })
    for qw(A B C X Y);
my %imp = (A => 'B', B => 'C', X => 'Y', Y => 'X');
$s->insert_edge({ source => $_, target => $imp{$_}, kind => 'imports', provenance => 'static',
    metadata => { via => 'use', module => $imp{$_} } }) for sort keys %imp;

my $q = App::PerlGraph::Query->new(store => $s);
my $r = $q->layers;

my %layer;
for my $lvl (keys %{ $r->{layers} }) { $layer{$_} = $lvl for @{ $r->{layers}{$lvl} } }
is $layer{C}, 0, 'C (imports nothing internal) is foundational (layer 0)';
is $layer{B}, 1, 'B (imports C) is layer 1';
is $layer{A}, 2, 'A (imports B) is layer 2';
ok +(grep { /X -> Y|Y -> X/ } @{ $r->{violations} }), 'the X<->Y cycle is reported as a layering violation';

my $txt = App::PerlGraph::Format::layers($r);
like $txt, qr/Architecture layers/,        'format: header';
like $txt, qr/Layer 0.*`C`/s,              'format: C in the foundational layer';
like $txt, qr/Layer 2.*`A`/s,              'format: A at the top';
like $txt, qr/Layering violations/,        'format: violations section';

done_testing;
