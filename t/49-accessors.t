use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::Store;
use App::PerlGraph::Resolver;
use App::PerlGraph::Query;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

sub graph ($src, $file) {
    my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
    my $out = App::PerlGraph::Extractor->new(file_path => $file)->extract($parser->parse_string($src));
    $store->insert_node($_)       for @{ $out->{nodes} };
    $store->insert_edge($_)       for @{ $out->{edges} };
    $store->insert_unresolved($_) for @{ $out->{refs} };
    App::PerlGraph::Resolver->new(store => $store)->resolve_all;
    return ($store, $out);
}
sub methods ($out) { map { $_->{qualified_name} } grep { $_->{kind} eq 'method' } @{ $out->{nodes} } }
sub calls ($store, $out, $from) {
    my %id = map { $_->{qualified_name} => $_->{id} } @{ $out->{nodes} };
    return map { $store->node($_->{target})->{qualified_name} }
           grep { $_->{target} } $store->outgoing_edges($id{$from}, 'calls');
}

# --- Moo/Moose `has` --------------------------------------------------------
my $moo = <<'PL';
package Widget;
use Moo;
has 'title'  => (is => 'ro');
has [qw(width height)] => (is => 'rw');
has 'secret' => (is => 'ro', reader => 'get_secret');
has 'bare'   => (is => 'bare');
has 'naked';
has 'count'  => (is => 'ro', writer => 'set_count');
has 'payload' => (is => 'rw', accessor => 'get_payload');
has 'cfg'    => (is => 'ro', default => sub { { accessor => 'FAKE', reader => 'NOPE' } });
sub render { my $self = shift; $self->title . $self->width . $self->get_secret }
PL

my ($s, $o) = graph($moo, 'Widget.pm');
my %m = map { $_ => 1 } methods($o);

ok $m{'Widget::title'},      'has (is=>ro) generates a reader named after the attribute';
ok $m{'Widget::width'},      'has [qw(...)] generates an accessor per attribute (width)';
ok $m{'Widget::height'},     '... and height';
ok $m{'Widget::get_secret'}, 'explicit reader => name is honored';
ok !$m{'Widget::secret'},    'renamed attribute does NOT emit an accessor under its own name (no false positive)';
ok !$m{'Widget::bare'},      'is => bare emits no accessor';
ok !$m{'Widget::naked'},     'has with no `is`/reader/accessor emits no accessor';
ok $m{'Widget::count'},      'has (is=>ro, writer=>X) emits the reader (count)';
ok $m{'Widget::set_count'},  '... and the explicit writer (set_count)';
ok $m{'Widget::get_payload'},'explicit accessor => name is honored';
ok !$m{'Widget::payload'},   '... and the attribute name itself is not emitted when accessor renames it';
ok $m{'Widget::cfg'},        'a default sub/hashref attribute still gets its own accessor';
ok !$m{'Widget::FAKE'} && !$m{'Widget::NOPE'},
   'option-looking keys inside a default sub/hashref are NOT mistaken for accessor options';

my %rc = map { $_ => 1 } calls($s, $o, 'Widget::render');
ok $rc{'Widget::title'},      '$self->title resolves to the generated accessor';
ok $rc{'Widget::get_secret'}, '$self->get_secret resolves to the renamed accessor';

# --- native field :reader ---------------------------------------------------
my $native = <<'PL';
use v5.38;
class Point {
    field $x :reader;
    field $y :reader(get_y);
    field $z;
    method show { $self->x + $self->get_y }
}
PL

my ($s2, $o2) = graph($native, 'Point.pm');
my %m2 = map { $_ => 1 } methods($o2);
ok $m2{'Point::x'},      'field :reader emits a reader named after the field';
ok $m2{'Point::get_y'},  'field :reader(name) emits a reader with the given name';
ok !$m2{'Point::z'},     'a plain field (no :reader) emits no accessor';

my %sc = map { $_ => 1 } calls($s2, $o2, 'Point::show');
ok $sc{'Point::x'},     '$self->x resolves to the field reader';
ok $sc{'Point::get_y'}, '$self->get_y resolves to the named field reader';

