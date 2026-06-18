package App::PerlGraph::XS;
use v5.36;
our $VERSION = q{0.001};
use App::PerlGraph::Model qw(node_id);

# Scan an XS (.xs) source into { nodes, edges, refs }: a package node + a
# function node per XSUB (language => 'xs'), so Perl calls into XS resolve to
# them (the Perl <-> C bridge). XS convention: the XSUB return type is on its
# own line, immediately above the `name(args)` signature line, both at column 0.

my %XS_KW = map { $_ => 1 } qw(
    CODE PPCODE OUTPUT INPUT INIT PREINIT POSTCALL CLEANUP BOOT
    ALIAS PROTOTYPE OVERLOAD INTERFACE INTERFACE_MACRO SCOPE C_ARGS REQUIRE VERSIONCHECK
);

sub scan ($class, $file_path, $src) {
    my (@nodes, @edges, %pkg_node, $pkg, $in_xs, $in_body, $lineno);
    my $prev = ''; $in_xs = 0; $in_body = 0; $lineno = 0;
    my $ensure_pkg = sub ($p) {
        $pkg_node{$p} //= _emit(\@nodes, { kind => 'package', name => $p, qualified_name => $p,
            file_path => $file_path, language => 'xs', start_line => $lineno,
            metadata => { provenance => 'xs' } });
    };

    for my $line (split /\n/, $src, -1) {
        $lineno++;
        if ($line =~ /^\s*MODULE\s*=\s*(\S+)/) {                   # MODULE = X [PACKAGE = Y]
            $in_xs = 1; $in_body = 0; $prev = '';
            my $mod = $1;
            my ($p) = $line =~ /PACKAGE\s*=\s*(\S+)/;
            $pkg = $p // $mod;
            $ensure_pkg->($pkg);
            next;
        }
        if ($in_xs && $line =~ /^\s*PACKAGE\s*=\s*(\S+)/) {        # bare PACKAGE switch
            $pkg = $1; $ensure_pkg->($pkg); $in_body = 0; $prev = ''; next;
        }
        if ($line !~ /\S/) { $in_body = 0; $prev = ''; next; }     # blank line ends an XSUB body

        if ($in_xs && !$in_body && $line =~ /^([A-Za-z_]\w*)\s*\(/) {
            my $name = $1;                                         # capture before later regexes clobber $1
            if (!$XS_KW{$name}
                && $prev =~ /^[A-Za-z_][\w\s:*&]*$/                # previous line looks like a return type
                && $prev !~ /[;{}=]/ && $prev !~ /:\s*\z/) {       # ...not a C stmt or section label
                my $node = _emit(\@nodes, { kind => 'function', name => $name,
                    qualified_name => "${pkg}::${name}", file_path => $file_path, language => 'xs',
                    start_line => $lineno, metadata => { provenance => 'xs' } });
                push @edges, { source => $pkg_node{$pkg}{id}, target => $node->{id},
                    kind => 'contains', provenance => 'xs' } if $pkg_node{$pkg};
                $in_body = 1;                                      # skip the XSUB body that follows
            }
        }
        $prev = $line;
    }
    return { nodes => \@nodes, edges => \@edges, refs => [] };
}

sub _emit ($nodes, $n) {
    $n->{id} = node_id($n);
    push @$nodes, $n;
    return $n;
}
1;

__END__

=head1 NAME

App::PerlGraph::XS - scan .xs sources for XSUBs

=head1 DESCRIPTION

Emits C<language=xs> function nodes so Perl calls into C resolve to their XSUB.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
