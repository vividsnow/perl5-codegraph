package App::PerlGraph::Format;
use v5.36;
our $VERSION = q{0.002};
use App::PerlGraph::Source;
use App::PerlGraph::Model qw(package_of);
use Cpanel::JSON::XS ();

# Render query results as markdown/text for humans and agents.

sub _loc ($n) { sprintf '%s:%s', $n->{file_path} // '?', $n->{start_line} // '?' }

sub list ($title, $nodes) {
    my $out = "## $title\n\n";
    $out .= @$nodes
        ? join('', map {
              my $tag = ($_->{_provenance} && $_->{_provenance} ne 'static') ? " [$_->{_provenance}]" : '';
              sprintf "- `%s` (%s) -- %s%s\n", $_->{qualified_name} // $_->{name}, $_->{kind}, _loc($_), $tag
          } @$nodes)
        : "_none_\n";
    return $out;
}

# Source-bearing renderers: a node's code + its immediate callers/callees.
sub _names ($label, $nodes) {
    return '' unless @$nodes;
    return "- $label: " . join(', ', map { '`' . ($_->{qualified_name} // $_->{name}) . '`' } @$nodes) . "\n";
}
sub _view ($v, $base) {
    my $n = $v->{node};
    my $out = sprintf "### `%s` (%s) -- %s\n", $n->{qualified_name} // $n->{name}, $n->{kind}, _loc($n);
    if (my $doc = $n->{docstring}) {
        (my $first = (split /\n\s*\n/, $doc)[0]) =~ s/\s+/ /g;
        $first =~ s/^\s+|\s+$//g;
        $out .= "_${first}_\n" if length $first;
    }
    if (defined(my $src = App::PerlGraph::Source::for_node($n, $base))) {
        my $longest = 0;
        while ($src =~ /(`+)/g) { $longest = length($1) if length($1) > $longest }
        my $fence = '`' x ($longest >= 3 ? $longest + 1 : 3);   # outlast any backticks in the source
        $src .= "\n" unless $src =~ /\n\z/;
        $out .= "${fence}perl\n$src${fence}\n";
    }
    $out .= _names('callers', $v->{callers});
    $out .= _names('callees', $v->{callees});
    return $out;
}
sub node_view ($symbol, $views, $base = '') {
    return "## $symbol\n\n_not found_\n" unless @$views;
    return "## $symbol\n\n" . join("\n", map { _view($_, $base) } @$views);
}
sub explore ($query, $views, $base = '') {
    return "## Explore: $query\n\n_no matches_\n" unless @$views;
    return "## Explore: $query\n\n" . join("\n", map { _view($_, $base) } @$views);
}

sub unused ($nodes) {
    my $out = "## Unreferenced symbols (no static callers)\n\n";
    return $out . "_none_\n" unless @$nodes;
    $out .= join '', map {
        sprintf "- `%s` (%s) -- %s\n", $_->{qualified_name} // $_->{name}, $_->{kind}, _loc($_)
    } @$nodes;
    my %pkg; $pkg{ package_of($_->{qualified_name} // $_->{name} // '') } = 1 for @$nodes;
    $out .= sprintf "\n%d package(s), %d sub(s) unreferenced\n", scalar(keys %pkg), scalar @$nodes;
    $out .= "(note: dynamic/string dispatch and cross-distribution callers not counted -- run `pcg index --runtime` to narrow)\n";
    return $out;
}

sub path ($from, $to, $nodes) {
    my $out = "## Path: $from -> $to\n\n";
    return $out . "_no path found_\n"
        . "(no statically-resolved call chain; \$obj->method dispatch is invisible to static analysis -- try `pcg index --runtime`)\n"
        unless @$nodes;
    for my $i (0 .. $#$nodes) {
        my $n = $nodes->[$i];
        my $via = ($i > 0 && $n->{_via} && $n->{_via} ne 'calls') ? " [$n->{_via}]" : '';
        $out .= sprintf "  %s`%s` (%s) -- %s%s\n",
            ($i ? '-> ' : ''), $n->{qualified_name} // $n->{name}, $n->{kind}, _loc($n), $via;
    }
    my $hops = @$nodes - 1;
    $out .= sprintf "\n(%d hop%s)\n", $hops, ($hops == 1 ? '' : 's');
    return $out;
}

# --- graph export (dot / mermaid / json) ---
sub export ($graph, $format = 'mermaid') {
    return _export_dot($graph)  if ($format // '') eq 'dot';
    return _export_json($graph) if ($format // '') eq 'json';
    return _export_mermaid($graph);
}

sub _nlabel ($n) { $n->{qualified_name} // $n->{name} // '?' }
sub _sorted ($nodes) { sort { _nlabel($a) cmp _nlabel($b) } @$nodes }
# mermaid has no backslash escape inside ["..."]; neutralize the two delimiters
# that would break it (route/framework node names can carry arbitrary path text).
sub _mlabel ($s) { ($s =~ s/"/&quot;/gr) =~ s/\]/&#93;/gr }

# stable, unique, identifier-safe ids keyed on node id (for mermaid)
sub _graph_ids ($nodes) {
    my (%id, %used, $i);
    for my $n (@$nodes) {
        (my $base = _nlabel($n)) =~ s/[^A-Za-z0-9]+/_/g;
        $base = 'n' unless length $base;
        my $uid = $base;
        $uid = $base . '_' . (++$i) while $used{$uid};
        $used{$uid} = 1;
        $id{ $n->{id} } = $uid;
    }
    return \%id;
}

sub _export_mermaid ($g) {
    my $ids = _graph_ids($g->{nodes});
    my $out = "graph TD\n";
    $out .= sprintf qq{  %s["%s"]\n}, $ids->{$_->{id}}, _mlabel(_nlabel($_)) for _sorted($g->{nodes});
    for my $e (@{ $g->{edges} }) {
        my ($f, $t) = ($ids->{ $e->{from} }, $ids->{ $e->{to} });
        next unless defined $f && defined $t;
        my $label = ($e->{kind} // 'calls') ne 'calls' ? "|$e->{kind}|" : '';
        $out .= sprintf "  %s -->%s %s\n", $f, $label, $t;
    }
    return $out;
}

sub _export_dot ($g) {
    my %name = map { ($_->{id} => _nlabel($_)) } @{ $g->{nodes} };
    my %style = (references => ' [style=dashed]', extends => ' [style=bold,color=blue]');
    my $esc = sub ($s) { (my $x = $s) =~ s/(["\\])/\\$1/g; $x };
    my $out = "digraph pcg {\n  rankdir=LR;\n  node [shape=box];\n";
    $out .= sprintf qq{  "%s";\n}, $esc->($name{ $_->{id} }) for _sorted($g->{nodes});
    for my $e (@{ $g->{edges} }) {
        next unless defined $name{ $e->{from} } && defined $name{ $e->{to} };
        $out .= sprintf qq{  "%s" -> "%s"%s;\n},
            $esc->($name{ $e->{from} }), $esc->($name{ $e->{to} }), ($style{ $e->{kind} // '' } // '');
    }
    return $out . "}\n";
}

sub _export_json ($g) {
    my %name = map { ($_->{id} => _nlabel($_)) } @{ $g->{nodes} };
    my $data = {
        nodes => [ map { +{ id => _nlabel($_), kind => $_->{kind}, file => $_->{file_path}, line => $_->{start_line} } }
                   _sorted($g->{nodes}) ],
        edges => [ map  { +{ from => $name{ $_->{from} }, to => $name{ $_->{to} }, kind => $_->{kind} } }
                   grep { defined $name{ $_->{from} } && defined $name{ $_->{to} } } @{ $g->{edges} } ],
    };
    return Cpanel::JSON::XS->new->canonical->pretty->encode($data);
}

sub callers ($symbol, $nodes) { list("Callers of $symbol", $nodes) }
sub callees ($symbol, $nodes) { list("Callees of $symbol", $nodes) }
sub impact  ($symbol, $nodes) { list("Impact of $symbol",  $nodes) }
sub search  ($query,  $nodes) { list("Search: $query",     $nodes) }

sub affected ($files, $paths) {
    my $out = '## Affected by ' . join(', ', @$files) . "\n\n";
    $out .= @$paths ? join('', map { "- `$_`\n" } @$paths) : "_none_\n";
    return $out;
}

1;

__END__

=head1 NAME

App::PerlGraph::Format - render query results as markdown / text

=head1 DESCRIPTION

Formats node, caller/callee, path, unused and export results for humans and agents.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
