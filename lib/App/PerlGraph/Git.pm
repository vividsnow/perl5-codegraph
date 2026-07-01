package App::PerlGraph::Git;
use v5.36;
our $VERSION = q{0.075};
use Moo;

# Thin read-only wrapper over `git log` for the history-aware analyses (churn for
# risk scoring, per-commit file sets for co-change mining, per-file author counts
# for ownership/bus-factor). Shells out to the git CLI (list-form open, no shell);
# every method degrades to empty when the root isn't a git work tree or git isn't
# installed.

has root => (is => 'ro', required => 1);

sub available ($self) {
    my $r = $self->_run('rev-parse', '--is-inside-work-tree');
    return defined $r && $r =~ /\btrue\b/;
}

# A git revision can never start with '-' (refname rules forbid it), so a leading-dash
# "ref" is git option-injection (e.g. `--output=FILE` -> arbitrary file write), never a
# real ref. Refs reach here from `pcg diff/review/affected --since` and their MCP tools,
# which an agent may drive on untrusted input -- so reject at this chokepoint.
sub _safe_ref ($r) { defined $r && length $r && $r !~ /\A-/ }

# { file_path => number_of_commits_that_touched_it }. With since => REF, only
# commits in REF..HEAD (e.g. churn on a branch).
sub churn ($self, %opt) {
    my $range = _safe_ref($opt{since}) ? "$opt{since}..HEAD" : ();
    # --relative: paths relative to the -C dir (so they match the graph's keys even
    # when the indexed project is a subdirectory of a larger git repo).
    my $out = $self->_run('log', '--relative', '--format=', '--name-only', ($range // ())) // return {};
    my %c;
    $c{$_}++ for grep { length } split /\n/, $out;
    return \%c;
}

# [ [file, ...], ... ] -- each commit's touched-file set, newest first, capped at
# $limit commits. The transactions co-change mining runs association rules over.
sub commits ($self, $limit = 3000) {
    my $out = $self->_run('log', "-n$limit", '--relative', '--format=%x00', '--name-only') // return [];
    my @tx;
    for my $block (split /\x00\n?/, $out) {
        my @files = grep { length } split /\n/, $block;
        push @tx, \@files if @files;
    }
    return \@tx;
}

# { file_path => { author => commits_touching_it } } -- per-file authorship from
# `git log`, for ownership / bus-factor analysis. Each commit emits a `\0<author>`
# header line followed by its touched files.
sub authors ($self) {
    my $out = $self->_run('log', '--relative', '--no-merges', '--format=%x00%an', '--name-only') // return {};
    my (%by, $who);
    for my $line (split /\n/, $out) {
        if ($line =~ /\A\x00(.*)/) { $who = $1; next }       # commit header: NUL + author name
        $by{$line}{$who}++ if length $line && defined $who;  # a file touched by that commit
    }
    return \%by;
}

# Perl files changed between $ref and the working tree (relative to the indexed
# root, via --relative -- so subdir-of-a-repo layouts work).
sub changed ($self, $ref) {
    return [] unless _safe_ref($ref);
    my $out = $self->_run('diff', '--name-only', '--relative', $ref) // return [];
    return [ grep { /\.(?:pm|pl|t|xs)\z/ } split /\n/, $out ];
}

# Content of an index-root-relative $path at $ref, or undef if it didn't exist
# there. `git show ref:path` wants a repo-root-relative path, so prepend the
# repo->index subdir prefix.
sub show ($self, $ref, $path) {
    return undef unless _safe_ref($ref);
    my $p = $self->{_prefix} //= do { my $x = $self->_run('rev-parse', '--show-prefix'); $x =~ s/\s+\z// if defined $x; $x // '' };
    return $self->_run('show', "$ref:$p$path");
}

sub _run ($self, @args) {
    require File::Spec;
    # silence git's own diagnostics (e.g. "path exists on disk but not in <ref>"
    # for files added since the ref) -- we detect failure from the exit status.
    my $save;
    open $save, '>&', \*STDERR or undef $save;
    open STDERR, '>', File::Spec->devnull if $save;   # only silence if we can later restore it
    my $out;
    if (open my $fh, '-|', 'git', '-C', $self->root, @args) { local $/; $out = <$fh>; close $fh }
    my $rc = $?;
    open STDERR, '>&', $save if $save;
    return defined $out && $rc == 0 ? $out : undef;
}

1;

__END__

=head1 NAME

App::PerlGraph::Git - read-only git-history helpers (churn, co-change transactions)

=head1 DESCRIPTION

A thin wrapper over C<git log> backing the history-aware analyses: C<churn> (how
many commits touched each file, for risk scoring), C<commits> (each commit's
touched-file set, for co-change mining), and C<authors> (per-file author commit
counts, for ownership / bus-factor). Degrades to empty when the root is not a git
work tree.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
