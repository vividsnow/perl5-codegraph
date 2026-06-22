use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::Store;
use App::PerlGraph::Resolver;

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

done_testing;
