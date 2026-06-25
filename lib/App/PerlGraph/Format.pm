package App::PerlGraph::Format;
use v5.36;
our $VERSION = q{0.065};
use App::PerlGraph::Source;
use App::PerlGraph::Model qw(package_of is_public);
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
# A fenced perl code block whose fence outlasts any backtick run in the source.
sub _fenced ($src) {
    my $longest = 0;
    while ($src =~ /(`+)/g) { $longest = length($1) if length($1) > $longest }
    my $fence = '`' x ($longest >= 3 ? $longest + 1 : 3);
    $src .= "\n" unless $src =~ /\n\z/;
    return "${fence}perl\n$src${fence}\n";
}
# A header line + the node's source (for the source-bearing bundles).
sub _src_block ($n, $base, $heading = '###') {
    my $cx = ($n->{metadata} // {})->{complexity};
    my $out = sprintf "%s `%s` (%s) -- %s%s\n", $heading, $n->{qualified_name} // $n->{name}, $n->{kind}, _loc($n),
        ($cx ? " -- complexity $cx" : '');
    if (defined(my $src = App::PerlGraph::Source::for_node($n, $base))) { $out .= _fenced($src) }
    return $out;
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
    if (defined(my $src = App::PerlGraph::Source::for_node($n, $base))) { $out .= _fenced($src) }
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

sub explain ($symbol, $dossiers, $base = '') {
    return "## Explain: $symbol\n\n_not found_\n" unless @$dossiers;
    my $out = "## Explain: $symbol\n\n";
    for my $d (@$dossiers) {
        $out .= _view($d, $base);                                  # def + source + callers + callees
        $out .= sprintf "- blast radius: %d transitive caller(s)\n", $d->{impact};
        $out .= @{ $d->{tests} }
            ? "- covered by: " . join(', ', map { "`$_`" } @{ $d->{tests} }) . "\n"
            : "- covered by: _no test statically reaches it_\n";
        $out .= "\n";
    }
    return $out;
}

# A ready-to-paste working set for an agent: the focus symbol(s) WITH source + their
# immediate caller/callee index + covering tests, then the SOURCE of each project callee
# (what you need to read to change the focus), truncated to a character budget.
sub context ($ctx, $base = '', $budget = 16000) {
    return "## Context: $ctx->{symbol}\n\n_not found_\n" unless @{ $ctx->{focus} };
    my $hint = $ctx->{via} ? " (via $ctx->{via} \"$ctx->{query}\")" : '';
    my $out  = "## Context: $ctx->{symbol}$hint\n\n";
    $out .= _view($_, $base) for @{ $ctx->{focus} };               # focus: source + caller/callee names
    $out .= sprintf "- covered by: %s\n\n",
        (@{ $ctx->{tests} } ? join(', ', map { "`$_`" } @{ $ctx->{tests} }) : '_no test statically reaches it_');
    if (@{ $ctx->{callees} }) {
        $out .= "### Callee definitions (what the focus depends on)\n\n";
        my $shown = 0;
        for my $n (@{ $ctx->{callees} }) {
            my $blk = _src_block($n, $base, '####');
            if ($shown && length($out) + length($blk) > $budget) {  # always show at least one; then stop at the budget
                my @rest = @{ $ctx->{callees} }[$shown .. $#{ $ctx->{callees} }];
                $out .= sprintf "_(+%d more callee definition(s) omitted for budget: %s)_\n",
                    scalar(@rest), join(', ', map { "`" . ($_->{qualified_name} // $_->{name}) . "`" } @rest);
                last;
            }
            $out .= $blk; $shown++;
        }
    }
    return $out;
}

sub semantic ($query, $r) {
    my $out = "## Semantic search: $query\n\n";
    if (my $e = $r->{error} // '') {
        return $out . ($e eq 'no_embeddings'
            ? "_no embeddings yet_ -- run `pcg index --embed` (needs a local provider: set PCG_EMBED_CMD or run Ollama). Use `pcg search` for keyword search meanwhile.\n"
            : "_embedding provider unavailable_ -- set PCG_EMBED_CMD or start a local Ollama to embed the query; use `pcg search` for keyword search meanwhile.\n");
    }
    my $res = $r->{results} // [];
    return $out . "_no matches_\n" unless @$res;
    $out .= join '', map {
        sprintf "- `%s` (%s) -- %s -- score %.2f\n",
            $_->{qualified_name} // $_->{name}, $_->{kind}, _loc($_), $_->{_score} // 0
    } @$res;
    return $out;
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

sub prereqs ($r) {
    return "## Prerequisites\n\n_no declared prereqs found (looked for META.json / MYMETA.json / cpanfile / Makefile.PL)_\n"
        unless $r->{source};
    my $out = "## Prerequisites (declared in $r->{source})\n\n";
    if (@{ $r->{missing} }) {
        $out .= "### Missing -- use'd but NOT declared (add to prereqs)\n\n";
        $out .= "- `$_`\n" for @{ $r->{missing} };
        $out .= "\n";
    }
    if (@{ $r->{unused} }) {
        $out .= "### Possibly unused -- declared but not seen in any use/require\n\n";
        $out .= "- `$_`\n" for @{ $r->{unused} };
        $out .= "(may be loaded dynamically, or used only in build tooling outside the indexed files)\n\n";
    }
    $out .= "_in sync -- every used module is declared and every declared prereq is used_\n"
        unless @{ $r->{missing} } || @{ $r->{unused} };
    $out .= sprintf "\n(%d declared, %d module(s) used; %d core module(s) used need no declaring)\n",
        $r->{declared}, $r->{used}, scalar @{ $r->{core} };
    return $out;
}

sub suggest_reviewers ($reviewers, $ref, $nchanged) {
    my $out = "## Suggested reviewers for the change vs `$ref`\n\n";
    return $out . "_no changed code files (or no git history for them)._\n" unless @$reviewers;
    $out .= "$nchanged changed code file(s); reviewers ranked by how much of that code they authored:\n\n";
    for my $r (@$reviewers) {
        my @f = @{ $r->{files} };
        my $shown = join(', ', map { "`$_`" } @f[0 .. ($#f < 4 ? $#f : 4)]);
        $shown .= sprintf ' (+%d more)', @f - 5 if @f > 5;
        $out .= sprintf "- **%s** -- %d commit(s) across %d of the changed file(s): %s\n",
            $r->{author}, $r->{commits}, scalar @f, $shown;
    }
    $out .= "\n(by git authorship of the touched files -- the change's own author ranks high, so pick the next most familiar.)\n";
    return $out;
}

sub owners ($rows) {
    my $out = "## Code ownership & bus factor\n\n";
    return $out . "_no git history for the indexed files_\n" unless @$rows;
    $out .= "(ranked by how depended-upon the file is; **risk** = one author owns >=80% of a depended-upon file)\n\n";
    for my $r (@$rows) {
        my $risk = ($r->{share} >= 0.8 && $r->{fanin} > 0) ? ' **[bus-factor risk]**' : '';
        $out .= sprintf "- `%s` -- owner **%s** (%.0f%% of %d commit%s, %d author%s) -- %d inbound dep(s)%s\n",
            $r->{file}, $r->{owner}, $r->{share} * 100, $r->{commits}, ($r->{commits} == 1 ? '' : 's'),
            $r->{authors}, ($r->{authors} == 1 ? '' : 's'), $r->{fanin}, $risk;
    }
    return $out;
}

sub duplication ($groups) {
    my $out = "## Duplicate code (structural clones)\n\n";
    return $out . "_none found_ -- no two non-trivial subs share an identical structure.\n" unless @$groups;
    $out .= scalar(@$groups)
        . " clone group(s) -- subs with an identical body structure (same shape; identifiers and literals aside). Each is an extract-a-shared-helper candidate:\n\n";
    my $i = 0;
    for my $g (@$groups) {
        $out .= sprintf "%d. **%d copies**, ~%d AST nodes each:\n", ++$i, $g->{count}, $g->{nodes};
        $out .= sprintf "   - `%s` -- %s\n", $_->{qualified_name} // $_->{name}, _loc($_) for @{ $g->{members} };
    }
    $out .= "\n(type-1 / type-2 clones: identical CST shape with names and literals abstracted away."
          . " Near-duplicates with small edits are not grouped.)\n";
    return $out;
}

sub dead_exports ($nodes) {
    my $out = "## Dead exports (exported but unused in-repo)\n\n";
    return $out . "_none_ -- every exported symbol is called by another package in the repo.\n" unless @$nodes;
    $out .= scalar(@$nodes)
        . " exported symbol(s) that no OTHER in-repo package calls -- candidates to drop from \@EXPORT"
        . " (or kept only for external/downstream consumers, which the graph can't see):\n\n";
    $out .= sprintf "- `%s` (%s) -- %s\n", $_->{qualified_name} // $_->{name}, $_->{kind}, _loc($_) for @$nodes;
    $out .= "\n(verify a symbol isn't part of your public CPAN API before removing it from the export list.)\n";
    return $out;
}

sub tidy ($r) {
    my ($rm, $ret, $cl) = ($r->{removable}, $r->{retractable}, $r->{clones});
    my $total = @$rm + @$ret + @$cl;
    my $out = "## Tidy -- cleanup opportunities\n\n";
    return $out . "_nothing to tidy_ -- no removable dead code, retractable exports, or structural clones.\n"
        unless $total;
    $out .= "$total cleanup opportunit" . ($total == 1 ? 'y' : 'ies')
          . ", each paired with the command that fixes it (a survey -- nothing is changed):\n\n";
    if (@$rm) {
        $out .= '### Removable dead code (' . scalar(@$rm) . ") -- `pcg rm <name>`\n\n";
        $out .= "Unreferenced, non-exported subs; `pcg rm` deletes each (cascading to the private helpers it solely used):\n\n";
        $out .= sprintf "- `%s` (%s) -- %s\n", $_->{qualified_name} // $_->{name}, $_->{kind}, _loc($_) for @$rm;
        $out .= "\n";
    }
    if (@$ret) {
        $out .= '### Retractable exports (' . scalar(@$ret) . ") -- drop from \@EXPORT, then `pcg rm`\n\n";
        $out .= "Exported, but no OTHER in-repo package uses them (verify no external consumer first):\n\n";
        $out .= sprintf "- `%s` (%s) -- %s\n", $_->{qualified_name} // $_->{name}, $_->{kind}, _loc($_) for @$ret;
        $out .= "\n";
    }
    if (@$cl) {
        $out .= '### Clone groups (' . scalar(@$cl) . ") -- `pcg dedupe <name>`\n\n";
        $out .= "Subs sharing an identical body structure; `pcg dedupe` collapses the exact (type-1) ones to a single canonical:\n\n";
        my $i = 0;
        for my $g (@$cl) {
            $out .= sprintf "%d. **%d copies**, ~%d AST nodes each -- e.g. `pcg dedupe %s`:\n",
                ++$i, $g->{count}, $g->{nodes}, $g->{members}[0]{qualified_name} // $g->{members}[0]{name};
            $out .= sprintf "   - `%s`\n", $_->{qualified_name} // $_->{name} for @{ $g->{members} };
        }
        $out .= "\n";
    }
    $out .= "(dead-code and clone detection don't see dynamic dispatch or downstream consumers -- review each before applying.)\n";
    return $out;
}

sub smells ($r) {
    my ($fe, $gc, $lp) = ($r->{feature_envy}, $r->{god_class}, $r->{long_params});
    my $t = $r->{thresholds} // {};
    my $bar = sprintf 'thresholds: feature-envy >= %d foreign calls, god-class >= %d methods & >= %d external callers, long-param >= %d params',
        $t->{fe_min} // 4, $t->{gc_methods} // 20, $t->{gc_fanin} // 15, $t->{lp_min} // 5;
    my $out = "## Refactoring smells (structural)\n\n";
    return $out . "_none found_ -- no feature-envy, god-class, or long-parameter-list smells above the\n"
        . "current $bar. (A smaller codebase legitimately has few; the defaults are tuned to avoid flagging\n"
        . "normal small classes.)\n"
        unless @$fe || @$gc || @$lp;
    if (@$gc) {
        $out .= "### God class (" . scalar(@$gc) . ") -- large + widely depended-upon (consider splitting)\n\n";
        $out .= sprintf "- `%s` -- %d methods, %d external caller(s)\n", $_->{class}, $_->{methods}, $_->{fanin} for @$gc;
        $out .= "\n";
    }
    if (@$fe) {
        $out .= "### Feature envy (" . scalar(@$fe) . ") -- a method more interested in another class (consider moving)\n\n";
        $out .= sprintf "- `%s` -- calls %d distinct method(s) of `%s` and none of its own `%s` (move to `%s`?)\n",
            $_->{node}{qualified_name} // $_->{node}{name}, $_->{foreign}, $_->{envied}, $_->{class}, $_->{envied} for @$fe;
        $out .= "\n";
    }
    if (@$lp) {
        $out .= "### Long parameter list (" . scalar(@$lp) . ") -- many parameters (consider a parameter object)\n\n";
        $out .= sprintf "- `%s` -- %d params: %s\n",
            $_->{node}{qualified_name} // $_->{node}{name}, $_->{count}, join(', ', map { "`$_`" } @{ $_->{params} }) for @$lp;
        $out .= "\n";
    }
    $out .= "($bar.\n"
          . "Heuristic, from RESOLVED call edges + signatures: feature-envy can flag a deliberate facade,"
          . " long-param skips old-style my(...)=\@_ subs. Verify before refactoring.)\n";
    return $out;
}

sub _pr_sym ($s) { $s->{new} ? $s->{new}{qualified_name} // $s->{new}{name} : $s->{qualified_name} // $s->{name} }
sub pr ($r) {
    my $c = $r->{counts};
    my $out = sprintf "## PR health: %s (%d/100) vs `%s`\n\n", $r->{verdict}, $r->{score}, $r->{ref};
    return $out . "_no structural changes vs `$r->{ref}`_ -- nothing to gate.\n" unless $r->{nfiles};
    my $total = $c->{breaking} + $c->{broken} + $c->{arity} + $c->{untested} + $c->{wide};
    $out .= sprintf "%d changed file(s); %s.\n\n", $r->{nfiles},
        ($total ? "$total concern(s) below (worst-first)" : 'no concerns flagged');
    if (@{ $r->{breaking} }) {
        $out .= "### Breaking changes (" . scalar(@{ $r->{breaking} }) . ") -- removed / re-signatured public API\n\n";
        $out .= sprintf "- `%s` (%s)%s\n", _pr_sym($_), ($_->{new} ? $_->{new}{kind} : $_->{kind}),
            ($_->{new} ? ' -- signature changed' : ' -- removed') for @{ $r->{breaking} };
        $out .= "\n";
    }
    if (@{ $r->{broken} }) {
        $out .= "### Broken calls in changed files (" . scalar(@{ $r->{broken} }) . ") -- likely bugs\n\n";
        $out .= sprintf "- `%s` calls `->%s` on `%s`, which doesn't define it -- %s:%s\n",
            $_->{caller}, $_->{method}, $_->{class}, $_->{file} // '?', $_->{line} // '?' for @{ $r->{broken} };
        $out .= "\n";
    }
    if (@{ $r->{arity} }) {
        $out .= "### Wrong-arity calls in changed files (" . scalar(@{ $r->{arity} }) . ")\n\n";
        $out .= sprintf "- `%s` -- %s:%s\n", $_->{callee} // $_->{name} // '?', $_->{file} // '?', $_->{line} // '?'
            for @{ $r->{arity} };
        $out .= "\n";
    }
    if (@{ $r->{untested} }) {
        $out .= "### Untested public changes (" . scalar(@{ $r->{untested} }) . ") -- no test reaches them\n\n";
        $out .= sprintf "- `%s` (%s)\n", $_->{qualified_name} // $_->{name}, $_->{kind} for @{ $r->{untested} };
        $out .= "\n";
    }
    if (@{ $r->{wide} }) {
        $out .= "### Wide blast radius (" . scalar(@{ $r->{wide} }) . ") -- touched public symbol many still call\n\n";
        $out .= sprintf "- `%s` (%s) -- %d caller(s)\n", $_->{qualified_name} // $_->{name}, $_->{kind}, $_->{_callers} // 0
            for @{ $r->{wide} };
        $out .= "\n";
    }
    if (@{ $r->{tests} }) {
        my @t = @{ $r->{tests} };
        $out .= sprintf "**Run %d affected test(s):** %s\n\n", scalar @t,
            join(', ', map { "`$_`" } @t[0 .. ($#t < 9 ? $#t : 9)]) . ($#t > 9 ? ' ...' : '');
    }
    $out .= "(score: 100 minus 15/breaking, 12/broken-call, 10/wrong-arity, 6/untested, 4/wide-blast."
          . " >=85 PASS, 60-84 REVIEW, <60 BLOCK. Heuristic gate -- not a substitute for human review.)\n";
    return $out;
}

sub metrics ($m) {
    my $out = "## Code health metrics\n\n";
    $out .= sprintf "**Scale** -- %d files, %d packages/classes, %d subs (%d public API); %d nodes, %d edges.\n\n",
        @{$m}{qw(files packages subs public_api nodes edges)};
    $out .= sprintf "**Resolution** -- %.0f%% of call/reference edges statically resolved (%d unresolved \$obj->method / bareword).\n\n",
        $m->{resolved_pct}, $m->{unresolved};
    $out .= "**Quality**\n";
    $out .= sprintf "- test coverage: %.0f%% of public API reached by a test (%d untested)\n",  $m->{tested_pct}, $m->{untested};
    $out .= sprintf "- doc coverage:  %.0f%% of public API carries POD (%d undocumented)\n",      $m->{documented_pct}, $m->{undocumented};
    $out .= sprintf "- complexity:    %d sub(s) at cyclomatic complexity >= 10 (max %d)\n",        $m->{complex}, $m->{max_complexity};
    $out .= sprintf "- dead code:     %d unreferenced sub(s)\n",                                    $m->{unused};
    $out .= sprintf "- duplication:   %d structural clone group(s)\n",                             $m->{clone_groups};
    $out .= sprintf "- cycles:        %d circular module-dependency group(s)\n",                   $m->{cycles};
    my @c;
    push @c, "$m->{cycles} dependency cycle(s)"                              if $m->{cycles};
    push @c, sprintf('%.0f%% of public API untested',     100 - $m->{tested_pct})     if $m->{tested_pct} < 80;
    push @c, sprintf('%.0f%% of public API undocumented', 100 - $m->{documented_pct}) if $m->{documented_pct} < 50;
    push @c, "$m->{complex} high-complexity sub(s)"                          if $m->{complex};
    push @c, "$m->{clone_groups} clone group(s)"                            if $m->{clone_groups};
    push @c, "$m->{unused} dead-code candidate(s)"                          if $m->{unused};
    $out .= "\n" . (@c ? '**Concerns:** ' . join('; ', @c) . ".\n" : "_No major concerns flagged._\n");
    return $out;
}

sub checkcalls ($findings) {
    my $out = "## Broken method calls\n\n";
    return $out . "_none found_ -- every \$obj->method on a known in-repo class hierarchy resolves to a real method.\n"
        unless @$findings;
    $out .= scalar(@$findings)
        . " call(s) to a method the receiver's class (and its full MRO) does not define -- likely a typo or a call into renamed/removed API:\n\n";
    for my $f (@$findings) {
        $out .= sprintf "- `->%s` in `%s` -- %s:%s -- class `%s` and its MRO define no `%s`\n",
            $f->{method}, $f->{caller}, $f->{file} // '?', $f->{line} // '?', $f->{class}, $f->{method};
    }
    $out .= "\n(heuristic: the static graph captures `has`/`field` accessors but not runtime-injected methods or"
          . " `handles` delegation -- `pcg index --runtime` resolves those and sharpens this; verify before removing a call.)\n";
    return $out;
}

sub checkargs ($findings) {
    my $out = "## Wrong-arity calls\n\n";
    return $out . "_none found_ -- every checked call passes a fitting number of arguments.\n" unless @$findings;
    $out .= scalar(@$findings)
        . " call(s) passing the wrong number of arguments to a sub whose signature fixes its arity:\n\n";
    for my $f (@$findings) {
        $out .= sprintf "- `%s%s` -- %s:%s -- expects %s arg(s) in \@_, got %s (from `%s`)\n",
            $f->{callee}, $f->{sig} // '', $f->{file} // '?', $f->{line} // '?', $f->{expected}, $f->{got}, $f->{caller};
    }
    $out .= "\n(checks calls to subs with an explicit signature -- a method call's implicit invocant is counted,"
          . " splat args like \@list are skipped, a `my (...) = \@_` sub has none to check. Heuristic; verify.)\n";
    return $out;
}

sub doccheck ($findings) {
    my $out = "## Stale POD\n\n";
    return $out . "_none found_ -- every `name(...)` / `\$obj->name` POD entry names a method that exists.\n"
        unless @$findings;
    $out .= scalar(@$findings)
        . " POD entr" . (@$findings == 1 ? 'y' : 'ies') . " documenting a method/function that no longer exists"
        . " (removed or renamed -- update the docs):\n\n";
    for my $f (@$findings) {
        $out .= sprintf "- `%s` -- %s:%s -- documented in POD, but no such sub in the package or its \@ISA\n",
            $f->{name}, $f->{file} // '?', $f->{line} // '?';
    }
    $out .= "\n(checks call-shaped POD headings `=head2 name(...)` / `=item \$obj->name`; package + MRO aware, so an"
          . " inherited method documented in a subclass is fine. Heuristic -- verify.)\n";
    return $out;
}

sub scaffold ($r) {
    return "## Scaffold\n\n**error**: $r->{error}\n" if $r->{error};
    my $n     = $r->{node};
    my $qn    = $n->{qualified_name} // $n->{name};
    my $short = $qn =~ s/.*:://r;
    my $pkg   = package_of($qn);
    my @vis   = $r->{is_method} ? @{ $r->{params} }[1 .. $#{ $r->{params} }] : @{ $r->{params} };
    my $sig   = '(' . join(', ', @vis) . ')';
    my $out   = "## Scaffold for `$qn`\n\n";

    $out .= "### POD skeleton (paste above the sub)\n\n```pod\n";
    $out .= "=head2 " . ($r->{is_method} ? "\$obj->$short$sig" : "$short$sig") . "\n\n";
    $out .= "TODO: one-line summary of what $short does.\n\n";
    $out .= "TODO: describe " . (@vis ? 'the parameter(s) (' . join(', ', @vis) . ') and ' : '') . "the return value.\n\n";
    $out .= "=cut\n```\n\n";

    my $args = join ', ', map { (my $x = $_) =~ s/\A[\$\@%]//; "TODO_$x" } @vis;
    $out .= "### Test skeleton\n\n```perl\nuse Test2::V0;\nuse $pkg;\n\n";
    $out .= $r->{is_method}
        ? "my \$obj = $pkg->new(TODO);   # TODO: construct an instance\nis \$obj->$short($args), TODO_expected, '$short: TODO describe the case';\n"
        : "is ${pkg}::$short($args), TODO_expected, '$short: TODO describe the case';\n";
    $out .= "\ndone_testing;\n```\n";

    $out .= "\n(skeletons -- fill the TODOs. " . ($r->{has_pod} ? 'This sub already has POD. ' : 'This sub has no POD. ')
          . "See pcg_untested / pcg_undocumented for what still needs these.)\n";
    return $out;
}

sub layers ($r) {
    my $out = "## Architecture layers (module dependency stratification)\n\n";
    my $L = $r->{layers};
    return $out . "_no modules_\n" unless %$L;
    for my $lvl (sort { $a <=> $b } keys %$L) {
        $out .= sprintf "**Layer %d**%s -- %s\n", $lvl, ($lvl == 0 ? ' (foundational)' : ''),
            join(', ', map { "`$_`" } sort @{ $L->{$lvl} });
    }
    if (@{ $r->{violations} }) {
        $out .= "\n### Layering violations (cyclic dependencies break the layering)\n\n";
        $out .= "- $_\n" for @{ $r->{violations} };
    }
    $out .= "\n(layer 0 depends on nothing internal; higher layers build on lower -- a clean architecture is a DAG)\n";
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
    my $f = $r->{findings} // {};
    if (@{ $f->{wide} // [] } || @{ $f->{untested} // [] }) {
        $out .= "### Findings\n\n";
        $out .= sprintf "- wide blast radius: `%s` has %d caller(s) -- change with care\n",
            $_->{qualified_name}, ($_->{_callers} // 0) for @{ $f->{wide} };
        $out .= sprintf "- untested change: `%s` -- no test statically reaches it; add coverage\n",
            $_->{qualified_name} for @{ $f->{untested} };
        $out .= "\n";
    }
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

# Recommend a semver bump from the structural diff: removed/re-signatured PUBLIC API
# forces MAJOR; otherwise new public API is MINOR; otherwise internal-only is PATCH.
sub semver ($d, $ref) {
    my @breaking  = grep { $_->{_breaking} } @{ $d->{removed} }, @{ $d->{changed} };
    my @added_pub = grep { is_public($_) } @{ $d->{added} };
    my ($level, $why) = @breaking  ? ('MAJOR', 'removed or re-signatured PUBLIC API')
                      : @added_pub ? ('MINOR', 'new public API, no breaking changes')
                      :              ('PATCH', 'no public API change (internal only)');
    my $out = "## Semver recommendation (vs $ref)\n\n**Recommended bump: $level** -- $why.\n\n";
    if (@breaking) {
        $out .= "### Breaking -> MAJOR\n\n";
        $out .= sprintf "- %s `%s` (%s)\n",
            ($_->{new} ? 're-signatured' : 'removed'),
            ($_->{new} ? $_->{new}{qualified_name} : $_->{qualified_name}),
            ($_->{new} ? $_->{new}{kind} : $_->{kind}) for @breaking;
        $out .= "\n";
    }
    if (@added_pub) {
        $out .= "### New public API -> MINOR\n\n";
        $out .= sprintf "+ `%s` (%s)\n", $_->{qualified_name}, $_->{kind} for @added_pub;
        $out .= "\n";
    }
    my $internal = (@{ $d->{added} } - @added_pub) + grep { !$_->{_breaking} } @{ $d->{changed} };
    $out .= sprintf "(%d internal / non-public change(s) -- do not raise the bump level)\n", $internal if $internal;
    return $out;
}

sub changelog ($d, $ref) {
    my @added    = @{ $d->{added} };
    my @removed  = @{ $d->{removed} };
    my @changed  = @{ $d->{changed} };
    my $out = "## Draft changelog (vs $ref)\n\n";
    return $out . "_no structural changes since `$ref`._\n" unless @added || @removed || @changed;
    my @breaking = grep { $_->{_breaking} } @removed, @changed;
    my @add_pub  = grep { is_public($_) } @added;
    $out .= 'Suggested version bump: **' . (@breaking ? 'major' : @add_pub ? 'minor' : 'patch') . "**.\n\n";
    if (@added) {
        $out .= "### Added\n\n";
        $out .= sprintf "- `%s` (%s)%s\n", $_->{qualified_name}, $_->{kind} // '?',
            (is_public($_) ? '' : ' _(internal)_') for @added;
        $out .= "\n";
    }
    if (@removed) {
        $out .= "### Removed\n\n";
        $out .= sprintf "- `%s` (%s)%s\n", $_->{qualified_name}, $_->{kind} // '?',
            ($_->{_breaking} ? ' **(breaking -- was public)**' : '') for @removed;
        $out .= "\n";
    }
    if (@changed) {
        $out .= "### Changed (signature)\n\n";
        $out .= sprintf "- `%s`: `%s` -> `%s`%s\n", $_->{new}{qualified_name},
            $_->{old}{signature} // '()', $_->{new}{signature} // '()',
            ($_->{_breaking} ? ' **(breaking)**' : '') for @changed;
        $out .= "\n";
    }
    $out .= "_Draft from the structural diff -- edit into prose before release._\n";
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

sub undocumented ($nodes) {
    my $out = "## Undocumented public API (no POD)\n\n";
    return $out . "_none -- every public symbol is documented_\n" unless @$nodes;
    $out .= join '', map { sprintf "- `%s` (%s) -- %s\n",
        $_->{qualified_name} // $_->{name}, $_->{kind}, _loc($_) } @$nodes;
    $out .= sprintf "\n%d undocumented public symbol(s)\n", scalar @$nodes;
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
    return _export_html($graph) if ($format // '') eq 'html';
    return _export_mermaid($graph);
}

# A SELF-CONTAINED interactive graph: the nodes/edges are embedded as JSON and laid out
# by a small inline force-directed simulation (no external/CDN dependency). Hover a node
# to highlight its neighbours, drag to reposition, search to locate. For onboarding/docs.
sub _export_html ($g) {
    my @nodes = map { +{ id => $_->{id}, label => _nlabel($_), kind => $_->{kind} // 'function' } } @{ $g->{nodes} };
    my @edges = map  { +{ from => $_->{from}, to => $_->{to}, kind => $_->{kind} // 'calls' } }
                grep { defined $_->{from} && defined $_->{to} } @{ $g->{edges} };
    my $json = Cpanel::JSON::XS->new->canonical->encode({ nodes => \@nodes, edges => \@edges });
    my $html = <<'HTML';
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>pcg graph</title>
<style>
 html,body{margin:0;height:100%;font:13px/1.4 system-ui,sans-serif;background:#0f1115;color:#cdd3de}
 #bar{position:fixed;top:8px;left:8px;z-index:2;background:#1b1f27;padding:6px 8px;border-radius:6px;box-shadow:0 1px 4px #0008}
 #bar input{background:#0f1115;border:1px solid #333;color:#cdd3de;padding:3px 6px;border-radius:4px;width:200px}
 #bar b{color:#8ab4f8} svg{width:100vw;height:100vh;display:block;cursor:grab}
 line{stroke:#39404d;stroke-width:1}
 circle{stroke:#0f1115;stroke-width:1.5;cursor:pointer}
 text{fill:#9aa3b2;font-size:10px;pointer-events:none;opacity:0}
 .lab-on text{opacity:1}
 .dim{opacity:.12} .hot{stroke:#fff;stroke-width:2.5px}
</style></head><body>
<div id="bar"><b>pcg</b> &middot; <span id="n"></span> nodes &middot;
 <input id="q" placeholder="search a symbol..." autocomplete="off"> &middot; hover=neighbours, drag=move</div>
<svg id="svg"><g id="links"></g><g id="nodes"></g></svg>
<script>
const DATA = __DATA__;
const KCOL = {function:'#8ab4f8',method:'#81c995',package:'#fdd663',class:'#fcad70',route:'#f28b82',constant:'#c58af9'};
const svg=document.getElementById('svg'), W=innerWidth, H=innerHeight;
document.getElementById('n').textContent = DATA.nodes.length;
const idx={}; DATA.nodes.forEach((n,i)=>{idx[n.id]=i; n.x=W/2+(Math.cos(i)*1+ (i%37)*7)%W*0+ (i*53%W); n.y=(i*97%H); n.vx=0;n.vy=0; n.deg=0;});
const E=DATA.edges.filter(e=>idx[e.from]!=null&&idx[e.to]!=null);
E.forEach(e=>{DATA.nodes[idx[e.from]].deg++;DATA.nodes[idx[e.to]].deg++;});
const adj={}; DATA.nodes.forEach(n=>adj[n.id]=new Set());
E.forEach(e=>{adj[e.from].add(e.to);adj[e.to].add(e.from);});
const N=DATA.nodes;
for(let it=0;it<280;it++){
  for(let i=0;i<N.length;i++)for(let j=i+1;j<N.length;j++){
    const a=N[i],b=N[j];let dx=a.x-b.x,dy=a.y-b.y;let d2=dx*dx+dy*dy+.01;
    if(d2>90000)continue;let d=Math.sqrt(d2),f=1600/d2;a.vx+=f*dx/d;a.vy+=f*dy/d;b.vx-=f*dx/d;b.vy-=f*dy/d;}
  E.forEach(e=>{const a=N[idx[e.from]],b=N[idx[e.to]];let dx=b.x-a.x,dy=b.y-a.y;let d=Math.sqrt(dx*dx+dy*dy)+.01;
    let f=(d-70)*.012;a.vx+=f*dx/d;a.vy+=f*dy/d;b.vx-=f*dx/d;b.vy-=f*dy/d;});
  N.forEach(n=>{n.vx+=(W/2-n.x)*.002;n.vy+=(H/2-n.y)*.002;n.x+=n.vx*.82;n.y+=n.vy*.82;n.vx*=.82;n.vy*=.82;});
}
const gl=document.getElementById('links'), gn=document.getElementById('nodes');
const lines=E.map(e=>{const l=document.createElementNS('http://www.w3.org/2000/svg','line');gl.appendChild(l);return {l,e};});
const els={};
N.forEach(n=>{const g=document.createElementNS('http://www.w3.org/2000/svg','g');
  const c=document.createElementNS('http://www.w3.org/2000/svg','circle');
  c.setAttribute('r',Math.min(4+n.deg,16));c.setAttribute('fill',KCOL[n.kind]||'#8ab4f8');
  const t=document.createElementNS('http://www.w3.org/2000/svg','text');t.textContent=n.label;
  g.appendChild(c);g.appendChild(t);gn.appendChild(g);els[n.id]={g,c,t};
  c.addEventListener('mouseenter',()=>focus(n.id));c.addEventListener('mouseleave',clear);
  let drag=false;c.addEventListener('mousedown',ev=>{drag=true;ev.preventDefault();});
  addEventListener('mousemove',ev=>{if(drag){n.x=ev.clientX;n.y=ev.clientY;render();}});
  addEventListener('mouseup',()=>drag=false);
});
function render(){N.forEach(n=>{const e=els[n.id];e.c.setAttribute('cx',n.x);e.c.setAttribute('cy',n.y);
  e.t.setAttribute('x',n.x+6);e.t.setAttribute('y',n.y+3);});
  lines.forEach(({l,e})=>{const a=N[idx[e.from]],b=N[idx[e.to]];l.setAttribute('x1',a.x);l.setAttribute('y1',a.y);l.setAttribute('x2',b.x);l.setAttribute('y2',b.y);});}
function focus(id){const keep=adj[id];N.forEach(n=>{const on=n.id===id||keep.has(n.id);els[n.id].g.classList.toggle('dim',!on);els[n.id].g.classList.toggle('lab-on',on);els[n.id].c.classList.toggle('hot',n.id===id);});
  lines.forEach(({l,e})=>l.style.opacity=(e.from===id||e.to===id)?.9:.05);}
function clear(){N.forEach(n=>{els[n.id].g.classList.remove('dim','lab-on');els[n.id].c.classList.remove('hot');});lines.forEach(({l})=>l.style.opacity=1);}
document.getElementById('q').addEventListener('input',ev=>{const v=ev.target.value.toLowerCase();
  if(!v){clear();return;}N.forEach(n=>{const hit=n.label.toLowerCase().includes(v);els[n.id].g.classList.toggle('dim',!hit);els[n.id].g.classList.toggle('lab-on',hit);});});
render();
</script></body></html>
HTML
    my $i = index $html, '__DATA__';
    substr($html, $i, length '__DATA__') = $json if $i >= 0;   # literal inject (no s/// interpretation of JSON)
    return $html;
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

sub inline ($r) {
    return "## Inline\n\n**error**: $r->{error}\n" if $r->{error};
    my $out   = "## Inline `$r->{target}`\n\n";
    my $files = scalar @{ $r->{files} };
    if (!@{ $r->{edits} } && !@{ $r->{frontier} }) {
        return $out . "_no resolved call sites to inline._\n";
    }
    if ($r->{applied}) {
        $out .= sprintf "Inlined **%d** call site(s)%s across %d file(s). Run `pcg sync` to refresh the graph.\n\n",
            scalar @{ $r->{edits} }, ($r->{removed} ? " and removed the definition" : ''), $files;
    }
    else {
        $out .= "Plan (dry run -- add `--apply` / apply:true to write):\n";
        my $fate = $r->{removed}       ? ' and remove the definition'
                 : @{ $r->{frontier} } ? ' (the definition is KEPT -- not every caller can be inlined)'
                 :                       ' (the definition is KEPT -- the function is exported)';
        $out .= '- replace ' . scalar(@{ $r->{edits} }) . " call site(s) with an inlined `do { ... }` block$fate:\n";
        my %byf; push @{ $byf{ $_->{file} } }, $_ for @{ $r->{edits} };
        for my $f (sort keys %byf) {
            $out .= sprintf "    `%s` L%d\n", $f, $_->{line} for sort { $a->{line} <=> $b->{line} } @{ $byf{$f} };
        }
        $out .= "\n";
    }
    if (@{ $r->{frontier} }) {
        $out .= '**Manual review** -- ' . scalar(@{ $r->{frontier} }) . " call site(s) left untouched (the definition is kept):\n";
        $out .= sprintf "- `%s` L%d -- %s\n", $_->{file}, $_->{line}, $_->{why} for @{ $r->{frontier} };
    }
    return $out;
}

sub move ($r) {
    return "## Move\n\n**error**: $r->{error}\n" if $r->{error};
    my $out   = "## Move `$r->{old}` -> `$r->{new}`\n\n";
    my $files = scalar @{ $r->{files} };
    if ($r->{applied}) {
        $out .= "Relocated the definition ($r->{relocation}) and applied **$r->{applied}** edit(s) "
              . "across $files file(s). Run `pcg sync` to refresh the graph.\n\n";
    }
    else {
        $out .= "Plan (dry run -- add `--apply` / apply:true to write):\n";
        $out .= "- relocate the definition: $r->{relocation}\n";
        $out .= "- requalify " . scalar(@{ $r->{edits} }) . " call site(s) to `$r->{new}`:\n";
        my %byf; push @{ $byf{ $_->{file} } }, $_ for @{ $r->{edits} };
        for my $f (sort keys %byf) {
            $out .= sprintf "    `%s` L%d  `%s` -> `%s`\n", $f, $_->{line}, $_->{old}, $_->{new}
                for sort { $a->{line} <=> $b->{line} } @{ $byf{$f} };
        }
        $out .= "\n";
    }
    if (@{ $r->{frontier} }) {
        $out .= "**Manual review** -- " . scalar(@{ $r->{frontier} })
              . " dynamic `\$obj->method` call(s) of the same name + any stale `use` imports of it:\n";
        $out .= sprintf "- `%s` L%d  (receiver `%s`)\n", $_->{file}, $_->{line}, $_->{receiver} // '?'
            for @{ $r->{frontier} };
    }
    return $out;
}

sub rename ($r) {
    return "## Rename\n\n**error**: $r->{error}\n" if $r->{error};
    my $out = "## Rename `$r->{old}` -> `$r->{new}`\n\n";
    my $files = scalar @{ $r->{files} };
    if ($r->{applied}) {
        $out .= "Applied **$r->{applied}** edit(s) across $files file(s). Run `pcg sync` to refresh the graph.\n\n";
    }
    else {
        $out .= scalar(@{ $r->{edits} }) . " edit(s) planned across $files file(s) (dry run -- add `--apply` / apply:true to write):\n";
        my %byf; push @{ $byf{ $_->{file} } }, $_ for @{ $r->{edits} };
        for my $f (sort keys %byf) {
            $out .= "- `$f`\n";
            $out .= sprintf "    L%d  %s`%s` -> `%s`\n", $_->{line}, ($_->{def} ? 'definition ' : ''), $_->{old}, $_->{new}
                for sort { $a->{line} <=> $b->{line} } @{ $byf{$f} };
        }
        $out .= "\n";
    }
    if (@{ $r->{frontier} }) {
        $out .= "**Manual review** -- " . scalar(@{ $r->{frontier} })
              . " dynamic `\$obj->method` call(s) of the same name the resolver could NOT tie to this symbol"
              . " (they may or may not be it):\n";
        $out .= sprintf "- `%s` L%d  (receiver `%s`)\n", $_->{file}, $_->{line}, $_->{receiver} // '?'
            for @{ $r->{frontier} };
    }
    return $out;
}

sub dedupe ($r) {
    return "## Deduplicate\n\n**error**: $r->{error}\n" . _dedupe_skipped($r) if $r->{error};
    my $n = scalar @{ $r->{replaced} };
    my $out = "## Deduplicate clone group -- canonical `$r->{canonical}`\n\n";
    $out .= $r->{applied}
        ? "Rewrote **$r->{applied}** exact-duplicate function(s) to delegate to `$r->{canonical}`. Run `pcg sync` to refresh.\n\n"
        : "Plan (dry run -- add `--apply` / apply:true to write): rewrite $n exact-duplicate function(s) to `{ goto &$r->{canonical} }`:\n\n";
    $out .= sprintf "- `%s` -- %s\n", $_->{name}, $_->{file} for @{ $r->{replaced} };
    $out .= _dedupe_skipped($r);
    $out .= "\n(only EXACT type-1 duplicate functions are merged -- each keeps its name but delegates; verify before apply.)\n";
    return $out;
}
sub _dedupe_skipped ($r) {
    my @s = @{ $r->{skipped} // [] };
    return '' unless @s;
    my $out = "\n_Not rewritten (clone group members that are not exact-duplicate functions -- handle manually):_\n";
    $out .= sprintf "- `%s` -- %s\n", $_->{name}, $_->{why} for @s;
    return $out;
}

sub rm ($r) {
    if ($r->{error}) {
        my $out = "## Remove\n\n**error**: $r->{error}\n";
        $out .= "\nstill referenced by:\n" . join('', map { "- `$_`\n" } @{ $r->{blocked_by} }) if @{ $r->{blocked_by} // [] };
        return $out;
    }
    my $n = scalar @{ $r->{removed} };
    my $out = "## Remove `$r->{target}`\n\n";
    $out .= $r->{applied}
        ? "Removed **$r->{applied}** dead sub(s). Run `pcg sync` to refresh.\n\n"
        : "Plan (dry run -- add `--apply` / apply:true to write): remove $n dead sub(s):\n\n";
    $out .= sprintf "- `%s` -- %s%s\n", $_->{name}, $_->{file} // '?',
        ($_->{cascade} ? ' (now-dead private helper it solely used)' : '') for @{ $r->{removed} };
    $out .= "\n(refuses if the target is still called or exported; cascades only into the now-dead PRIVATE helpers.)\n";
    return $out;
}

sub change_signature ($r) {
    return "## Change signature\n\n**error**: $r->{error}\n" if $r->{error};
    my $verb = $r->{op} eq 'remove' ? "remove parameter \#$r->{position}" : "add parameter at \#$r->{position}";
    my $out  = "## Change signature `$r->{target}` -- $verb\n\n";
    $out .= "`$r->{signature}` -> `$r->{new_signature}`\n\n";
    my $files = scalar @{ $r->{files} };
    my @sites = grep { !$_->{def} } @{ $r->{edits} };
    if ($r->{applied}) {
        $out .= "Applied **$r->{applied}** edit(s) (the definition + "
              . scalar(@sites) . " call site(s)) across $files file(s). Run `pcg sync` to refresh the graph.\n\n";
    }
    else {
        $out .= scalar(@{ $r->{edits} }) . " edit(s) planned across $files file(s) (dry run -- add `--apply` / apply:true to write):\n";
        my %byf; push @{ $byf{ $_->{file} } }, $_ for @{ $r->{edits} };
        for my $f (sort keys %byf) {
            $out .= "- `$f`\n";
            $out .= sprintf "    L%d  %s-> `%s`\n", $_->{line}, ($_->{def} ? 'signature ' : 'call '), $_->{replacement}
                for sort { $a->{line} <=> $b->{line} } @{ $byf{$f} };
        }
        $out .= "\n";
    }
    if (@{ $r->{frontier} }) {
        $out .= "**Manual review** -- " . scalar(@{ $r->{frontier} })
              . " call site(s) the codemod would not touch (a `\$obj->method` dispatch, or an indeterminate"
              . " argument list it can't position-map):\n";
        $out .= sprintf "- `%s` L%d -- %s\n", $_->{file}, $_->{line}, $_->{why} for @{ $r->{frontier} };
    }
    return $out;
}

sub sinks ($r) {
    my $out = "## Security sinks -- command / SQL execution\n\n";
    return $out . "_none found_ (no system/exec or DBI do/execute/select* calls)\n" unless @{ $r->{sites} };
    my $dyn_sites = grep { grep { $_->{dynamic} } @{ $_->{sinks} } } @{ $r->{sites} };
    if (@{ $r->{reachable} }) {
        $out .= "### Reachable from an endpoint (attack surface)\n\n";
        for my $e (@{ $r->{reachable} }) {
            $out .= sprintf "- **%s** -> %s\n", $e->{route}{name},
                join('; ', map { sprintf '%s `%s` in `%s`%s', $_->{type}, $_->{name}, $_->{sub},
                    $_->{dynamic} ? ' **[dynamic -- injection risk]**' : ' [parameterized]' } @{ $e->{sinks} });
        }
        $out .= "\n";
    }
    $out .= "### All sink sites (" . scalar(@{ $r->{sites} }) . ", $dyn_sites with a dynamically-built argument)\n\n";
    for my $site (@{ $r->{sites} }) {
        $out .= sprintf "- `%s` -- %s\n", $site->{sub},
            join(', ', map { "$_->{type}:$_->{name}" . ($_->{dynamic} ? ' **[dynamic]**' : '') } @{ $site->{sinks} });
    }
    $out .= "\n(**[dynamic]** = the command/SQL string is built from a variable (interpolated or concatenated) -- the\n"
          . "injection-shaped sites to VERIFY. Unmarked sinks pass a constant or use placeholders, and are safe.)\n";
    return $out;
}

sub taint ($r) {
    my $out = "## Taint paths -- user input -> injectable sink\n\n";
    return $out . "_no dynamic sinks found_ (no command/SQL site builds its argument from a variable).\n"
        unless $r->{sinks};
    return $out . "_$r->{sinks} dynamic sink(s) found, but no user-input source reaches any of them._"
        . " (sources looked for: web endpoints + request accessors -- param / params / cookie(s) /"
        . " upload(s) / header(s) / query_parameters / body_parameters / route_parameters.)\n"
        unless @{ $r->{paths} };
    $out .= scalar(@{ $r->{paths} }) . " taint path(s) -- a user-input source whose call graph REACHES a"
          . " dynamically-built command/SQL sink ($r->{sources} source(s), $r->{sinks} dynamic sink(s)):\n\n";
    for my $p (@{ $r->{paths} }) {
        my $src = $p->{source}{kind} eq 'endpoint' ? "endpoint `$p->{source}{detail}`"
                                                   : "reads `->$p->{source}{detail}`";
        my $sinks = join(', ', map { "$_->{type}:$_->{name}" } @{ $p->{sinks} });
        $out .= sprintf "- %s%s\n", ($p->{local} ? '**[local]** ' : ''), $src;
        $out .= '    ' . join(' -> ', map { "`$_`" } @{ $p->{path} }) . "\n";
        $out .= "    sink: **$sinks**" . ($p->{local} ? " (read and used in the SAME sub -- highest confidence)\n" : "\n");
    }
    $out .= "\n(call-graph REACHABILITY, not value-flow: it proves input can reach the sink's sub, not that the\n"
          . "tainted value lands in the sink's argument -- VERIFY each. A **[local]** hit is the strongest. \$ENV /\n"
          . "\@ARGV / STDIN sources are not yet detected.)\n";
    return $out;
}

sub overview ($o) {
    my $k = $o->{kinds};
    my $subs = ($k->{function} // 0) + ($k->{method} // 0);
    my $out  = "## Codebase map\n\n";
    $out .= sprintf "**Scale**: %d files, %d packages/classes, %d subs (%d func, %d method), %d edges; %d unresolved\n",
        ($k->{file} // 0), ($k->{package} // 0) + ($k->{class} // 0), $subs,
        ($k->{function} // 0), ($k->{method} // 0), $o->{edges}, $o->{unresolved};
    $out .= "**Edges by provenance**: " . join(', ', map { "$_->[0]=$_->[1]" } @{ $o->{prov} }) . "\n\n"
        if @{ $o->{prov} };
    $out .= "**Web routes**: $o->{routes}\n\n" if $o->{routes};

    if (@{ $o->{scripts} }) {
        my @s = @{ $o->{scripts} }; @s = (@s[0 .. 14], '...') if @s > 15;
        $out .= "**Entry-point scripts**:\n" . join('', map { "- `$_`\n" } @s) . "\n";
    }
    if (@{ $o->{namespaces} }) {
        $out .= "**Top namespaces** (by sub count):\n"
              . join('', map { sprintf "- `%s` -- %d subs\n", $_->{ns}, $_->{subs} } @{ $o->{namespaces} }) . "\n";
    }
    if (@{ $o->{central} }) {
        $out .= "**Most central** (highest fan-in -- change with care):\n"
              . join('', map { sprintf "- `%s` -- %d callers\n", $_->{node}{qualified_name} // $_->{node}{name}, $_->{callers} } @{ $o->{central} }) . "\n";
    }
    if (@{ $o->{inherited} }) {
        $out .= "**Most-subclassed**:\n"
              . join('', map { sprintf "- `%s` -- %d subclass(es)\n", $_->{node}{qualified_name} // $_->{node}{name}, $_->{subclasses} } @{ $o->{inherited} });
    }
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

Renders every L<App::PerlGraph::Query> result as markdown / text for humans and agents:
the source-bearing symbol views (node, explore, explain, context), the relationship and
analysis reports (navigation, architecture, history, security and release queries), the
unresolved surface and resolve result, and graph export (dot / mermaid / json / html).

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
