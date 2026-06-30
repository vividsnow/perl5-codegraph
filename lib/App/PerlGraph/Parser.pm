package App::PerlGraph::Parser;
use v5.36;
our $VERSION = q{0.072};
use Moo;
use Text::Treesitter;
no warnings 'recursion';                 # deep but bounded CST walks (after Moo re-enables warnings)
no warnings 'experimental::for_list';    # multi-var foreach is experimental on 5.36 (stable in 5.40)

has lang_name  => (is => 'ro', default => 'perl');
has parser_dir => (is => 'ro', default => sub {
    $ENV{PCG_TS_PARSER_DIR} // "$ENV{HOME}/.cache/pcg/tree-sitter-perl";
});
has _ts => (is => 'lazy');

sub _build__ts ($self) {
    return Text::Treesitter->new(
        lang_name => $self->lang_name,
        lang_dir  => $self->parser_dir,
    );
}

# Returns a Text::Treesitter::Tree.
sub raw_parse ($self, $src) { return $self->_ts->parse_string($src); }

sub parse_string ($self, $src) {
    my $tree = $self->raw_parse($src);
    return $self->_normalize($tree->root_node);
}

# Convert a Text::Treesitter::Node into a plain hashtree. All 3rd-party Node
# accessors are confined to this method. NB: ->text is ~75% of this method's
# cost, but it can't be replaced by substr($src, start_byte..end_byte): with
# multi-byte UTF-8 the tree-sitter byte offsets do not index the raw Perl byte
# string 1:1, so substr returns the wrong slice. ->text is the only correct read.
sub _normalize ($self, $node) {
    my ($sr, $sc) = $node->start_point;
    my ($er, $ec) = $node->end_point;
    my (@children, %fields);
    foreach my ($fname, $child) ($node->field_names_with_child_nodes) {
        my $norm = $self->_normalize($child);
        push @children, $norm;
        $fields{$fname} = $norm if defined $fname;
    }
    return {
        type     => $node->type,
        text     => $node->text,
        named    => $node->is_named ? 1 : 0,
        sl => $sr + 1, sc => $sc, el => $er + 1, ec => $ec,
        children => \@children,
        fields   => \%fields,
    };
}

1;

__END__

=head1 NAME

App::PerlGraph::Parser - parse Perl into a normalized hashtree via tree-sitter

=head1 DESCRIPTION

Wraps L<Text::Treesitter> and the tree-sitter-perl grammar, normalizing the CST into a plain hashtree the extractor walks.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
