package App::PerlGraph::Review;
use v5.36;
our $VERSION = q{0.047};
use Moo;
use App::PerlGraph::Git;
use App::PerlGraph::Diff;
use App::PerlGraph::Query;
use App::PerlGraph::Model qw(is_public);

# Composes the change-oriented analyses into one branch/PR review: the structural
# diff vs a git ref (added/removed/re-signatured symbols, breaking-API flagged),
# the blast radius of the changed files (affected files + tests to run), and the
# current caller count of each touched symbol. One call answers "what does this
# change do, what breaks, and what should I test".

has root   => (is => 'ro', required => 1);
has ref    => (is => 'ro', required => 1);
has parser => (is => 'ro', required => 1);   # for the structural diff
has store  => (is => 'ro', required => 1);   # the current (indexed) graph, for affected/callers

sub review ($self) {
    my @files = @{ App::PerlGraph::Git->new(root => $self->root)->changed($self->ref) };
    my $diff  = App::PerlGraph::Diff->new(root => $self->root, ref => $self->ref, parser => $self->parser)->diff;
    my $q     = App::PerlGraph::Query->new(store => $self->store);
    # annotate each touched symbol with its current caller count (blast radius of
    # touching it). For a removed symbol this is who still calls the gone name.
    for my $s (@{ $diff->{removed} }, (map { $_->{new} } @{ $diff->{changed} }), @{ $diff->{added} }) {
        $s->{_callers} = scalar $q->callers($s->{qualified_name} // '');
    }
    # graph-derived findings the reviewer should act on, beyond the raw diff. Only
    # CALLABLE symbols can be "untested" -- a package/class node has no test that
    # reaches it directly, so it would be a vacuous (noisy) untested finding.
    my (@untested, @wide);
    for my $s (@{ $diff->{added} }, map { $_->{new} } @{ $diff->{changed} }) {   # added/changed public API no test reaches
        next unless is_public($s) && defined $s->{qualified_name}
                 && ($s->{kind} // '') =~ /\A(?:function|method|constant)\z/;
        push @untested, $s unless scalar $q->covers($s->{qualified_name});
    }
    for my $s (@{ $diff->{removed} }, map { $_->{new} } @{ $diff->{changed} }) { # changed/removed symbol many things still call
        push @wide, $s if is_public($s) && ($s->{_callers} // 0) >= 5;
    }
    return {
        ref      => $self->ref,
        files    => \@files,
        diff     => $diff,
        affected => [ $q->affected(\@files) ],
        tests    => [ $q->affected(\@files, tests_only => 1) ],
        findings => { untested => \@untested, wide => \@wide },
    };
}

1;

__END__

=head1 NAME

App::PerlGraph::Review - synthesize a branch/PR review from the change analyses

=head1 DESCRIPTION

Combines L<App::PerlGraph::Diff> (structural diff vs a git ref), the affected-files
and affected-tests closure, and current caller counts into one review report:
what changed, what breaks (removed / re-signatured public API), and which tests to
run. Backs C<pcg review>.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