# --- accessor-GENERATOR modules (Class::XSAccessor / Class::Tiny / Object::Tiny / Class::Accessor) ---
my $gen = <<'PL';
package Gen;
use Class::XSAccessor::Array getters => +{ path => 0, pages => 1 }, accessors => [qw/host/], predicates => { has_x => 2 };
use Class::Tiny qw(alpha beta);
use Object::Tiny qw(ro_one);
__PACKAGE__->mk_accessors(qw/name email/);
__PACKAGE__->mk_ro_accessors('id');
sub run { my $self = shift; $self->path + $self->alpha + $self->name + $self->id + $self->host + $self->has_x }
PL
my ($s3, $o3) = graph($gen, 'Gen.pm');
my %m3 = map { $_ => 1 } methods($o3);
ok $m3{'Gen::path'},   'Class::XSAccessor getters HASH -> accessor (key = method name)';
ok $m3{'Gen::pages'},  '... and the second hash key';
ok $m3{'Gen::host'},   'Class::XSAccessor accessors ARRAY -> accessor';
ok $m3{'Gen::has_x'},  'Class::XSAccessor predicates -> predicate method';
ok $m3{'Gen::alpha'},  'Class::Tiny qw(...) -> accessor';
ok $m3{'Gen::ro_one'}, 'Object::Tiny qw(...) -> accessor';
ok $m3{'Gen::name'},   'Class::Accessor __PACKAGE__->mk_accessors(...) -> accessor';
ok $m3{'Gen::id'},     'Class::Accessor mk_ro_accessors -> accessor';
ok !$m3{'Gen::Class'} && !$m3{'Gen::XSAccessor'}, 'the generator module name is not mistaken for an accessor';

my %gc = map { $_ => 1 } calls($s3, $o3, 'Gen::run');
ok $gc{'Gen::path'}, '$self->path resolves to the Class::XSAccessor accessor (was an unresolved/false-positive before)';
ok $gc{'Gen::name'}, '$self->name resolves to the Class::Accessor accessor';

# Class::XSAccessor's hashref-WRAPPER calling form: `use X { getters => {...}, accessors => [...] }`.
# The option keywords (getters/accessors) are hash keys here too -- they must NOT become accessors.
my $wrap = <<'PL';
package Wrap;
use Class::XSAccessor { getters => { foo => 0, bar => 1 }, accessors => [qw/baz/], constructor => 'new', chained => 1, replace => 1 };
1;
PL
my (undef, $ow) = graph($wrap, 'Wrap.pm');
my %mw = map { $_ => 1 } methods($ow);
ok $mw{'Wrap::foo'} && $mw{'Wrap::bar'}, 'wrapper form: the getters-hash keys become accessors';
ok $mw{'Wrap::baz'},                     'wrapper form: the accessors-array element becomes an accessor';
ok !$mw{'Wrap::getters'} && !$mw{'Wrap::accessors'}, 'wrapper form: the hash/array OPTION keywords are not mistaken for accessors';
ok !$mw{'Wrap::constructor'} && !$mw{'Wrap::chained'} && !$mw{'Wrap::replace'},
   'wrapper form: the scalar/boolean OPTION keywords (constructor/chained/replace) are not mistaken for accessors';

# Class::Tiny's HASH-DEFAULT form `{ attr => $default }` -- the KEYS are the attributes, the
# string defaults must NOT be collected as accessor names (and the keys must NOT be missed).
my $cth = <<'PL';
package CT;
use Class::Tiny { host => 'localhost', port => 8080 };
sub run { my $self = shift; $self->host . $self->port }
1;
PL
my ($sct, $oct) = graph($cth, 'CT.pm');
my %mct = map { $_ => 1 } methods($oct);
ok $mct{'CT::host'} && $mct{'CT::port'}, 'Class::Tiny hash form: the keys become accessors';
ok !$mct{'CT::localhost'},               'Class::Tiny hash form: a string DEFAULT is not mistaken for an accessor';
my %ctc = map { $_ => 1 } calls($sct, $oct, 'CT::run');
ok $ctc{'CT::host'}, '$self->host resolves to the hash-form accessor';

# mk_accessors fires only for a CLASS invocant (__PACKAGE__ / Pkg), never `$obj->mk_accessors`.
my $mk = <<'PL';
package Mk;
use base 'Class::Accessor';
__PACKAGE__->mk_accessors(qw/good/);
sub other { my $obj = shift; $obj->mk_accessors(qw/bad/) }
1;
PL
my (undef, $omk) = graph($mk, 'Mk.pm');
my %mmk = map { $_ => 1 } methods($omk);
ok $mmk{'Mk::good'}, 'mk_accessors on __PACKAGE__ emits the accessor';
ok !$mmk{'Mk::bad'}, 'mk_accessors on a real object var ($obj->) does NOT emit a phantom accessor on this package';

# a generated accessor is public surface but must NOT be flagged untested (metadata.accessor filter)
my %ut = map { ($_->{qualified_name} => 1) } App::PerlGraph::Query->new(store => $s3)->untested('Gen');
ok !$ut{'Gen::path'}, 'a generated accessor (Gen::path) is excluded from untested';
ok $ut{'Gen::run'},   '... but a normal sub (Gen::run) is still flagged untested';

done_testing;
