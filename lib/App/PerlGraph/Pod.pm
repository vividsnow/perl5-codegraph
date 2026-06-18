package App::PerlGraph::Pod;
use v5.36;
our $VERSION = q{0.001};

# Map a documented name -> its POD text (first block), from `=headN name` /
# `=item name` sections. Heuristic but covers the common "one section per sub"
# convention; the name is the first identifier on the heading (POD formatting
# codes like C<...> are stripped first).
sub extract ($src) {
    my %doc;
    my ($name, @buf, $collecting);
    my $flush = sub {
        if (defined $name) {
            (my $d = join "\n", @buf) =~ s/\A\s+|\s+\z//g;
            $doc{$name} //= $d if length $d;
        }
        $name = undef; @buf = ();
    };
    for my $l (split /\n/, $src, -1) {
        if ($l =~ /^=(?:head[1-4]|item)\s+(.+?)\s*$/) {
            $flush->();
            (my $h = $1) =~ s/[A-Z]<+\s*(.*?)\s*>+/$1/g;          # strip C<>, B<>, ...
            if ($h =~ /([A-Za-z_]\w*(?:::\w+)*)/) { $name = $1; $collecting = 1 }
        }
        elsif ($l =~ /^=cut\b/)              { $flush->(); $collecting = 0 }
        elsif ($l =~ /^=[a-z]/)              { $flush->() }       # any other directive ends the block
        elsif ($collecting && defined $name) { push @buf, $l }
    }
    $flush->();
    return \%doc;
}
1;

__END__

=head1 NAME

App::PerlGraph::Pod - extract POD docstrings by name

=head1 DESCRIPTION

Maps a documented name to its first POD block, for attaching docstrings to symbols.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
