package Dog;
use strict; use warnings;
use parent -norequire, 'Animal';
sub sound { "Woof" }                                            # overrides Animal::sound
sub fetch { my $self = shift; $self->speak; return Animal::sound() }
1;
