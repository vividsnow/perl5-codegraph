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
    map { $store->node($_->{target})->{qualified_name} } grep { $_->{target} } $store->outgoing_edges($id{$from}, 'calls');
}

# Mojo::Base `has` in all its forms -- always a rw accessor named after the attribute.
my $src = <<'PL';
package Widget;
use Mojo::Base -base, -signatures;
has 'title';
has [qw(width height)];
has bg   => 'white';
has data => sub { {} };
sub render ($self) { $self->title . $self->width . $self->bg . $self->data . $self->height }
PL

my ($s, $o) = graph($src, 'Widget.pm');
my %m = map { $_ => 1 } methods($o);
ok $m{'Widget::title'},  'has \'title\' -> accessor';
ok $m{'Widget::width'},  'has [qw(...)] -> accessor (width)';
ok $m{'Widget::height'}, '... and height';
ok $m{'Widget::bg'},     'has attr => default -> accessor';
ok $m{'Widget::data'},   'has attr => sub {...} -> accessor';

my %rc = map { $_ => 1 } calls($s, $o, 'Widget::render');
ok $rc{'Widget::title'}, '$self->title resolves to the Mojo accessor';
ok $rc{'Widget::data'},  '$self->data resolves too';

# a Mojo accessor is inherited: a controller `use Mojo::Base 'Widget'` resolves
# $self->title up the (static) MRO to the parent's accessor.
my $sub = <<'PL';
package Panel;
use Mojo::Base 'Widget';
sub draw { my $self = shift; $self->title }
PL
# index parent + child together
{
    my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
    for my $f (['Widget.pm', $src], ['Panel.pm', $sub]) {
        my $out = App::PerlGraph::Extractor->new(file_path => $f->[0])->extract($parser->parse_string($f->[1]));
        $store->insert_node($_) for @{$out->{nodes}}; $store->insert_edge($_) for @{$out->{edges}};
        $store->insert_unresolved($_) for @{$out->{refs}};
    }
    App::PerlGraph::Resolver->new(store => $store)->resolve_all;
    my ($draw) = $store->nodes_by_qname('Panel::draw');
    my @t = map { $store->node($_->{target})->{qualified_name} } grep { $_->{target} } $store->outgoing_edges($draw->{id}, 'calls');
    ok scalar(grep { $_ eq 'Widget::title' } @t), 'inherited Mojo accessor resolves up the MRO (Panel->draw calls Widget::title)';
}

# Mojolicious helpers: `helper name => sub` / `$app->helper(name => sub)` are
# callable as $c->name anywhere -> method nodes the resolver matches by name.
my $lite = <<'PL';
use Mojolicious::Lite;
helper db => sub { my $c = shift; return $c };
app->helper(model => sub { my $c = shift; $c->db });
get '/x' => sub { my $c = shift; $c->db; $c->model };
PL
my ($s3, $o3) = graph($lite, 'app.pl');
my %m3 = map { $_ => 1 } methods($o3);
ok $m3{'main::db'},    'helper db => sub -> method node';
ok $m3{'main::model'}, '$app->helper(model => sub) -> method node';

# the db helper resolves on an opaque receiver ($c->db) inside the model helper's body
my ($model) = $s3->nodes_by_qname('main::model');
my @mc = map { $s3->node($_->{target})->{qualified_name} } grep { $_->{target} } $s3->outgoing_edges($model->{id}, 'calls');
ok scalar(grep { $_ eq 'main::db' } @mc), '$c->db (opaque receiver) resolves to the db helper (framework)';
# and the provenance is framework, not a fabricated static edge
my ($dbn) = $s3->nodes_by_qname('main::db');
my ($e) = grep { $_->{target} && $_->{target} eq $dbn->{id} } $s3->outgoing_edges($model->{id}, 'calls');
is $e->{provenance}, 'framework', 'helper resolution carries framework provenance';

# Mojo::Base classes compose roles with `with` (Role::Tiny), like Moo -- recognized as
# `implements` edges (so role methods resolve up the MRO), not phantom `with` calls.
my (undef, $rout) = graph(<<'PL', 'R.pm');
package Ctrl;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Role::Tiny::With;
with 'My::Role::Track';
with qw/My::Role::A My::Role::B/;
sub act ($self) { 1 }
PL
my @roles = sort map { $_->{metadata}{name} } grep { $_->{kind} eq 'implements' } @{ $rout->{edges} };
is \@roles, [qw(My::Role::A My::Role::B My::Role::Track)], 'Mojo::Base `with` composes roles as implements edges';
ok !(grep { $_->{reference_name} eq 'with' } @{ $rout->{refs} }), 'the `with` calls are not left as phantom unresolved';

done_testing;
