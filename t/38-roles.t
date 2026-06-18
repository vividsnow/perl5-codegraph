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
$dir->child('lib/Roles.pm')->spew_utf8(<<'PERL');
package Role::Printable;
use Moo::Role;
sub print_me { 'printed' }
1;
package Role::Loud;
use Moo::Role;
sub shout { 'HEY' }
1;
package Thing;
use Moo;
with 'Role::Printable', 'Role::Loud';
sub run    { my $self = shift; $self->print_me }   # composed role method
sub yeller { my $self = shift; $self->shout }      # second composed role
1;
package Plain;
use Moo;
with 'Role::Printable' => { -alias => { print_me => 'myprint' } };  # option strings must not become roles
sub go { my $self = shift; $self->print_me }
1;
package Base2;
use Moo;
sub base_m { 'base' }
1;
package Kid;
use Moo;
extends 'Base2';                                   # modern inheritance (not `our @ISA`)
sub run2 { my $self = shift; $self->base_m }
1;
package MooseKid;
use Moose;
extends 'Base2';                                   # Moose, not Moo
1;
package MultiKid;
use Moo;
extends 'Base2', 'Plain';                          # multiple parents
1;
package MojoKid;
use Mojo::Base 'Base2', -signatures;               # Mojolicious inheritance idiom
1;
PERL

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
App::PerlGraph::Indexer->new(store => $store, root => "$dir")->index_all;
my $q = App::PerlGraph::Query->new(store => $store);

sub callees_of { my %h = map { ($_->{qualified_name} // $_->{name}) => $_ } $q->callees($_[0]); \%h }

my $run = callees_of('Thing::run');
ok $run->{'Role::Printable::print_me'},               '$self->role_method resolves through `with` composition';
is $run->{'Role::Printable::print_me'}{_provenance}, 'heuristic', 'composed-role self-method edge is heuristic';
ok callees_of('Thing::yeller')->{'Role::Loud::shout'},'a second composed role resolves too';

# the class -> role `implements` edge exists and is resolved
my ($thing) = $store->nodes_by_qname('Thing');
my ($printable) = $store->nodes_by_qname('Role::Printable');
my %impl = map { ($_->{target} => 1) } $store->outgoing_edges($thing->{id}, 'implements');
ok $impl{ $printable->{id} }, 'Thing -> Role::Printable implements edge resolved';

# option-hash args must NOT create bogus role edges, but the real role still resolves
ok callees_of('Plain::go')->{'Role::Printable::print_me'}, 'role resolves even with a trailing option hash';
my ($plain) = $store->nodes_by_qname('Plain');
my @impl = sort map { ($_->{metadata} || {})->{name} // '' } $store->outgoing_edges($plain->{id}, 'implements');
is \@impl, ['Role::Printable'],
   'only the role is an implements edge -- strings inside the option hash (myprint) are not';

# Moo/Moose `extends 'Base'` (the modern way, not `our @ISA`) -> extends edge + inheritance
ok callees_of('Kid::run2')->{'Base2::base_m'}, '$self->method resolves through Moo `extends` inheritance';
my ($kid)  = $store->nodes_by_qname('Kid');
my ($base) = $store->nodes_by_qname('Base2');
ok +(grep { ($_->{target} // '') eq $base->{id} } $store->outgoing_edges($kid->{id}, 'extends')),
   'Kid -> Base2 extends edge from Moo `extends` is resolved';

# Moose (not Moo) extends, multiple parents, and `use Mojo::Base 'Parent'` all become extends edges
sub extends_of { my ($n) = $store->nodes_by_qname($_[0]); sort map { ($_->{metadata} || {})->{name} // '' } $store->outgoing_edges($n->{id}, 'extends') }
is [extends_of('MooseKid')], ['Base2'],          'Moose `extends` (not just Moo) is detected';
is [extends_of('MultiKid')], ['Base2', 'Plain'], 'multiple parents -> multiple extends edges';
is [extends_of('MojoKid')],  ['Base2'],          "use Mojo::Base 'Parent' -> extends edge (Mojolicious)";

done_testing;
