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
    return $store;
}
sub callees ($store, $caller) {
    my ($n) = $store->nodes_by_qname($caller);
    map { [ $store->node($_->{target})->{qualified_name}, $_->{provenance} ] }
        grep { $_->{target} } $store->outgoing_edges($n->{id}, 'calls');
}
sub has_callee ($store, $caller, $qn) { grep { $_->[0] eq $qn } callees($store, $caller) }

# Moo: `has db => (isa => 'Store')` makes `$self->db` return a Store, so the
# chained `$self->db->save` resolves against Store's MRO.
my $s = graph(<<'PL');
package App;
use Moo;
has db    => (is => 'ro', isa => 'Store');
has cache => (is => 'ro');                # no isa -> no return type known
has name  => (is => 'ro', isa => 'Str');  # a non-class type -> resolves to nothing
sub run   { my $self = shift; $self->db->save() }
sub run2  { my $self = shift; $self->cache->save() }
sub run3  { my $self = shift; $self->name->save() }
package Store;
sub new  { bless {} }
sub save { 1 }
PL

my %run = map { $_->[0] => $_->[1] } callees($s, 'App::run');
ok $run{'Store::save'},              '$self->db->save resolves via `has isa => Store` (chained)';
is $run{'Store::save'}, 'inferred',  '... with inferred provenance';
ok +(has_callee($s, 'App::run', 'App::db')), 'the intermediate $self->db accessor call still resolves too';
ok !(grep { $_->[0] =~ /save/ } callees($s, 'App::run2')), 'an untyped attr does not resolve the chain (no guess)';
ok !(grep { $_->[0] =~ /save/ } callees($s, 'App::run3')), 'a non-class isa type fabricates nothing';

# the chain composes with 0.009 local type inference: my $x = App->new; $x->db->save
my $s2 = graph(<<'PL');
package App;
use Moo;
has db => (is => 'ro', isa => 'Store');
package Client;
sub go { my $app = App->new; $app->db->save() }
package Store;
sub new  { bless {} }
sub save { 1 }
package App;
sub new { bless {} }
PL
ok +(has_callee($s2, 'Client::go', 'Store::save')), 'my $x = App->new; $x->db->save chains through the inferred type';

# native class: `field $x :reader :isa(Class)` gives the reader a return type too
my $s3 = graph(<<'PL');
use experimental 'class';
class Widget {
    field $log :reader :isa(Logger);
    method run { $self->log->write() }
}
class Logger {
    method write { 1 }
}
PL
ok +(has_callee($s3, 'Widget::run', 'Logger::write')), 'native field :isa(Logger): $self->log->write chains';

done_testing;
