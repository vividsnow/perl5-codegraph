package Widget;
use Moose;
with 'Role::Printable';
has size => (is => 'ro');
sub area { my $self = shift; return $self->size }
__PACKAGE__->meta->make_immutable;
1;
