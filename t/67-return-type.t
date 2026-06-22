use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::Store;
use App::PerlGraph::Resolver;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

sub graph ($src) {
    my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
    my $out = App::PerlGraph::Extractor->new(file_path => 'A.pm')->extract($parser->parse_string($src));
    $store->insert_node($_)       for @{ $out->{nodes} };
    $store->insert_edge($_)       for @{ $out->{edges} };
    $store->insert_unresolved($_) for @{ $out->{refs} };
    App::PerlGraph::Resolver->new(store => $store)->resolve_all;
    return ($store, $out);
}
sub callees ($store, $caller) {
    my ($n) = $store->nodes_by_qname($caller);
    map { [ $store->node($_->{target})->{qualified_name}, $_->{provenance} ] }
        grep { $_->{target} } $store->outgoing_edges($n->{id}, 'calls');
}
sub has_callee ($store, $caller, $qn) { grep { $_->[0] eq $qn } callees($store, $caller) }

my ($s, $out) = graph(<<'PL');
package App;
sub make_db   { Store->new }            # implicit-return constructor
sub get_cache { return Cache->new }     # explicit-return constructor
sub plain     { my $x = 1; $x + 2 }     # no constructor return
sub run  { my $self = shift; $self->make_db->save() }   # $self->builder->method
sub run2 { make_db()->save() }                          # func()->method
package Store; sub new { bless {} } sub save  { 1 }
package Cache; sub new { bless {} } sub flush { 1 }
PL

# the return type is captured on the producing subs
my %byq = map { ($_->{qualified_name} => $_) } @{ $out->{nodes} };
is $byq{'App::make_db'}{metadata}{returns},   'Store', '`sub { Store->new }` records a Store return type';
is $byq{'App::get_cache'}{metadata}{returns}, 'Cache', '`return Cache->new` records a Cache return type';
ok !($byq{'App::plain'}{metadata} && $byq{'App::plain'}{metadata}{returns}), 'a non-constructor sub records no return type';

# the chains resolve through the return type
ok +(has_callee($s, 'App::run',  'Store::save')), '$self->make_db->save resolves via the builder return type';
ok +(has_callee($s, 'App::run2', 'Store::save')), 'make_db()->save resolves via the function return type';
my %r = map { $_->[0] => $_->[1] } callees($s, 'App::run');
is $r{'Store::save'}, 'inferred', '... as `inferred` provenance';

done_testing;
