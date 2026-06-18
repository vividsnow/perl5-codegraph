package App::PerlGraph::Model;
use v5.36;
our $VERSION = q{0.001};
use Exporter 'import';
use Digest::SHA qw(sha1_hex);

our @EXPORT_OK = qw(
    node_id package_of qualify is_builtin
    NODE_KINDS EDGE_KINDS PROVENANCE
);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

use constant NODE_KINDS => [qw(file package class role function method field constant variable route parameter)];
use constant EDGE_KINDS => [qw(contains calls references imports exports extends implements instantiates overrides)];
use constant PROVENANCE => [qw(static symtab optree mop xs framework heuristic)];

my %BUILTIN = map { $_ => 1 } qw(
    print printf say sprintf warn die defined ref bless wantarray
    push pop shift unshift splice map grep sort reverse join split
    keys values each exists delete scalar length substr index rindex
    open close read write chomp chop chr ord lc uc lcfirst ucfirst
    eval do require return last next redo local my our
    abs int sqrt rand srand sleep time
);

sub is_builtin ($name) { $BUILTIN{$name} ? 1 : 0 }

sub package_of ($qname) {
    return 'main' unless $qname =~ /::/;
    (my $p = $qname) =~ s/::[^:]+\z//;
    return $p;
}

sub qualify ($pkg, $name) { return "$pkg\::$name" }

sub node_id ($f) {
    # Stable across edits: line numbers are NOT part of the id, so re-indexing a
    # file (which shifts lines) keeps ids constant and inbound edges valid.
    return sha1_hex(join "\0",
        $f->{kind} // '', $f->{qualified_name} // $f->{name} // '',
        $f->{file_path} // '');
}
1;

__END__

=head1 NAME

App::PerlGraph::Model - node identity and name helpers

=head1 DESCRIPTION

Pure helpers shared across the graph: C<node_id>, C<qualify>, C<package_of>, C<is_builtin>.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
