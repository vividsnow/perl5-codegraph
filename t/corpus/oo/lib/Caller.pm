package Caller;
use strict; use warnings;
sub name  { "caller-name" }                                   # collision name
sub greet { my $self = shift; return $self->name }            # $self -> resolves to Caller::name
sub run   { my $self = shift; my $other = Animal->new; return $other->name }  # $other -> must NOT resolve
1;
