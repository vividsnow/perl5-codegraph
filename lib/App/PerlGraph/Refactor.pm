package App::PerlGraph::Refactor;
use v5.36;
our $VERSION = q{0.047};
use Moo;
use App::PerlGraph::Model qw(package_of);
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::Resolver;
use Path::Tiny qw(path);

# Graph-driven rename of a function/method to a new short name in its OWN package.
# The graph supplies the candidate files and the resolver decides which call sites
# really target the symbol (so a same-named method on a different class is left
# alone); each affected file is re-parsed for byte-precise positions. Dynamic
# `$obj->method` dispatch the resolver can't tie to this symbol is reported as the
# honest frontier, never silently edited.

has store  => (is => 'ro', required => 1);
has root   => (is => 'ro', required => 1);   # filesystem root, to read/write the source
has parser => (is => 'lazy', builder => sub { App::PerlGraph::Parser->new });

sub rename ($self, $old, $new, %opt) {
    my $s = $self->store;
    my @defs = grep { ($_->{kind} // '') =~ /method|function/ }
               ($old =~ /::/ ? $s->nodes_by_qname($old) : $s->nodes_by_name($old));
    return { error => "no function/method named '$old'" }                            unless @defs;
    return { error => "'$old' is ambiguous (@{[ scalar @defs ]} defs) -- qualify it" } if @defs > 1;

    my $def   = $defs[0];
    my $old_q = $def->{qualified_name};
    my $pkg   = package_of($old_q);
    my $old_s = $old_q =~ s/.*:://r;
    # Rename is within one package -- the new name is a bare identifier. Reject a
    # qualified `Pkg::name` outright rather than silently stripping its package (which
    # would quietly ignore a cross-package move the user actually asked for).
    return { error => "give a bare new name, not '$new' (rename is within one package)" } if $new =~ /::/;
    my $new_s = $new;
    return { error => "'$new_s' is not a valid identifier" }   unless $new_s =~ /\A\w+\z/;
    return { error => "the name is unchanged" }                if $new_s eq $old_s;
    return { error => "${pkg}::${new_s} already exists" }
        if grep { ($_->{kind} // '') =~ /method|function/ } $s->nodes_by_qname("${pkg}::${new_s}");

    my $resolver = App::PerlGraph::Resolver->new(store => $s);

    # candidate files: the definition, every resolved caller, and every file with an
    # unresolved ref of the short name (the dynamic-dispatch sites to vet/report).
    my %files = ($def->{file_path} => 1);
    for my $e ($s->incoming_edges($def->{id}, 'calls', 'references')) {
        my $n = $s->node($e->{source});
        $files{ $n->{file_path} } = 1 if $n && defined $n->{file_path};
    }
    $files{ $_->{file_path} } = 1
        for $s->_rows('select distinct file_path from unresolved_refs where reference_name = ?', $old_s);

    my (@edits, @frontier);
    for my $file (sort keys %files) {
        my $disk = path($self->root)->child($file);
        next unless $disk->is_file;
        my $src  = $disk->slurp_raw;
        my $out  = eval { App::PerlGraph::Extractor->new(file_path => $file, source => $src)
                              ->extract($self->parser->parse_string($src)) } or next;
        for my $r (@{ $out->{refs} }) {
            my $nm = $r->{reference_name};
            next unless $nm eq $old_s || $nm eq $old_q;
            my $is_method = ($r->{reference_kind} // '') eq 'method_call';
            my $tn = $is_method ? ($resolver->_resolve_method($r))[0] : $resolver->_resolve_call($r);
            if ($tn && $tn->{id} eq $def->{id}) {                          # provably this symbol -> safe edit
                push @edits, { file => $file, line => $r->{line}, col => $r->{col},
                               old => $nm, new => ($nm =~ /::/ ? "${pkg}::${new_s}" : $new_s),
                               method => $is_method };   # method_call col points at the RECEIVER, name is after ->
            }
            elsif ($is_method && $nm eq $old_s) {                         # opaque dispatch -> can't verify
                push @frontier, { file => $file, line => $r->{line}, col => $r->{col},
                                  receiver => ($r->{candidates} // {})->{receiver} };
            }
        }
    }
    push @edits, { file => $def->{file_path}, line => $def->{start_line}, def => 1, old => $old_s, new => $new_s };

    my $applied = $opt{apply} ? $self->_apply(\@edits) : 0;
    return { old => $old_q, new => "${pkg}::${new_s}", edits => \@edits, frontier => \@frontier,
             files => [ sort keys %files ], applied => $applied };
}

# Apply the edits to disk: byte-precise replacement at (line, col), right-to-left per
# line so earlier edits don't shift later columns; each position is re-validated
# against the current bytes (a stale index skips that site rather than corrupting it).
sub _apply ($self, $edits) {
    my %by_file;
    push @{ $by_file{ $_->{file} } }, $_ for @$edits;
    my $count = 0;
    for my $file (sort keys %by_file) {
        my $disk  = path($self->root)->child($file);
        next unless $disk->is_file;
        my @lines = split /(?<=\n)/, $disk->slurp_raw;
        my %per_line;
        push @{ $per_line{ $_->{line} } }, $_ for @{ $by_file{$file} };
        for my $ln (sort keys %per_line) {
            my $i = $ln - 1;
            next unless defined $lines[$i];
            for my $e (sort { ($b->{col} // -1) <=> ($a->{col} // -1) } @{ $per_line{$ln} }) {
                if ($e->{def}) {                                          # the `sub NAME` / `method NAME` declaration
                    $count++ if $lines[$i] =~ s/\b(sub|method)(\s+)\Q$e->{old}\E\b/$1$2$e->{new}/;
                }
                elsif ($e->{method}) {                                    # $recv->NAME: col is the receiver; the name follows ->
                    pos($lines[$i]) = $e->{col} // 0;
                    # non-greedy: the FIRST ->NAME at/after the receiver col is the call on
                    # THIS receiver. Greedy would jump to a later same-named call on the line
                    # (e.g. a sibling frontier `$other->NAME`) and edit the wrong one.
                    if ($lines[$i] =~ /\G.*?->\s*\K\Q$e->{old}\E\b/) {
                        substr($lines[$i], $-[0], length $e->{old}) = $e->{new};
                        $count++;
                    }
                }
                elsif (defined $e->{col} && substr($lines[$i], $e->{col}, length $e->{old}) eq $e->{old}) {
                    substr($lines[$i], $e->{col}, length $e->{old}) = $e->{new};
                    $count++;
                }
            }
        }
        $disk->spew_raw(join '', @lines);
    }
    return $count;
}

# Graph-driven MOVE of a function to another package: requalify every resolved call
# site (Foo::bar / bareword bar -> NewPkg::bar) and relocate the sub's source from its
# origin file into the target package's file. Dynamic dispatch and stale `use` imports
# are reported, not edited. Dry-run unless apply.
sub move ($self, $old, $new_pkg, %opt) {
    my $s = $self->store;
    my @defs = grep { ($_->{kind} // '') =~ /method|function/ }
               ($old =~ /::/ ? $s->nodes_by_qname($old) : $s->nodes_by_name($old));
    return { error => "no function/method named '$old'" }                            unless @defs;
    return { error => "'$old' is ambiguous (@{[ scalar @defs ]} defs) -- qualify it" } if @defs > 1;

    my $def     = $defs[0];
    my $old_q   = $def->{qualified_name};
    my $src_pkg = package_of($old_q);
    my $short   = $old_q =~ s/.*:://r;
    return { error => "give a target PACKAGE (e.g. Other::Pkg), not '$new_pkg'" } unless $new_pkg =~ /\A\w+(?:::\w+)*\z/;
    return { error => "'$old' is already in $new_pkg" } if $new_pkg eq $src_pkg;
    my $new_q = "${new_pkg}::${short}";
    return { error => "$new_q already exists" }
        if grep { ($_->{kind} // '') =~ /method|function/ } $s->nodes_by_qname($new_q);
    my ($tpkg) = grep { ($_->{kind} // '') =~ /package|class/ } $s->nodes_by_qname($new_pkg);
    return { error => "target package '$new_pkg' is not defined in this project" } unless $tpkg && $tpkg->{file_path};

    my $resolver = App::PerlGraph::Resolver->new(store => $s);
    my %files = ($def->{file_path} => 1, $tpkg->{file_path} => 1);
    for my $e ($s->incoming_edges($def->{id}, 'calls', 'references')) {
        my $n = $s->node($e->{source});
        $files{ $n->{file_path} } = 1 if $n && defined $n->{file_path};
    }
    $files{ $_->{file_path} } = 1
        for $s->_rows('select distinct file_path from unresolved_refs where reference_name = ?', $short);

    my (@edits, @frontier);
    for my $file (sort keys %files) {
        my $disk = path($self->root)->child($file);
        next unless $disk->is_file;
        my $fsrc = $disk->slurp_raw;
        my $out  = eval { App::PerlGraph::Extractor->new(file_path => $file, source => $fsrc)
                              ->extract($self->parser->parse_string($fsrc)) } or next;
        for my $r (@{ $out->{refs} }) {
            my $nm = $r->{reference_name};
            next unless $nm eq $short || $nm eq $old_q;
            my $is_method = ($r->{reference_kind} // '') eq 'method_call';
            my $tn = $is_method ? ($resolver->_resolve_method($r))[0] : $resolver->_resolve_call($r);
            if ($tn && $tn->{id} eq $def->{id}) {                # requalify the whole call token -> NewPkg::bar
                push @edits, { file => $file, line => $r->{line}, col => $r->{col}, old => $nm, new => $new_q };
            }
            elsif ($is_method && $nm eq $short) {                # opaque dispatch -> manual review
                push @frontier, { file => $file, line => $r->{line}, col => $r->{col},
                                  receiver => ($r->{candidates} // {})->{receiver} };
            }
        }
    }

    my $applied = 0;
    if ($opt{apply}) {
        $applied  = $self->_apply(\@edits);                      # requalify call sites (positional)
        $applied += $self->_relocate($def->{file_path}, $tpkg->{file_path}, "${src_pkg}::${short}", $new_pkg);
    }
    return { old => $old_q, new => $new_q, edits => \@edits, frontier => \@frontier,
             relocation => "$def->{file_path} -> $tpkg->{file_path}",
             files => [ sort keys %files ], applied => $applied };
}

# Cut the sub `$qn` out of $from_file and splice its lines in after the `package
# $to_pkg` declaration in $to_file (same-file move handled in one pass). Re-extracts
# $from_file for the sub's CURRENT line span, so a column-only call-site edit (which
# doesn't shift lines) earlier in the same run stays valid.
sub _relocate ($self, $from_file, $to_file, $qn, $to_pkg) {
    my $from = path($self->root)->child($from_file);
    return 0 unless $from->is_file;
    my $fsrc = $from->slurp_raw;
    my $out  = eval { App::PerlGraph::Extractor->new(file_path => $from_file, source => $fsrc)
                          ->extract($self->parser->parse_string($fsrc)) } or return 0;
    my ($sub) = grep { ($_->{qualified_name} // '') eq $qn } @{ $out->{nodes} };
    return 0 unless $sub && $sub->{start_line} && $sub->{end_line};
    my @flines = split /(?<=\n)/, $fsrc;
    my @block  = splice @flines, $sub->{start_line} - 1, $sub->{end_line} - $sub->{start_line} + 1;
    return 0 unless @block;
    if ($from_file eq $to_file) {                                # same file: insert after the (now-shifted) package line
        my $at = _pkg_line(\@flines, $to_pkg);
        splice @flines, $at, 0, "\n", @block;
        $from->spew_raw(join '', @flines);
    }
    else {
        $from->spew_raw(join '', @flines);                       # write the origin (sub removed)
        my $to = path($self->root)->child($to_file);
        return 0 unless $to->is_file;
        my @tlines = split /(?<=\n)/, $to->slurp_raw;
        splice @tlines, _pkg_line(\@tlines, $to_pkg), 0, "\n", @block;
        $to->spew_raw(join '', @tlines);
    }
    return 1;
}
# The line index (0-based) just AFTER `package $pkg`'s declaration, or end-of-file.
sub _pkg_line ($lines, $pkg) {
    for my $i (0 .. $#$lines) { return $i + 1 if $lines->[$i] =~ /^\s*package\s+\Q$pkg\E\b/ }
    return scalar @$lines;
}

1;

__END__

=head1 NAME

App::PerlGraph::Refactor - graph-driven rename / move codemods

=head1 DESCRIPTION

Renames a function/method within its own package, or MOVES a function to another
existing package (relocating its source and requalifying call sites to NewPkg::sub),
using the resolved call graph to locate every reference precisely and the resolver to
decide which call sites actually target it. Dynamic C<$obj-E<gt>method> dispatch that
cannot be tied to the symbol is reported, not edited. Internal to L<App::PerlGraph>; driven
by C<pcg rename> / C<pcg move> and the C<pcg_rename> / C<pcg_move> MCP tools.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
