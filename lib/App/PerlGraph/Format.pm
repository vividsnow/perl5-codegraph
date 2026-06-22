package App::PerlGraph::Format;
use v5.36;
our $VERSION = q{0.029};
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
    my $cx = ($n->{metadata} // {})->{complexity};
    my $out = sprintf "### `%s` (%s) -- %s%s\n", $n->{qualified_name} // $n->{name}, $n->{kind}, _loc($n),
        ($cx ? " -- complexity $cx" : '');
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

# count of breaking entries (removed or re-signatured public symbols) in a diff
sub _breaking_count ($d) { scalar grep { $_->{_breaking} } @{ $d->{removed} }, @{ $d->{changed} } }

sub review ($r) {
    my $d = $r->{diff};
    my $break = _breaking_count($d);
    my $out = "## Review: $r->{ref} -> working tree\n\n";
    $out .= sprintf "%d file(s) changed -- %d added, %d removed, %d signature change(s)%s\n\n",
        scalar @{ $r->{files} }, scalar @{ $d->{added} }, scalar @{ $d->{removed} }, scalar @{ $d->{changed} },
        ($break ? "; **$break breaking**" : '');
    if ($break) {
        $out .= "### Breaking changes (removed / re-signatured public API)\n\n";
        for my $s (grep { $_->{_breaking} } @{ $d->{removed} }) {
            $out .= sprintf "- removed `%s` (%s)%s\n", $s->{qualified_name}, $s->{kind},
                ($s->{_callers} ? " -- $s->{_callers} caller(s) still reference it" : '');
        }
        for my $s (grep { $_->{_breaking} } @{ $d->{changed} }) {
            $out .= sprintf "- `%s` (%s) `%s` -> `%s`%s\n", $s->{new}{qualified_name}, $s->{new}{kind},
                $s->{old}{signature} // '', $s->{new}{signature} // '',
                ($s->{new}{_callers} ? " -- $s->{new}{_callers} caller(s)" : '');
        }
        $out .= "\n";
    }
    $out .= sprintf "### Blast radius\n\n%d file(s) affected by these changes.\n\n", scalar @{ $r->{affected} };
    $out .= @{ $r->{tests} }
        ? "### Tests to run (" . scalar(@{ $r->{tests} }) . ")\n\n" . join('', map { "- `$_`\n" } @{ $r->{tests} }) . "\n"
        : "### Tests to run\n\n_none statically reach the changed files_\n\n";
    return $out . diff($d, $r->{ref});   # the full structural diff
}

sub diff ($d, $ref) {
    my $total = @{ $d->{added} } + @{ $d->{removed} } + @{ $d->{changed} };
    my $out = "## Diff vs $ref\n\n";
    return $out . "_no structural changes_\n" unless $total;
    my $break = _breaking_count($d);
    $out .= "**$break breaking change(s)** -- removed or re-signatured public API\n\n" if $break;
    if (@{ $d->{removed} }) {
        $out .= "### Removed\n\n" . join('', map {
            sprintf "- `%s` (%s)%s\n", $_->{qualified_name}, $_->{kind}, ($_->{_breaking} ? '  **[breaking]**' : '')
        } @{ $d->{removed} }) . "\n";
    }
    if (@{ $d->{added} }) {
        $out .= "### Added\n\n" . join('', map {
            sprintf "+ `%s` (%s)\n", $_->{qualified_name}, $_->{kind}
        } @{ $d->{added} }) . "\n";
    }
    if (@{ $d->{changed} }) {
        $out .= "### Signature changed\n\n" . join('', map {
            sprintf "~ `%s` (%s) -- `%s` -> `%s`%s\n", $_->{new}{qualified_name}, $_->{new}{kind},
                $_->{old}{signature} // '', $_->{new}{signature} // '', ($_->{_breaking} ? '  **[breaking]**' : '')
        } @{ $d->{changed} });
    }
    return $out;
}

sub cochange ($rows) {
    my $out = "## Co-change coupling (files that change together)\n\n";
    return $out . "_none_\n" unless @$rows;
    $out .= join '', map {
        sprintf "- `%s` <-> `%s` -- %d commits, coupling %.0f%%%s\n",
            $_->{a}, $_->{b}, $_->{support}, $_->{coupling} * 100,
            ($_->{linked} ? '' : '  [no static link]')
    } @$rows;
    $out .= "(coupling = Jaccard of the commit sets; `[no static link]` = hidden coupling the call graph can't see)\n";
    return $out;
}

sub risk ($rows) {
    my $out = "## Risk (churn x fan-in)\n\n";
    return $out . "_none_\n" unless @$rows;
    $out .= join '', map {
        my $cx = ($_->{node}{metadata} // {})->{complexity};
        sprintf "- `%s` (%s) -- churned %d, %d caller%s%s -- score %d -- %s\n",
            $_->{node}{qualified_name} // $_->{node}{name}, $_->{node}{kind},
            $_->{churn}, $_->{fan_in}, ($_->{fan_in} == 1 ? '' : 's'),
            ($cx ? ", cx $cx" : ''), $_->{score}, _loc($_->{node})
    } @$rows;
    $out .= "(churn = commits touching the file; frequently-changed + widely-depended-upon = top risk)\n";
    return $out;
}

sub untested ($nodes) {
    my $out = "## Untested public API (no test statically reaches these)\n\n";
    return $out . "_none_\n" unless @$nodes;
    $out .= join '', map { sprintf "- `%s` (%s) -- %s\n",
        $_->{qualified_name} // $_->{name}, $_->{kind}, _loc($_) } @$nodes;
    $out .= sprintf "\n%d untested public symbol(s)\n", scalar @$nodes;
    $out .= "(note: dynamic \$obj->method dispatch from tests isn't a static edge -- run `pcg index --runtime` to narrow)\n";
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

sub deps ($modules) {
    my $out = "## Module dependencies\n\n";
    my @with = grep { %{ $_->{deps} } } @$modules;
    return $out . "_none_\n" unless @with;
    for my $m (@with) {
        $out .= "### `$m->{module}`\n";
        $out .= sprintf "- %s `%s`\n", $m->{deps}{$_}, $_ for sort keys %{ $m->{deps} };
        $out .= "\n";
    }
    return $out;
}

sub cycles ($cycles) {
    my $out = "## Circular module dependencies\n\n";
    return $out . "_none found_\n" unless @$cycles;
    $out .= '- ' . join(' -> ', map { "`$_`" } @$_, $_->[0]) . "\n" for @$cycles;
    return $out;
}

sub hotspots ($h) {
    my $out = "## Hotspots\n\n### Most depended-upon (fan-in)\n\n";
    $out .= @{ $h->{fan_in} }
        ? join('', map {
              # show the transitive blast radius only when it exceeds the direct count
              my $imp = (defined $_->{impact} && $_->{impact} > $_->{count}) ? ", $_->{impact} transitive" : '';
              my $cx  = ($_->{node}{metadata} // {})->{complexity};   # complex AND widely-used = top risk
              sprintf "- `%s` (%s) -- %d %s%s%s -- %s\n",
                  $_->{node}{qualified_name} // $_->{node}{name}, $_->{node}{kind},
                  $_->{count}, ($_->{count} == 1 ? 'caller' : 'callers'), $imp, ($cx ? ", cx $cx" : ''), _loc($_->{node})
          } @{ $h->{fan_in} })
        : "_none_\n";
    $out .= "\n### Most calls made (fan-out)\n\n";
    $out .= @{ $h->{fan_out} }
        ? join('', map { sprintf "- `%s` (%s) -- calls %d -- %s\n",
              $_->{node}{qualified_name} // $_->{node}{name}, $_->{node}{kind},
              $_->{count}, _loc($_->{node}) } @{ $h->{fan_out} })
        : "_none_\n";
    $out .= "\n### Most complex (cyclomatic)\n\n";
    $out .= @{ $h->{complex} // [] }
        ? join('', map { sprintf "- `%s` (%s) -- complexity %d -- %s\n",
              $_->{node}{qualified_name} // $_->{node}{name}, $_->{node}{kind}, $_->{cx}, _loc($_->{node}) } @{ $h->{complex} })
        : "_none_\n";
    $out .= "\n### Most coupled modules (efferent)\n\n";
    $out .= @{ $h->{packages} // [] }
        ? join('', map { sprintf "- `%s` -- depends on %d module%s\n",
              $_->{module}, $_->{count}, ($_->{count} == 1 ? '' : 's') } @{ $h->{packages} })
        : "_none_\n";
    return $out;
}

sub api ($module, $nodes) {
    my $out = "## API of $module\n\n";
    return $out . "_none_\n" unless @$nodes;
    $out .= join '', map {
        sprintf "- `%s` (%s) -- %s%s\n", $_->{qualified_name} // $_->{name}, $_->{kind}, _loc($_),
            ($_->{is_exported} ? ' [exported]' : '')
    } sort { ($a->{name} // '') cmp ($b->{name} // '') } @$nodes;
    return $out;
}

sub covers ($symbol, $paths) {
    my $out = "## Tests covering $symbol\n\n";
    $out .= @$paths ? join('', map { "- `$_`\n" } @$paths) : "_none_\n";
    return $out;
}

# The agent-resolvable unresolved method calls: each opaque `$recv->method` call
# with the real candidate definitions to disambiguate between.
sub unresolved ($groups) {
    my $out = "## Unresolved method calls with candidates\n\n";
    return $out . "_none_ (nothing left that maps to a known method)\n" unless @$groups;
    for my $g (@$groups) {
        $out .= sprintf "- `%s->%s` in `%s` (%s:%s%s)\n", $g->{receiver}, $g->{method}, $g->{caller},
            $g->{file} // '?', $g->{line} // '?', (($g->{count} // 1) > 1 ? ", x$g->{count}" : '');
        $out .= "  candidates: " . join(', ',
            map { sprintf "`%s` (%s:%s)", $_->{qname}, $_->{file} // '?', $_->{line} // '?' } @{ $g->{candidates} }) . "\n";
    }
    $out .= "\nInfer each receiver's class (read the code if needed), then call `pcg_resolve` --\n"
          . "prefer { caller, receiver, class } (types the receiver once, resolves all its calls at that site),\n"
          . "or { caller, method, receiver, target } for a single call (target = one of the candidates).\n";
    return $out;
}

sub resolve_targets ($targets) {
    my $out = "## Resolve hints -- opaque receivers grouped by their method set\n\n";
    return $out . "_none_ (no opaque receiver's method set pins a known class)\n" unless @$targets;
    for my $t (@$targets) {
        my $n = @{ $t->{classes} };
        my $hint = $n == 1 ? "type as `$t->{classes}[0]` (the only class defining all these methods)"
                 : $n <= 4 ? "one of: " . join(', ', map { "`$_`" } @{ $t->{classes} })
                 :           "$n candidate classes (narrow by reading the code)";
        $out .= sprintf "- `%s` in `%s` -- %d call(s) on: %s\n      -> %s\n",
            $t->{receiver}, $t->{caller}, $t->{calls}, join(' ', map { "$_()" } @{ $t->{methods} }), $hint;
    }
    $out .= "\nResolve a confident one with pcg_resolve { caller, receiver, class }: it types the\n"
          . "receiver and resolves every call on it at once. Confirm against the source if unsure.\n";
    return $out;
}

sub resolved ($res) {
    my $out = sprintf "## Resolution: applied %d, rejected %d\n\n", scalar @{ $res->{applied} }, scalar @{ $res->{rejected} };
    for my $a (@{ $res->{applied} }) {
        # receiver-type form { caller, receiver, class, edges } vs explicit { caller, receiver, method, target, edges }
        $out .= defined $a->{class}
            ? sprintf("- `%s` `%s` is `%s` -- %d call(s) resolved, llm\n", @{$a}{qw(caller receiver class edges)})
            : sprintf("- `%s` `%s->%s` -> `%s` (%d edge(s), llm)\n", @{$a}{qw(caller receiver method target edges)});
    }
    $out .= sprintf "- rejected `%s`: %s\n", $_->{target} // $_->{class} // '?', $_->{reason} for @{ $res->{rejected} };
    return $out;
}

1;

__END__

=head1 NAME

App::PerlGraph::Format - render query results as markdown / text

=head1 DESCRIPTION

Formats every query result for humans and agents: node/explore source views,
caller/callee/impact/search lists, path, affected, unused, deps, cycles, api,
covers, the unresolved surface and the resolve result, and graph export
(dot/mermaid/json).

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
