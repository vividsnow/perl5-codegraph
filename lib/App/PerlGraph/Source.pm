package App::PerlGraph::Source;
use v5.36;
our $VERSION = q{0.001};
use Path::Tiny qw(path);

# Read a node's verbatim source from its file by line range, so queries can
# return code (not just locations). $base is the directory file_path is relative
# to (the index root); absolute file_paths ignore it. Returns undef when the
# node has no file/line (e.g. runtime symtab nodes) or the file is unreadable.
use constant MAX_LINES => 150;

sub for_node ($node, $base = '') {
    my $fp = $node->{file_path} or return undef;
    return undef unless defined $node->{start_line};
    # file_path is stored as walked (relative to the index cwd, or absolute);
    # try it directly, then fall back to $base for callers that store project-relative paths.
    my $p = path($fp);
    $p = path($base, $fp) if !$p->is_file && length $base && $fp !~ m{^/};
    return undef unless $p->is_file;
    my @lines = eval { $p->lines_utf8({ chomp => 0 }) };
    $@ = '';                                     # eval is fail-soft by design
    return undef unless @lines;
    my $s = $node->{start_line} - 1;
    my $e = ($node->{end_line} // $node->{start_line}) - 1;
    $s = 0       if $s < 0;
    $e = $#lines if $e > $#lines;
    return undef if $s > $e;
    my $trunc = ($e - $s + 1) > MAX_LINES;
    $e = $s + MAX_LINES - 1 if $trunc;
    my $src = join '', @lines[$s .. $e];
    $src .= "...\n" if $trunc;
    return $src;
}
1;

__END__

=head1 NAME

App::PerlGraph::Source - read a node verbatim source by line range

=head1 DESCRIPTION

Returns the source text spanning a node so queries can show definitions.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
