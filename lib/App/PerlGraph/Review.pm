package App::PerlGraph::Review;
use v5.36;
our $VERSION = q{0.075};
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
        next if ($s->{metadata} // {})->{accessor};                              # generated accessors need no test of their own
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

# A scored PR-HEALTH GATE, built on top of review(): the same change analysis, PLUS the
# changed files linted for call bugs (checkcalls / checkargs, scoped to the touched files --
# you should fix broken calls in code you're editing), folded into one weighted 0-100 health
# score and a PASS / REVIEW / BLOCK verdict for CI. Each concern type deducts; the renderer
# lists them worst-first. A heuristic signal, not a substitute for human review.
my %PR_WEIGHT = (breaking => 15, broken => 12, arity => 10, untested => 6, wide => 4);

sub pr ($self) {
    my $rv = $self->review;
    my $q  = App::PerlGraph::Query->new(store => $self->store);
    my %changed = map { ($_ => 1) } @{ $rv->{files} };
    my $diff = $rv->{diff};

    my @breaking = grep { $_->{_breaking} } @{ $diff->{removed} }, @{ $diff->{changed} };
    my @broken   = grep { $changed{ $_->{file} // '' } } @{ $q->checkcalls };
    my @arity    = grep { $changed{ $_->{file} // '' } } @{ $q->checkargs($self->root) };
    my $untested = $rv->{findings}{untested};
    my $wide     = $rv->{findings}{wide};

    my %count = (breaking => scalar @breaking, broken => scalar @broken, arity => scalar @arity,
                 untested => scalar @$untested, wide => scalar @$wide);
    my $score = 100;
    $score -= $PR_WEIGHT{$_} * $count{$_} for keys %count;
    $score = 0 if $score < 0;
    my $verdict = $score >= 85 ? 'PASS' : $score >= 60 ? 'REVIEW' : 'BLOCK';

    return {
        ref      => $self->ref,
        score    => $score,
        verdict  => $verdict,
        counts   => \%count,
        breaking => \@breaking,
        broken   => \@broken,
        arity    => \@arity,
        untested => $untested,
        wide     => $wide,
        nfiles   => scalar @{ $rv->{files} },
        tests    => $rv->{tests},
        affected => $rv->{affected},
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

C<pr> builds on C<review> to produce a scored PR-health gate: the same analysis plus
the changed files linted for call bugs (broken / wrong-arity calls), folded into a
weighted 0-100 score and a PASS / REVIEW / BLOCK verdict for CI. Backs C<pcg pr>.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
