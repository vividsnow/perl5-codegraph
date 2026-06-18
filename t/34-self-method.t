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
$dir->child('lib/Animal.pm')->spew_utf8(<<'PERL');
package Animal;
sub new      { bless {}, shift }
sub describe { my $self = shift; $self->speak }   # $self->speak -> Animal::speak
sub speak    { my $self = shift; $self->sound }   # $self->sound -> Animal::sound
sub sound    { 'generic' }
sub via_obj  { my $x = make(); $x->sound }        # unknown receiver -> NOT resolved
sub via_cls  { my $class = shift; $class->sound } # $class->sound -> Animal::sound
1;
PERL
$dir->child('lib/Dog.pm')->spew_utf8(<<'PERL');
package Dog;
our @ISA = ('Animal');
sub sound { 'woof' }
sub run   { my $self = shift; $self->speak }      # inherited Animal::speak via @ISA
1;
PERL
$dir->child('lib/Both.pm')->spew_utf8(<<'PERL');
package Both;
sub go     { my $self = shift; helper(); $self->helper }  # bareword (static) + $self-> (heuristic)
sub helper { 1 }
1;
PERL
# package-scope call to a name that is ambiguous globally: only resolves if the
# enclosing *package* (not 'main') is used as the search scope.
$dir->child('lib/Scope.pm')->spew_utf8(<<'PERL');
package One;
our $loaded = boot();   # package-scope call -> from-node is the One package node
sub boot { 1 }
package Two;
sub boot { 2 }          # same name elsewhere -> the global fallback is ambiguous
1;
PERL

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
App::PerlGraph::Indexer->new(store => $store, root => "$dir")->index_all;
my $q = App::PerlGraph::Query->new(store => $store);

sub callees_of { my %h = map { ($_->{qualified_name} // $_->{name}) => $_ } $q->callees($_[0]); \%h }

my $describe = callees_of('Animal::describe');
ok $describe->{'Animal::speak'},                    '$self->speak resolves to the enclosing package';
is $describe->{'Animal::speak'}{_provenance}, 'heuristic', 'self-method edge carries provenance heuristic';

ok callees_of('Animal::speak')->{'Animal::sound'}, '$self->sound resolves within the package';
ok callees_of('Animal::via_cls')->{'Animal::sound'},'$class->method resolves like $self';

# inheritance: Dog::run -> $self->speak -> inherited Animal::speak (through @ISA)
ok callees_of('Dog::run')->{'Animal::speak'},       '$self->method resolves through @ISA to a parent';

# unknown receiver: no false edge
ok !callees_of('Animal::via_obj')->{'Animal::sound'},'$obj->method on an unknown receiver is not resolved';

# the whole point: path now traverses $self->method chains
is join(',', map { $_->{name} } $q->path('Animal::describe', 'Animal::sound')),
   'describe,speak,sound',                          'path traverses self-method edges end to end';

# a method with no local/ancestor definition stays unresolved (no guess edge)
ok !callees_of('Animal::describe')->{'Animal::nonexistent'}, 'no guess edge for an undefined method';

# a certain static (bareword) call out-labels a heuristic $self-> call to the same target
is callees_of('Both::go')->{'Both::helper'}{_provenance}, 'static',
   'static call wins the provenance label over a heuristic one (heuristic ranks below static)';

# package-scope call resolves against the enclosing package, not 'main'
ok callees_of('One')->{'One::boot'},
   'package-scope bareword call resolves against the package despite an ambiguous global';

done_testing;
