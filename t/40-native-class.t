use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::Store;
use App::PerlGraph::Resolver;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

sub extract ($src, $file = 'C.pm') {
    App::PerlGraph::Extractor->new(file_path => $file)->extract($parser->parse_string($src));
}
sub by_q ($out) { map { ($_->{qualified_name} => $_) } @{ $out->{nodes} } }

# --- native class: class node + scoped method + field + :isa ----------------
my $out = extract(<<'PL');
use v5.38;
use feature 'class';
no warnings 'experimental::class';
class Point :isa(Shape) {
    field $x :param = 0;
    field $y :param = 0;
    method coords { ($x, $y) }
    method _private { 1 }
}
PL
my %q = by_q($out);

is $q{'Point'}{kind}, 'class',            'class NAME -> class node';
ok !exists $q{'coords'},                  'method is NOT emitted as a bare top-level function';
is $q{'Point::coords'}{kind}, 'method',   'method NAME {} -> method node scoped to the class';
is $q{'Point::_private'}{visibility}, 'private', 'leading-underscore method is private';

# fields (sigil-stripped name, scoped, consistent with runtime MOP field naming)
is $q{'Point::x'}{kind}, 'field',         'field $x -> field node (with a default)';
is $q{'Point::y'}{kind}, 'field',         'field $y -> field node';
ok !exists $q{'Point::$x'},               'field name has no sigil';

# :isa(Shape) -> extends edge (null target, resolved later by name)
my @extends = grep { $_->{kind} eq 'extends' } @{ $out->{edges} };
ok( (grep { (($_->{metadata}||{})->{name}//'') eq 'Shape' } @extends),
    ':isa(Parent) -> extends edge carrying the parent name' );

# the class contains its method
ok( (grep { $_->{kind} eq 'contains' && $_->{source} eq $q{'Point'}{id} && $_->{target} eq $q{'Point::coords'}{id} } @{ $out->{edges} }),
    'class contains its method' );

# --- statement-form `class Foo;` scopes following declarations to Foo --------
my %qs = by_q(extract("use feature 'class';\nclass Foo;\nfield \$a;\nmethod m { 1 }\n", 'F.pm'));
is $qs{'Foo'}{kind},      'class',  'statement-form class -> class node';
is $qs{'Foo::m'}{kind},   'method', 'statement-form class scopes following methods to it';
is $qs{'Foo::a'}{kind},   'field',  'statement-form class scopes following fields to it';

# --- block-form classes do not leak scope into a sibling class --------------
my %qb = by_q(extract("use feature 'class';\nclass A { method ay { 1 } }\nclass B { method by { 1 } }\n", 'AB.pm'));
is $qb{'A::ay'}{kind}, 'method',    'class A block scopes ay to A';
is $qb{'B::by'}{kind}, 'method',    'class B block scopes by to B';
ok !exists $qb{'A::by'},            'block-form class B does not leak its method into A';

# --- Object::Pad uses the same keywords -> same extraction (no extra code) ---
my %qp = by_q(extract("use Object::Pad;\nclass Acc {\n field \$v :param;\n method val { \$v }\n}\n", 'Acc.pm'));
is $qp{'Acc'}{kind},      'class',  'Object::Pad class -> class node';
is $qp{'Acc::val'}{kind}, 'method', 'Object::Pad method -> method node';
is $qp{'Acc::v'}{kind},   'field',  'Object::Pad field -> field node';

# --- :isa -> extends AND :does(Role) -> implements (Object::Pad role composition)
my $ro = extract("use Object::Pad;\nclass Widget :isa(Base) :does(Drawable) {\n method draw { 1 }\n}\n", 'W.pm');
my @we = @{ $ro->{edges} };
ok( (grep { $_->{kind} eq 'extends'    && (($_->{metadata}||{})->{name}//'') eq 'Base' }     @we), ':isa -> extends Base' );
ok( (grep { $_->{kind} eq 'implements' && (($_->{metadata}||{})->{name}//'') eq 'Drawable' } @we), ':does -> implements Drawable' );

# --- end-to-end: $self->method inside a class method resolves to the sibling -
{
    my $o = extract("use feature 'class';\nclass Calc {\n method run { \$self->step() }\n method step { 1 }\n}\n", 'Calc.pm');
    my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
    $s->insert_node($_)       for @{ $o->{nodes} };
    $s->insert_edge($_)       for @{ $o->{edges} };
    $s->insert_unresolved($_) for @{ $o->{refs} };
    App::PerlGraph::Resolver->new(store => $s)->resolve_all;
    my %qq = by_q($o);
    my @callees = map  { $s->node($_->{target})->{qualified_name} }
                  grep { $_->{target} } $s->outgoing_edges($qq{'Calc::run'}{id}, 'calls');
    ok( (grep { $_ eq 'Calc::step' } @callees),
        '$self->step() in a class method resolves to the sibling method (MRO works)' );
}

done_testing;
