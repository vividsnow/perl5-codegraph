package App::PerlGraph::Refactor;
use v5.36;
our $VERSION = q{0.072};
use Moo;
use App::PerlGraph::Model qw(package_of);
use App::PerlGraph::Grammar qw(:all);
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

# Graph-driven INLINE of a simple function: replace each RESOLVED call with a `do { ... }`
# block that binds the call's arguments to the sub's params and runs its body, then remove
# the definition. The do-block preserves single-evaluation of args and correct precedence, and
# works for multi-statement bodies. Strictly scoped for safety -- a plain function (not a
# method), params via a leading `my (...) = @_` or a simple all-scalar signature, and a body
# with NO return / wantarray / shift / pop / $_[N] / @_-reuse / caller / goto / local (control
# flow or @_ tricks a do-block can't preserve). Dynamic `$obj->method` and unresolved call
# sites are reported and the definition is kept; dry-run unless apply.
sub inline ($self, $target, %opt) {
    my $s = $self->store;
    my @defs = grep { ($_->{kind} // '') eq 'function' }
               ($target =~ /::/ ? $s->nodes_by_qname($target) : $s->nodes_by_name($target));
    return { error => "no plain function named '$target' (only functions inline; a method needs its invocant)" } unless @defs;
    return { error => "'$target' is ambiguous (@{[ scalar @defs ]} defs) -- qualify it" } if @defs > 1;
    my $def   = $defs[0];
    my $qn    = $def->{qualified_name};
    my $short = $qn =~ s/.*:://r;

    my $disk = path($self->root)->child($def->{file_path});
    return { error => "cannot read $def->{file_path}" } unless $disk->is_file;
    my $dsrc  = $disk->slurp_raw;
    my $dtree = eval { $self->parser->parse_string($dsrc) } or return { error => "could not parse $def->{file_path}" };
    my $subnode = _find_sub($dtree, $short, $def->{start_line}) or return { error => "could not locate sub $short in $def->{file_path}" };
    my ($build, $why) = _inline_template($subnode);
    return { error => "cannot safely inline $qn -- $why" } unless $build;

    my $resolver = App::PerlGraph::Resolver->new(store => $s);
    my %files = ($def->{file_path} => 1);
    for my $e ($s->incoming_edges($def->{id}, 'calls', 'references')) {
        my $n = $s->node($e->{source});
        $files{ $n->{file_path} } = 1 if $n && defined $n->{file_path};
    }
    $files{ $_->{file_path} } = 1
        for $s->_rows('select distinct file_path from unresolved_refs where reference_name = ?', $short);

    my (@edits, @frontier);
    for my $file (sort keys %files) {
        my $fdisk = path($self->root)->child($file);
        next unless $fdisk->is_file;
        my $fsrc  = $fdisk->slurp_raw;
        my $ftree = eval { $self->parser->parse_string($fsrc) } or next;
        my $calls = _calls_by_pos($ftree);                                   # "line:col" -> call node
        my $out   = eval { App::PerlGraph::Extractor->new(file_path => $file, source => $fsrc)->extract($ftree) } or next;
        for my $r (@{ $out->{refs} }) {
            next unless ($r->{reference_name} // '') eq $short || ($r->{reference_name} // '') eq $qn;
            if (($r->{reference_kind} // '') eq 'method_call') {
                push @frontier, { file => $file, line => $r->{line}, why => 'method call (needs an invocant)' };
                next;
            }
            my $tn = $resolver->_resolve_call($r);
            next unless $tn && $tn->{id} eq $def->{id};                      # provably this function
            my $call = $calls->{ "$r->{line}:$r->{col}" };
            if (!$call) { push @frontier, { file => $file, line => $r->{line}, why => 'could not pinpoint the call expression' }; next }
            my $args = ($call->{fields}{ +F_ARGUMENTS } // {})->{text} // '';
            push @edits, { file => $file, line => $r->{line},
                           span => [ @{$call}{qw(sl sc el ec)} ], replacement => $build->($args) };
        }
    }

    # A self-call (recursion) sits INSIDE the definition's own body. Inlining it would lose the
    # recursion AND -- since its replacement rewrites bytes inside the def -- invalidate the
    # def-removal span, corrupting the file. Send such sites to the frontier and keep the def.
    my ($dsl, $del) = @{$subnode}{qw(sl el)};
    my @safe;
    for my $e (@edits) {
        if ($e->{file} eq $def->{file_path} && ($e->{span}[0] // 0) >= $dsl && ($e->{span}[0] // 0) <= $del) {
            push @frontier, { file => $e->{file}, line => $e->{line}, why => 'self-call inside the function (recursive)' };
        }
        else { push @safe, $e }
    }
    @edits = @safe;

    # Remove the def only when EVERY caller was inlined AND it is not exported (an exported
    # function may have out-of-repo consumers the graph can't see -- inline the calls, keep the def).
    my $removable = !@frontier && @edits && !$def->{is_exported};
    my $applied = 0;
    if ($opt{apply}) {
        $applied = $self->_apply_inline(\@edits,
            ($removable ? { file => $def->{file_path}, span => [ @{$subnode}{qw(sl sc el ec)} ] } : undef));
    }
    return { target => $qn, edits => \@edits, frontier => \@frontier, files => [ sort keys %files ],
             removed => ($removable ? 1 : 0), applied => $applied };
}

# The NODE_SUB named $short, anchored to $line (the def's start line from the graph) so a
# multi-package file with two same-named subs picks the RIGHT one -- a bare-name match alone
# would grab whichever the walk reaches first and inline/remove the wrong package's sub. A
# sole name-match is returned regardless of $line; ambiguity with no line hit yields undef.
sub _find_sub ($tree, $short, $line) {
    my @hits;
    my @stack = ($tree);
    while (my $n = pop @stack) {
        push @hits, $n if ($n->{type} // '') eq NODE_SUB && (($n->{fields}{ +F_NAME } // {})->{text} // '') eq $short;
        push @stack, @{ $n->{children} // [] };
    }
    my ($exact) = grep { ($_->{sl} // 0) == $line } @hits;
    return $exact // (@hits == 1 ? $hits[0] : undef);
}

# The fourth WRITE tool: de-duplicate an EXACT structural clone group. Given a target
# function in a `pcg duplication` group, keep it as the canonical copy and rewrite every
# OTHER plain function in the group whose signature+body is byte-identical into a one-line
# delegation `sub name { goto &Canonical }` -- the duplicated logic is removed while each
# name stays callable. Conservative: only EXACT (type-1) duplicate FUNCTIONS are rewritten;
# type-2 clones (renamed vars / changed literals) and methods are reported, not touched.
# Dry-run unless apply => 1.
sub dedupe ($self, $target, %opt) {
    my $s = $self->store;
    my @defs = grep { ($_->{kind} // '') eq 'function' }
               ($target =~ /::/ ? $s->nodes_by_qname($target) : $s->nodes_by_name($target));
    return { error => "no plain function named '$target' (dedupe keeps a function as the canonical copy)" } unless @defs;
    return { error => "'$target' is ambiguous (@{[ scalar @defs ]} defs) -- qualify it" } if @defs > 1;
    my $canon = $defs[0];
    my $fp    = ($canon->{metadata} // {})->{dup}
        or return { error => "'$target' is not part of a structural clone group (see `pcg duplication`)" };
    my $crest = $self->_sub_rest($canon);
    return { error => "could not read '$target'" } unless defined $crest;
    # A sub PROTOTYPE (($$) etc.) or an :attribute (:lvalue) can't be carried into the
    # `goto &Canon` delegation stub -- rewriting would silently drop it (a `($x)` SIGNATURE
    # is fine). The exact clones all share $crest, so this is an all-or-nothing refusal.
    return { error => "'$target' carries a prototype or :attribute the goto-delegation can't preserve -- not safe to dedupe",
             canonical => $canon->{qualified_name}, replaced => [], skipped => [] }
        if $crest =~ /\A\([\$\@\%\&\*\\\[\];+]+\)/ || $crest =~ /\A(?:\([^)]*\)\s*)?:\w/;
    my $canon_pkg = package_of($canon->{qualified_name});

    my (@replaced, @skipped);
    for my $g (grep { $_->{id} ne $canon->{id} && (($_->{metadata} // {})->{dup} // '') eq $fp }
               $s->all_nodes(qw(function method))) {
        my $name = $g->{qualified_name} // $g->{name};
        if (($g->{kind} // '') ne 'function') { push @skipped, { name => $name, why => 'a method (its invocant differs)' }; next }
        my ($rest, $node) = $self->_sub_rest($g, want_node => 1);
        if    (!defined $rest)  { push @skipped, { name => $name, why => 'could not read it' };            next }
        elsif ($rest ne $crest) { push @skipped, { name => $name, why => 'a type-2 clone (text differs)' }; next }
        # `goto &Canon` dies at runtime unless the canonical's package is loadable where the
        # clone lives: same file, same package, or the clone's package use's it.
        my $cpkg = package_of($name);
        unless ($g->{file_path} eq $canon->{file_path} || $cpkg eq $canon_pkg
                || grep { (($_->{metadata} // {})->{module} // '') eq $canon_pkg }
                        map { $s->outgoing_edges($_->{id}, 'imports') } $s->nodes_by_qname($cpkg)) {
            push @skipped, { name => $name, why => "its file does not `use $canon_pkg` -- add it first" };
            next;
        }
        push @replaced, { name => $name, file => $g->{file_path}, span => [ @{$node}{qw(sl sc el ec)} ],
                          replacement => 'sub ' . ($name =~ s/.*:://r) . " { goto &$canon->{qualified_name} }" };
    }
    return { error => "'$target' has no EXACT (type-1) duplicate function to merge -- its clone group is"
                    . " type-2 or methods only (reported below, not rewritten)",
             canonical => $canon->{qualified_name}, replaced => [], skipped => \@skipped } unless @replaced;

    my $applied = $opt{apply}
        ? $self->_apply_inline([ map { +{ file => $_->{file}, span => $_->{span}, replacement => $_->{replacement} } } @replaced ], undef)
        : 0;
    return { canonical => $canon->{qualified_name}, replaced => \@replaced, skipped => \@skipped, applied => $applied };
}

# The (signature + body) text of a sub with the leading `sub NAME` stripped -- the part
# that must be byte-identical for two clones to be EXACT (type-1). Re-parses the file. With
# want_node it also returns the CST sub node (for its byte span); returns undef / () on miss.
sub _sub_rest ($self, $node, %opt) {
    my $disk = path($self->root)->child($node->{file_path} // '');
    return $opt{want_node} ? () : undef unless $disk->is_file;
    my $tree = eval { $self->parser->parse_string($disk->slurp_raw) } or return $opt{want_node} ? () : undef;
    my $short = ($node->{qualified_name} // $node->{name} // '') =~ s/.*:://r;
    my $sn = _find_sub($tree, $short, $node->{start_line}) or return $opt{want_node} ? () : undef;
    (my $rest = $sn->{text} // '') =~ s/\A\s*sub\s+\w+//;        # drop `sub NAME`, keep (sig) { body }
    $rest =~ s/\A\s+//;
    $rest =~ s/\s+\z//;
    return $opt{want_node} ? ($rest, $sn) : $rest;
}

# The fifth WRITE tool: safely DELETE a dead sub. Refuses if the target is still called by
# any in-repo node, or is exported (it may have out-of-repo consumers) -- you remove the
# callers / export first. When it IS dead, removes it AND cascade-removes the now-dead
# PRIVATE helpers it solely used (recursively, to a fixed point), so a whole dead subtree
# goes in one shot. Dry-run unless apply => 1.
sub rm ($self, $target, %opt) {
    my $s = $self->store;
    my @defs = grep { ($_->{kind} // '') =~ /\A(?:function|method)\z/ }
               ($target =~ /::/ ? $s->nodes_by_qname($target) : $s->nodes_by_name($target));
    return { error => "no function/method named '$target'" } unless @defs;
    return { error => "'$target' is ambiguous (@{[ scalar @defs ]} defs) -- qualify it" } if @defs > 1;
    my $t = $defs[0];
    return { error => "'$target' is exported -- it may have out-of-repo consumers; remove the export first" }
        if $t->{is_exported};
    my @callers = grep { $_->{source} ne $t->{id} } $s->incoming_edges($t->{id}, 'calls', 'references');
    if (@callers) {
        my %who; for (@callers) { my $n = $s->node($_->{source}); $who{ $n->{qualified_name} // $n->{name} // '?' } = 1 if $n }
        return { error => "'$target' is still called -- remove the call site(s) first", blocked_by => [ sort keys %who ] };
    }
    my %rm = ($t->{id} => $t);                                   # cascade now-dead PRIVATE helpers to a fixed point
    my $changed = 1;
    while ($changed) {
        $changed = 0;
        for my $n (values %rm) {
            for my $e ($s->outgoing_edges($n->{id}, 'calls', 'references')) {
                my $c = $s->node($e->{target}) or next;
                next if $rm{$c->{id}} || $c->{is_exported};
                next unless ($c->{kind} // '') =~ /\A(?:function|method)\z/ && ($c->{visibility} // '') eq 'private';
                next if grep { !$rm{$_->{source}} } $s->incoming_edges($c->{id}, 'calls', 'references');
                $rm{$c->{id}} = $c;
                $changed = 1;
            }
        }
    }
    my @nodes   = sort { ($a->{qualified_name} // '') cmp ($b->{qualified_name} // '') } values %rm;
    my $applied = $opt{apply} ? $self->_apply_removals(\@nodes) : 0;
    return { target => $t->{qualified_name}, applied => $applied,
             removed => [ map { +{ name => ($_->{qualified_name} // $_->{name}), file => $_->{file_path},
                                   cascade => ($_->{id} ne $t->{id} ? 1 : 0) } } @nodes ] };
}

# Remove each node's `sub NAME {...}` span from disk (right-to-left per file, eating the
# def's indentation + trailing newline). Re-parses to get exact byte spans, like _apply_inline.
sub _apply_removals ($self, $nodes) {
    my %by_file;
    push @{ $by_file{ $_->{file_path} } }, $_ for grep { $_->{file_path} } @$nodes;
    my $count = 0;
    for my $file (sort keys %by_file) {
        my $disk = path($self->root)->child($file);
        next unless $disk->is_file;
        my $src  = $disk->slurp_raw;
        my $tree = eval { $self->parser->parse_string($src) } or next;
        my @line_off = (0);
        my $off = 0;
        $off += length($_), push @line_off, $off for split /(?<=\n)/, $src;
        my @abs;
        for my $node (@{ $by_file{$file} }) {
            my $short = ($node->{qualified_name} // $node->{name} // '') =~ s/.*:://r;
            my $sn = _find_sub($tree, $short, $node->{start_line}) or next;
            my ($sl, $sc, $el, $ec) = @{$sn}{qw(sl sc el ec)};
            push @abs, [ ($line_off[$sl - 1] // -1) + $sc, ($line_off[$el - 1] // -1) + $ec ];
        }
        for my $a (sort { $b->[0] <=> $a->[0] } @abs) {          # right-to-left so offsets stay valid
            my ($x, $y) = @$a;
            next if $x < 0 || $y < $x || $y > length $src;
            $x-- while $x > 0 && substr($src, $x - 1, 1) =~ /[ \t]/;
            $y++ if substr($src, $y, 1) eq "\n";
            substr($src, $x, $y - $x) = '';
            $count++;
        }
        $disk->spew_raw($src);
    }
    return $count;
}

# The SIXTH write tool: change a plain function's parameter list and propagate it to every
# RESOLVED call site. Three conservative operations -- add a parameter (`add => SPEC`, at 1-based
# position `at` or appended, inserting `value` (default `undef`) at each call site), remove one
# (`remove => N`, dropping the Nth positional argument at each site), or reorder them
# (`reorder => '2,1,3'`, a permutation that also permutes each call site's args). Function-only: a
# method ($self/$class first param) is refused, and a `$obj->method` call site is reported to
# the frontier, because the invocant offsets the positions and the dispatch can't be statically
# tied. A call site whose argument list is statically indeterminate (a splat / deref / call
# result among the args) or that doesn't reach the touched position is reported, never edited.
# The def's signature and every call site are byte-span edits. Dry-run unless apply => 1.
sub change_signature ($self, $target, %opt) {
    my $s = $self->store;
    my $n_ops = (defined $opt{add}) + (defined $opt{remove}) + (defined $opt{reorder});
    return { error => "specify --add '\$param', --remove N, or --reorder '2,1,3'" } unless $n_ops;
    return { error => "use only one of --add / --remove / --reorder" }                if $n_ops > 1;
    my $op = defined $opt{remove} ? 'remove' : defined $opt{reorder} ? 'reorder' : 'add';

    my @defs = grep { ($_->{kind} // '') eq 'function' }
               ($target =~ /::/ ? $s->nodes_by_qname($target) : $s->nodes_by_name($target));
    return { error => "no plain function named '$target'" }                            unless @defs;
    return { error => "'$target' is ambiguous (@{[ scalar @defs ]} defs) -- qualify it" } if @defs > 1;
    my $def   = $defs[0];
    my $qn    = $def->{qualified_name};
    my $short = $qn =~ s/.*:://r;
    my $sigtext = $def->{signature};
    return { error => "$qn has no explicit signature -- change-signature needs `sub $short (\$a, \$b)` to map call-site positions" }
        unless defined $sigtext && $sigtext =~ /\A\s*\(.*\)\s*\z/s;
    my @params = grep { length } map { s/\A\s+|\s+\z//gr } _split_top_commas($sigtext =~ s/\A\s*\(\s*|\s*\)\s*\z//gr);
    return { error => "$qn looks like a method (first param is \$self/\$class) -- change-signature is function-only" }
        if @params && $params[0] =~ /\A\$(?:self|class)\b/;

    my ($newparams, $pos, $value);
    if ($op eq 'remove') {
        $pos = $opt{remove};
        return { error => "--remove takes a 1-based position (this signature has @{[ scalar @params ]} param(s))" }
            unless $pos =~ /\A[1-9][0-9]*\z/ && $pos <= @params;
        my @np = @params; splice @np, $pos - 1, 1; $newparams = \@np;
    }
    elsif ($op eq 'reorder') {
        my @perm = grep { length } split /\s*,\s*/, ($opt{reorder} =~ s/\A\s+|\s+\z//gr);
        return { error => "--reorder takes a comma list of 1-based positions, e.g. '2,1,3'" }
            if !@perm || grep { !/\A[1-9][0-9]*\z/ } @perm;
        return { error => "--reorder must be a permutation of 1..@{[ scalar @params ]} (got '@{[ join ',', @perm ]}')" }
            unless @perm == @params && join(',', sort { $a <=> $b } @perm) eq join(',', 1 .. @params);
        return { error => "the reorder leaves the parameters in their current order" }
            if join(',', @perm) eq join(',', 1 .. @params);
        $newparams = [ map { $params[$_ - 1] } @perm ];
        $pos = \@perm;                                                # passed to _rewrite_args; carries the permutation
    }
    else {
        my $spec = $opt{add} =~ s/\A\s+|\s+\z//gr;
        return { error => "--add takes a parameter, e.g. '\$verbose' or '\$n = 0'" }
            unless $spec =~ /\A[\$\@%]\w+\s*(?:=.*)?\z/s;
        $pos = defined $opt{at} ? $opt{at} : @params + 1;
        return { error => "--at takes a 1-based position (1..@{[ scalar @params + 1 ]})" }
            unless $pos =~ /\A[1-9][0-9]*\z/ && $pos <= @params + 1;
        my @np = @params; splice @np, $pos - 1, 0, $spec; $newparams = \@np;
        $value = defined $opt{value} ? $opt{value} : 'undef';
    }
    my $newsig = '(' . join(', ', @$newparams) . ')';
    # the resulting signature must obey Perl's parameter-ordering rules, or it won't compile:
    # a slurpy (@/%) must be LAST, and a required scalar can't follow an optional (defaulted)
    # one. Inserting `$z` after `$n = 5`, or anything after a `@rest`, would break -- so refuse
    # rather than write a broken sub.
    my ($opt_seen, $slurpy_seen) = (0, 0);
    for my $p (@$newparams) {
        return { error => "the resulting signature `$newsig` would not compile -- a slurpy (\@/%) parameter must be last" }
            if $slurpy_seen;
        my $is_slurpy = $p =~ /\A[\@%]/;
        my $is_opt    = $is_slurpy || $p =~ /=/;
        return { error => "the resulting signature `$newsig` would not compile -- a required parameter can't follow an optional one; give it a default or change the position" }
            if $opt_seen && !$is_opt;
        $opt_seen    ||= $is_opt;
        $slurpy_seen ||= $is_slurpy;
    }

    my $ddisk = path($self->root)->child($def->{file_path});
    return { error => "cannot read $def->{file_path}" } unless $ddisk->is_file;
    my $dtree = eval { $self->parser->parse_string($ddisk->slurp_raw) } or return { error => "could not parse $def->{file_path}" };
    my $subnode = _find_sub($dtree, $short, $def->{start_line}) or return { error => "could not locate sub $short in $def->{file_path}" };
    my ($signode) = grep { ($_->{type} // '') eq 'signature' } @{ $subnode->{children} // [] };
    return { error => "could not locate the signature node of $qn (re-sync the index?)" } unless $signode;

    # Removing a parameter still referenced elsewhere would leave a dangling variable that no
    # longer compiles: in the BODY (`sub f () { $x }` after dropping $x) OR in a SURVIVING
    # parameter's default (`sub f ($x, $y = $x + 1)` after dropping $x). We can't repair either,
    # so refuse. Match any sigil + optional brace + the name (so `${x}` interpolation forms count
    # too, not just a bare `$x`) -- err toward refusing, since a missed use corrupts.
    if ($op eq 'remove' and my ($var, $name) = $params[$pos - 1] =~ /\A([\$\@%](\w+))/) {
        my ($block) = grep { ($_->{type} // '') eq NODE_BLOCK } @{ $subnode->{children} // [] };
        my $body_uses = $block && (($block->{text} // '') =~ /[\$\@%]\{?\Q$name\E\b/);
        my $sig_uses  = grep { /[\$\@%]\{?\Q$name\E\b/ } @$newparams;   # a surviving param's default
        return { error => "removing parameter #$pos ($var) would leave $qn still using $var "
                        . ($body_uses ? 'in its body' : "in another parameter's default")
                        . " -- remove its uses (or rename the parameter) first" }
            if $body_uses || $sig_uses;
    }

    my @edits = ({ file => $def->{file_path}, line => $signode->{sl}, def => 1,
                   span => [ @{$signode}{qw(sl sc el ec)} ], replacement => $newsig });

    my $resolver = App::PerlGraph::Resolver->new(store => $s);
    my %files = ($def->{file_path} => 1);
    for my $e ($s->incoming_edges($def->{id}, 'calls', 'references')) {
        my $n = $s->node($e->{source});
        $files{ $n->{file_path} } = 1 if $n && defined $n->{file_path};
    }
    $files{ $_->{file_path} } = 1
        for $s->_rows('select distinct file_path from unresolved_refs where reference_name = ?', $short);

    my @frontier;
    for my $file (sort keys %files) {
        my $fdisk = path($self->root)->child($file);
        next unless $fdisk->is_file;
        my $fsrc  = $fdisk->slurp_raw;
        my $ftree = eval { $self->parser->parse_string($fsrc) } or next;
        my $calls = _calls_by_pos($ftree);
        my $out   = eval { App::PerlGraph::Extractor->new(file_path => $file, source => $fsrc)->extract($ftree) } or next;
        for my $r (@{ $out->{refs} }) {
            next unless ($r->{reference_name} // '') eq $short || ($r->{reference_name} // '') eq $qn;
            if (($r->{reference_kind} // '') eq 'method_call') {
                push @frontier, { file => $file, line => $r->{line}, why => 'method call ($obj->...) -- function-only' };
                next;
            }
            my $tn = $resolver->_resolve_call($r);
            next unless $tn && $tn->{id} eq $def->{id};                          # provably this function
            my $call = $calls->{ "$r->{line}:$r->{col}" };
            if (!$call) { push @frontier, { file => $file, line => $r->{line}, why => 'could not pinpoint the call expression' }; next }
            my $argsnode = $call->{fields}{ +F_ARGUMENTS };
            my ($new, $why) = _rewrite_args($argsnode, $op, $pos, $value);
            if (!defined $new) { push @frontier, { file => $file, line => $r->{line}, why => $why }; next }
            push @edits, { file => $file, line => $r->{line},
                           span => [ @{$argsnode}{qw(sl sc el ec)} ], replacement => $new };
        }
    }

    my $applied = $opt{apply} ? $self->_apply_inline(\@edits, undef) : 0;
    return { target => $qn, op => $op, position => (ref $pos eq 'ARRAY' ? join(',', @$pos) : $pos),
             signature => $sigtext, new_signature => $newsig,
             value => $value, edits => \@edits, frontier => \@frontier, files => [ sort keys %files ], applied => $applied };
}

# Split on top-level commas (depth-aware), so a nested `foo(1, 2)` or `[1, 2]` arg stays whole.
sub _split_top_commas ($str) {
    my @out; my $buf = ''; my $depth = 0;
    for my $ch (split //, $str) {
        if    ($ch =~ /[(\[{]/)           { $depth++;        $buf .= $ch }
        elsif ($ch =~ /[)\]}]/)           { $depth--;        $buf .= $ch }
        elsif ($ch eq ',' && $depth == 0) { push @out, $buf; $buf = '' }
        else                              {                  $buf .= $ch }
    }
    push @out, $buf if length $buf;
    return @out;
}

# Statically determinate top-arg count of a call's F_ARGUMENTS node, or undef if a splat /
# deref / list-returning call among the args makes the positions ambiguous (mirrors
# Query::_count_args, the same rule pcg_checkargs uses).
sub _arg_count ($argsnode) {
    return 0 unless $argsnode;
    my @top = (($argsnode->{type} // '') eq NODE_LIST_EXPR)
        ? grep { ($_->{type} // '') !~ /\A[[:punct:]]+\z/ } @{ $argsnode->{children} // [] }
        : ($argsnode);
    for my $a (@top) {
        my $t = $a->{type} // '';
        return undef if $t =~ /\A(?:array|hash)\z/ || $t =~ /(?:array|hash)_deref/ || $t =~ /_call_expression\z/;
    }
    return scalar @top;
}

# Rewrite a call's argument text for the operation, or (undef, reason) when it can't be done
# safely (indeterminate arg list, or the call doesn't reach the touched position).
sub _rewrite_args ($argsnode, $op, $pos, $value) {
    my $cnt = _arg_count($argsnode);
    return (undef, 'indeterminate argument list (a splat / deref / call-result arg) -- positions are ambiguous')
        unless defined $cnt;
    my @args = grep { length } map { s/\A\s+|\s+\z//gr } ($argsnode ? _split_top_commas($argsnode->{text} // '') : ());
    return (undef, "could not split the $cnt-arg call's argument list (a string/heredoc arg with a comma the splitter can't see?)")
        if @args != $cnt;
    if ($op eq 'remove') {
        return (undef, "the call passes $cnt arg(s) -- it does not reach the removed position $pos") if $cnt < $pos;
        my @na = @args; splice @na, $pos - 1, 1;
        return (join(', ', @na), undef);
    }
    if ($op eq 'reorder') {                                          # $pos is the permutation (1-based old positions, new order)
        return (undef, "the call passes $cnt arg(s) but the signature has @{[ scalar @$pos ]} parameter(s) -- can't position-map the reorder")
            if $cnt != @$pos;
        return (join(', ', map { $args[$_ - 1] } @$pos), undef);
    }
    return (undef, 'the call has no argument list to extend -- add the argument manually') unless $argsnode;
    return (undef, "the call passes $cnt arg(s) -- cannot insert at position $pos") if $pos > $cnt + 1;
    my @na = @args; splice @na, $pos - 1, 0, $value;
    return (join(', ', @na), undef);
}

# function_call_expression nodes keyed "line:col" (their start), to map a resolved ref back
# to the full call expression (with its byte span + argument text) for replacement.
sub _calls_by_pos ($tree) {
    my %by;
    my @stack = ($tree);
    while (my $n = pop @stack) {
        $by{ "$n->{sl}:$n->{sc}" } = $n if ($n->{type} // '') eq NODE_CALL;
        push @stack, @{ $n->{children} // [] };
    }
    return \%by;
}

# Given a sub node, return (\&build, undef) where build->($args_text) yields the `do {...}`
# inline for a call with those args, or (undef, reason) if the sub is not safely inlineable.
sub _inline_template ($sub) {
    my ($block) = grep { ($_->{type} // '') eq NODE_BLOCK } @{ $sub->{children} // [] };
    return (undef, 'no body block') unless $block;
    (my $body = $block->{text} // '') =~ s/\A\s*\{//;
    $body =~ s/\}\s*\z//;
    $body =~ s/\A\s+//; $body =~ s/\s+\z//;
    return (undef, 'empty body') unless length $body;
    for my $kw (qw(return wantarray shift pop caller goto local)) {
        return (undef, "the body uses `$kw` (control flow / \@_ a do-block can't preserve)") if $body =~ /\b\Q$kw\E\b/;
    }
    return (undef, 'the body indexes @_ directly ($_[N])') if $body =~ /\$_\[/;

    my $sig;
    for my $c (@{ $sub->{children} }) { $sig = $c->{text}, last if ($c->{type} // '') eq 'signature' }
    if (defined $sig) {
        return (undef, 'the signature has defaults or a slurpy param') if $sig =~ /[=\@\%]/;
        my $params = $sig =~ s/\A\(\s*|\s*\)\z//gr;
        return (sub ($args) { length $params ? "do { my ($params) = ($args); $body }" : "do { $body }" }, undef);
    }
    my @at = $body =~ /(\@_)/g;
    if (@at == 1 && $body =~ /\bmy\b[^;]*=\s*\@_/) {                          # the `my (...) = @_` unpack idiom
        # literal substr replace, NOT s/// -- $args is raw call-site text that may contain
        # $1/$&/etc., which a regex replacement would interpolate as capture vars.
        return (sub ($args) { my $b = $body; substr($b, index($b, '@_'), 2) = "($args)"; "do { $b }" }, undef);
    }
    return (undef, '@_ is used ' . scalar(@at) . ' times (would re-evaluate the arguments)') if @at;
    return (sub ($args) { "do { $body }" }, undef);                          # a parameterless body
}

# Apply inline edits: each is a (line,col)-span of source replaced by its `do {...}` text.
# Spans are converted to byte offsets and applied right-to-left so earlier edits don't shift
# later ones. An optional $remove span (the definition) is deleted, swallowing its indentation
# and trailing newline. Each span is re-validated against the current bytes.
sub _apply_inline ($self, $edits, $remove) {
    my %by_file;
    push @{ $by_file{ $_->{file} } }, $_ for @$edits;
    push @{ $by_file{ $remove->{file} } }, { %$remove, replacement => '', _remove => 1 } if $remove;
    my $count = 0;
    for my $file (sort keys %by_file) {
        my $disk = path($self->root)->child($file);
        next unless $disk->is_file;
        my $src  = $disk->slurp_raw;
        my @line_off = (0);                                                  # byte offset of each line start
        my $off = 0;
        $off += length($_), push @line_off, $off for split /(?<=\n)/, $src;
        my @apply;
        for my $e (@{ $by_file{$file} }) {
            my ($sl, $sc, $el, $ec) = @{ $e->{span} };
            my $start = ($line_off[$sl - 1] // -1) + $sc;
            my $end   = ($line_off[$el - 1] // -1) + $ec;
            next if $start < 0 || $end < $start || $end > length $src;
            push @apply, { start => $start, end => $end, repl => $e->{replacement}, rm => $e->{_remove} };
        }
        for my $a (sort { $b->{start} <=> $a->{start} } @apply) {            # right-to-left
            if ($a->{rm}) {
                my ($x, $y) = ($a->{start}, $a->{end});
                $x-- while $x > 0 && substr($src, $x - 1, 1) =~ /[ \t]/;     # eat the def's indentation
                $y++ if substr($src, $y, 1) eq "\n";                        # and its trailing newline
                substr($src, $x, $y - $x) = '';
            }
            else {
                substr($src, $a->{start}, $a->{end} - $a->{start}) = $a->{repl};
            }
            $count++;
        }
        $disk->spew_raw($src);
    }
    return $count;
}

# Extract a contiguous STATEMENT RANGE out of a sub into a new named sub (the inverse of inline).
# Inputs = variables declared OUTSIDE the range that it reads (-> the new sub's params); outputs =
# variables the range `my`-declares that are read AFTER it (-> the return list + a `my (...) =` at
# the call site). CONSERVATIVE: refuses anything it can't prove safe -- non-local control flow
# (return/next/last/redo/goto/wantarray), a direct @_ read, an outer variable the range MUTATES
# (its new value can't be threaded back), a `state` declaration (its persistence wouldn't survive),
# a range that splits a statement (or one ending on the sub's closing-brace line), or >1 array/hash
# input OR output (the call site couldn't unpack them).
# Dry-run unless apply: shows the generated sub, the call that replaces the range, and inputs/outputs.
sub extract ($self, $file, $range, $name, %opt) {
    return { error => "give a bare sub name, not '@{[ $name // '' ]}'" } unless defined $name && $name =~ /\A[A-Za-z_]\w*\z/;
    my ($rs, $re) = (($range // '') =~ /\A(\d+)-(\d+)\z/);
    return { error => "range must be START-END line numbers (e.g. 10-15)" } unless $rs && $re && $re >= $rs;
    my $disk = path($self->root)->child($file);
    return { error => "no such file: $file" } unless $disk->is_file;
    my $src  = $disk->slurp_raw;
    my $tree = eval { $self->parser->parse_string($src) } or return { error => "could not parse $file" };
    my @lines = split /(?<=\n)/, $src;

    # enclosing sub = the smallest NODE_SUB whose body strictly contains [rs,re] (sl < rs keeps the
    # `sub`/signature line outside the range; el >= re keeps the close brace outside).
    my @subs;
    { my @st = ($tree); while (my $n = pop @st) { push @subs, $n if ($n->{type} // '') eq NODE_SUB; push @st, @{ $n->{children} // [] } } }
    my ($sub) = sort { ($a->{el} - $a->{sl}) <=> ($b->{el} - $b->{sl}) }
                grep { ($_->{sl} // 0) < $rs && ($_->{el} // 0) >= $re } @subs;
    return { error => "lines $range are not inside a single sub body" } unless $sub;

    my ($block) = grep { ($_->{type} // '') eq NODE_BLOCK } @{ $sub->{children} };
    return { error => "could not find the sub body" } unless $block;
    my @stmts = grep { ($_->{type} // '') =~ /statement\z/ } @{ $block->{children} };
    for my $s (@stmts) {                                          # a statement straddling either edge -> refuse
        my ($a, $b) = ($s->{sl} // 0, $s->{el} // 0);
        return { error => "lines $range split a statement (it spans lines $a-$b) -- extract whole statements" }
            if ($a < $rs && $b >= $rs) || ($a <= $re && $b > $re);
    }
    my @rstmts = grep { ($_->{sl} // 0) >= $rs && ($_->{el} // 0) <= $re } @stmts;
    return { error => "no complete statements in lines $range" } unless @rstmts;
    my ($lo, $hi) = ($rstmts[0]{sl}, $rstmts[-1]{el});
    # If the last statement shares its line with the sub's closing brace (`stmt }` on one line),
    # the line-based splice that replaces the range would eat the `}` -- refuse rather than corrupt.
    return { error => "the range's last line ($hi) also holds the sub's closing brace -- put the `}` on its own line, or shrink the range" }
        if $hi >= ($sub->{el} // 0);
    my $rtext = join '', @lines[ $lo - 1 .. $hi - 1 ];

    for my $kw (qw(return next last redo goto wantarray)) {
        return { error => "the range uses `$kw` -- a block with non-local control flow can't move into a sub" }
            if $rtext =~ /(?<![\w>-])\b\Q$kw\E\b/;
    }
    return { error => "the range reads \@_ directly -- extract can't thread the caller's args" } if $rtext =~ /\@_/;
    # A `state` var persists across calls to the ENCLOSING sub; moved into a new sub (called once
    # per enclosing call) its persistence + any post-range write-back would silently change meaning.
    return { error => "the range declares a `state` variable -- its cross-call persistence wouldn't survive extraction" }
        if $rtext =~ /(?<![\w>-])\bstate\s+[\$\@%(]/;

    # every `my`/`state`/`our`/`local` declaration in the sub, tagged with its line, + signature params.
    my @decl;
    { my @st = ($sub); while (my $n = pop @st) {
        push @decl, { sl => $n->{sl} // 0, vars => [ _decl_vars($n) ] } if ($n->{type} // '') eq 'variable_declaration';
        push @st, @{ $n->{children} // [] };
    } }
    my ($sig) = grep { ($_->{type} // '') eq 'signature' } @{ $sub->{children} };
    my @sigp  = $sig ? (($sig->{text} // '') =~ /([\$\@%]\w+)/g) : ();
    my %decl_in = map { $_ => 1 } map { @{ $_->{vars} } } grep { $_->{sl} >= $lo && $_->{sl} <= $hi } @decl;
    my @outer   = do { my %s; grep { !$s{$_}++ } @sigp, map { @{ $_->{vars} } } grep { $_->{sl} < $lo } @decl };
    my $atext   = $hi < ($sub->{el} // 0) ? join('', @lines[ $hi .. $sub->{el} - 1 ]) : '';

    my @inputs  = grep { _var_used($rtext, $_) } @outer;                  # outer vars the range reads
    my @outputs = grep { _var_used($atext, $_) } sort keys %decl_in;      # range-locals read afterwards

    my @lhs = _assign_lhs(\@rstmts);                                      # non-my assignment targets in the range
    if (my @mut = grep { my $in = $_; grep { _var_used($_, $in) } @lhs } @inputs) {
        return { error => "the range modifies @{[ join ', ', @mut ]} (declared outside it) -- extract can't thread the new value back" };
    }
    return { error => "the range has more than one array/hash input (@{[ join ', ', grep { /\A[\@%]/ } @inputs ]}) -- not safely unpackable as params" }
        if (grep { /\A[\@%]/ } @inputs) > 1;
    @inputs = ((grep { /\A\$/ } @inputs), (grep { /\A[\@%]/ } @inputs));   # a single array/hash param goes last
    # Same hazard on the RETURN side: `my (@a, @b) = f()` would let @a swallow everything. Refuse >1
    # array/hash output, and put the single one last so `my ($s, @rest) = f()` unpacks correctly.
    return { error => "the range has more than one array/hash output (@{[ join ', ', grep { /\A[\@%]/ } @outputs ]}) -- the call site can't unpack them (the first would swallow the rest)" }
        if (grep { /\A[\@%]/ } @outputs) > 1;
    @outputs = ((grep { /\A\$/ } @outputs), (grep { /\A[\@%]/ } @outputs));

    my $indent = $lines[$lo-1] =~ /\A(\s*)/ ? $1 : '';
    (my $body = $rtext) =~ s/\n\z//;
    my $ret = @outputs > 1 ? '(' . join(', ', @outputs) . ')' : $outputs[0];
    my @nb = ("sub $name {\n");
    push @nb, "${indent}my (" . join(', ', @inputs) . ") = \@_;\n" if @inputs;
    push @nb, map { "$_\n" } split /\n/, $body;
    push @nb, "${indent}return $ret;\n" if @outputs;
    push @nb, "}\n";
    my $new_sub = join '', @nb;
    my $call = $indent . (@outputs ? "my $ret = " : '') . "$name(" . join(', ', @inputs) . ");\n";

    my $applied = 0;
    if ($opt{apply}) {
        splice @lines, $lo - 1, $hi - $lo + 1, $call;            # range -> the call
        my $insert = ($sub->{el} // 0) - ($hi - $lo);           # the close brace shifted up by the lines we removed
        splice @lines, $insert, 0, "\n$new_sub";                # new sub right after the enclosing sub
        $disk->spew_raw(join '', @lines);
        $applied = 1;
    }
    return { sub => (($sub->{fields}{ +F_NAME } // {})->{text} // '?'), name => $name, file => $file,
             lines => "$lo-$hi", inputs => \@inputs, outputs => \@outputs,
             new_sub => $new_sub, call => $call, applied => $applied };
}

sub _decl_vars ($n) { return ($n->{text} // '') =~ /([\$\@%]\w+)/g }

# Does $text reference the declared variable $var (e.g. '$x' / '@x' / '%x'), counting Perl's
# sigil-variant access forms ($x[..] reads @x, $x{..} reads %x, $#x reads @x, @x{..} reads %x)?
sub _var_used ($text, $var) {
    my ($sig, $nm) = $var =~ /\A([\$\@%])(\w+)\z/ or return 0;
    my $n = qr/(?:\{\Q$nm\E\}|\Q$nm\E\b)/;          # the name, bare OR ${braced} (interpolation `"${x}y"` counts)
    my $lb = qr/(?<![\w\$\@%])/;                     # not part of a longer name / a $$ / @$ / %$ deref
    return scalar $text =~ /$lb\$$n(?![\[{])/                                      if $sig eq '$';
    return scalar $text =~ /$lb\@$n(?!\{)|$lb\$$n\s*\[|\$#\{?\Q$nm\E\}?/           if $sig eq '@';
    return scalar $text =~ /$lb\%$n|$lb\$$n\s*\{|$lb\@$n\s*\{/;
}

# The assignment TARGET texts in these statements -- the LHS of every assignment whose LHS is not a
# `my`/etc. declaration (those make new locals, not mutations). Used to detect a mutated input.
sub _assign_lhs ($stmts) {
    my @lhs;
    my @st = @$stmts;
    while (my $n = pop @st) {
        if (($n->{type} // '') eq 'assignment_expression') {
            my $first = ($n->{children} // [])->[0];
            push @lhs, $first->{text} // '' if $first && ($first->{type} // '') ne 'variable_declaration';
        }
        push @st, @{ $n->{children} // [] };
    }
    return @lhs;
}

# Orchestrated cleanup: APPLY the safe subset of the `pcg tidy` survey. Phase 1 dedupes each
# exact-clone group (rewrites copies to `goto &Canonical`); phase 2 rm's each unused sub (with
# rm's own export/caller guards + dead-private-helper cascade), looping so cross-batch cascades
# (a helper only the just-removed subs called) surface after each graph re-sync. Dead EXPORTS are
# reported, never auto-retracted -- removing public API may break out-of-repo consumers. The
# dry-run is just `pcg tidy` (the survey + per-item commands); this is the executor (apply:true).
sub tidy ($self, %opt) {
    require App::PerlGraph::Query;
    require App::PerlGraph::Indexer;
    my $survey = App::PerlGraph::Query->new(store => $self->store)->tidy(%opt);
    return { %$survey, applied => 0 } unless $opt{apply};

    my $idx = App::PerlGraph::Indexer->new(store => $self->store, root => $self->root);
    my (@deduped, @removed, @skipped);

    # Phase 1 -- dedupe exact-clone groups (canonical = the first FUNCTION member; dedupe keeps a
    # function, and skips methods/type-2 copies itself). Independent groups -> one sync after all.
    for my $g (@{ $survey->{clones} // [] }) {
        my ($canon) = grep { ($_->{kind} // '') eq 'function' } @{ $g->{members} // [] };
        next unless $canon && defined $canon->{qualified_name};
        my $r = $self->dedupe($canon->{qualified_name}, apply => 1);
        if    ($r->{error})                 { push @skipped, { op => 'dedupe', target => $canon->{qualified_name}, why => $r->{error} } }
        elsif (@{ $r->{replaced} // [] })   { push @deduped, { canonical => $r->{canonical}, replaced => [ map { $_->{name} } @{ $r->{replaced} } ] } }
    }
    $idx->sync if @deduped;

    # Phase 2 -- rm unused subs. A survey's removable subs are mutually independent (an unused sub
    # has no caller, so none calls another), so a whole batch applies cleanly before one re-sync;
    # the loop then re-surveys to catch helpers freed by the removals. Bounded against runaway.
    my %tried;
    for (1 .. 12) {
        my @rem = grep { defined $_->{qualified_name} && !$tried{ $_->{qualified_name} }++ }
                  @{ App::PerlGraph::Query->new(store => $self->store)->tidy->{removable} };
        last unless @rem;
        my $did = 0;
        for my $sub (@rem) {
            my $r = $self->rm($sub->{qualified_name}, apply => 1);
            if ($r->{error}) { push @skipped, { op => 'rm', target => $sub->{qualified_name}, why => $r->{error} } }
            else             { push @removed, @{ $r->{removed} }; $did++ }
        }
        last unless $did;
        $idx->sync;
    }

    return { deduped => \@deduped, removed => \@removed, skipped => \@skipped, applied => 1 };
}

1;

__END__

=head1 NAME

App::PerlGraph::Refactor - graph-driven rename / move / inline / extract / dedupe / change-signature / rm codemods

=head1 DESCRIPTION

The seven graph-driven write tools (plus the C<tidy> cleanup orchestrator). RENAMES a
function/method within its own package; MOVES a function to another existing package
(relocating its source and requalifying call sites to NewPkg::sub); INLINES a simple function
at its call sites as a C<do { ... }> block and removes the definition; EXTRACTs a contiguous
statement range out of a sub into a new named sub (the inverse of inline, inferring parameters
and a return list from variable liveness); DEDUPEs an exact (type-1) structural clone group by
keeping one canonical function and rewriting each byte-identical duplicate to C<sub name { goto
&Canonical }>; CHANGE_SIGNATUREs a plain function by adding, removing, or reordering a parameter
and propagating it to every resolved call site; or safely RMs a dead sub, cascade-removing the
now-dead private helpers it solely used. C<tidy> orchestrates the safe subset (dedupe + rm,
re-syncing between) for a whole-codebase cleanup. All use the resolved call graph to locate every
reference precisely and the resolver to decide which call sites actually target the symbol.
Dynamic C<$obj-E<gt>method>
dispatch that cannot be tied to the symbol is reported, not edited; rm refuses a sub that is
still called or exported; dedupe refuses outright if the canonical carries a prototype or
C<:attribute> the C<goto> stub cannot preserve, otherwise it skips type-2 clones, methods, and
clones whose file cannot load the canonical; and change_signature is function-only, reporting
a method or indeterminate-argument call site rather than editing it. Internal to
L<App::PerlGraph>; driven by C<pcg rename> / C<pcg move> / C<pcg inline> / C<pcg dedupe> /
C<pcg change-signature> / C<pcg rm> and the matching C<pcg_*> MCP tools.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
