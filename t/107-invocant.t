use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::Store;
use App::PerlGraph::Resolver;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

sub resolve ($src) {
    my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
    my $out = App::PerlGraph::Extractor->new(file_path => 'X.pm')->extract($parser->parse_string($src));
    $store->insert_node($_)       for @{ $out->{nodes} };
    $store->insert_edge($_)       for @{ $out->{edges} };
    $store->insert_unresolved($_) for @{ $out->{refs} };
    App::PerlGraph::Resolver->new(store => $store)->resolve_all;
    return $store;
}
sub callees ($store, $caller) {
    my ($n) = $store->nodes_by_qname($caller); return () unless $n;
    map { [ $store->node($_->{target})->{qualified_name}, $_->{provenance} ] }
        grep { $_->{target} } $store->outgoing_edges($n->{id}, 'calls');
}

# A Mojolicious-style controller: the first signature parameter `$c` IS the invocant, exactly
# like `$self` -- so `$c->method` must resolve against the class (the pervasive Mojo pattern that
# was otherwise fully opaque).
my $s = resolve(<<'PL');
package My::Controller;
use Mojo::Base 'Mojolicious::Controller', -signatures;
sub index ($c) { return $c->compute(5) + $c->build('x') }
sub compute ($c, $n) { $n * 2 }
sub build ($c, $s) { "[$s]" }
PL
my %c = map { $_->[0] => $_->[1] } callees($s, 'My::Controller::index');
ok $c{'My::Controller::compute'}, '$c->compute resolves against the class (named first-param invocant)';
ok $c{'My::Controller::build'},   '$c->build resolves too';
is $c{'My::Controller::compute'}, 'heuristic', 'the named-invocant edge is heuristic (like $self)';

# A named invocant that is NOT the first parameter is NOT an invocant.
my $s3 = resolve(<<'PL');
package K;
use Moo;
sub m1 ($self, $c) { $c->other }
sub other ($self) { 1 }
PL
my %k = map { $_->[0] => 1 } callees($s3, 'K::m1');
ok !$k{'K::other'}, 'a $c that is the SECOND param (a passed object) is not typed as the class';

# A plain (non-OO) package: the first param must NOT be typed as the package (no false invocant).
my $s2 = resolve(<<'PL');
package Util;
sub run ($thing) { return $thing->process }
sub process ($x) { $x }
PL
my %u = map { $_->[0] => 1 } callees($s2, 'Util::run');
ok !$u{'Util::process'}, 'in a non-class package, the first param is NOT typed as the package';

# A plain HELPER function inside a REAL OO class: its first param `$thing` is an arbitrary object, NOT
# an invocant -- even though the class defines a same-named `render`. Only conventional invocant names
# ($self/$class/$this/$c) are typed, so `$thing->render` must stay opaque (no phantom edge to the class).
my $s4 = resolve(<<'PL');
package Widget;
use Moo;
sub _fmt ($thing, $opt) { return $thing->render }
sub render ($self) { 'x' }
PL
my %w = map { $_->[0] => 1 } callees($s4, 'Widget::_fmt');
ok !$w{'Widget::render'}, 'a helper with an arbitrarily-named first param ($thing) is NOT typed as the class';

done_testing;
