package Animal;
use strict; use warnings;
sub new   { my $class = shift; return bless { @_ }, $class }
sub speak { my $self = shift; return $self->sound() . "!" }   # dynamic dispatch via $self
sub sound { "generic" }
sub name  { $_[0]->{name} }
1;
