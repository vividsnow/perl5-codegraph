package App::PerlGraph::Diff;
use v5.36;
our $VERSION = q{0.037};
use Moo;
use Path::Tiny qw(path);
use App::PerlGraph::Git;
use App::PerlGraph::Extractor;
use App::PerlGraph::Model qw(is_public);

# Structural ("semantic") diff between a git ref and the working tree: which
# symbols were added, removed, or had their signature change -- and whether any
# of those touch the PUBLIC surface (a breaking change). Both sides are parsed
# fresh (the ref via `git show`, the working tree from disk), so the result is
# independent of how stale the on-disk graph is.

has root   => (is => 'ro', required => 1);
has ref    => (is => 'ro', required => 1);   # the git ref to compare against (e.g. main, HEAD~3)
has parser => (is => 'ro', required => 1);   # an App::PerlGraph::Parser

my $KINDS = qr/\A(?:function|method|constant|package|class)\z/;

sub diff ($self) {
    my $git = App::PerlGraph::Git->new(root => $self->root);
    my (@added, @removed, @changed);
    for my $file (@{ $git->changed($self->ref) }) {
        my %old = map { ($_->{qualified_name} => $_) } $self->_symbols($git->show($self->ref, $file), $file);
        my $cur = path($self->root)->child($file);
        my %new = $cur->is_file       # raw bytes, like git->show + every other parse site: the parser
            ? (map { ($_->{qualified_name} => $_) } $self->_symbols(scalar $cur->slurp_raw, $file)) : ();   # is byte-oriented, and a decoded vs byte name would mis-key a non-ASCII symbol
        push @added, $new{$_} for grep { !exists $old{$_} } keys %new;
        for my $q (keys %old) {
            if (!exists $new{$q}) {
                push @removed, { %{ $old{$q} }, _breaking => is_public($old{$q}) };
            }
            elsif (($old{$q}{signature} // '') ne ($new{$q}{signature} // '')) {
                push @changed, { old => $old{$q}, new => $new{$q}, _breaking => is_public($new{$q}) };
            }
        }
    }
    return {
        added   => [ sort { ($a->{qualified_name} // '') cmp ($b->{qualified_name} // '') } @added ],
        removed => [ sort { ($a->{qualified_name} // '') cmp ($b->{qualified_name} // '') } @removed ],
        changed => [ sort { ($a->{new}{qualified_name} // '') cmp ($b->{new}{qualified_name} // '') } @changed ],
    };
}

sub _symbols ($self, $src, $file) {
    return () unless defined $src && length $src;
    my $tree = eval { $self->parser->parse_string($src) } or return ();
    my $out = App::PerlGraph::Extractor->new(file_path => $file)->extract($tree);
    return grep { ($_->{kind} // '') =~ $KINDS } @{ $out->{nodes} };
}

1;

__END__

=head1 NAME

App::PerlGraph::Diff - structural diff of symbols between a git ref and the working tree

=head1 DESCRIPTION

Compares the symbols defined at a git C<ref> against the current working tree:
returns the C<added>, C<removed> and signature-C<changed> functions/methods/
constants/packages, each removed/changed public symbol flagged C<_breaking>.
Both sides are parsed fresh (the ref via C<git show>), so it doesn't depend on
the indexed graph being current. Backs C<pcg diff>.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
