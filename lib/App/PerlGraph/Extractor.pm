package App::PerlGraph::Extractor;
use v5.36;
our $VERSION = q{0.074};
use Moo;
use App::PerlGraph::Model qw(node_id qualify sink_type);
use App::PerlGraph::Grammar qw(:all);
use App::PerlGraph::Pod;
use Digest::SHA qw(sha1_hex);
no warnings 'recursion';   # deep but bounded CST walks (after Moo re-enables warnings)

# Walks a normalized parse tree (from App::PerlGraph::Parser) and produces
# { nodes => [...], edges => [...], refs => [...] }.
#
# Scope model: the *current package* is instance state ($self->{_pkg}).
# Statement-form `package NAME;` sets it and leaks to all following siblings.
# Block-form `package NAME { ... }` sets it for its block only, then _walk
# restores the prior value at the block boundary. The *current sub* is threaded
# through _walk as a parameter (it scopes to a sub body).

has file_path => (is => 'ro', required => 1);
has _nodes    => (is => 'ro', default => sub { [] });
has _edges    => (is => 'ro', default => sub { [] });
has _refs     => (is => 'ro', default => sub { [] });
has _packages => (is => 'ro', default => sub { {} });   # qname  -> package node (post-pass)
has _exports  => (is => 'ro', default => sub { {} });   # symbol -> 1
has source    => (is => 'ro', default => '');           # raw file source (for POD docstrings)

# `use`d module names that are pragmas / handled specially — not real imports.
# (`constant` is handled specially too -> _handle_constant, so it's not here.)
my %PRAGMA = map { $_ => 1 } qw(strict warnings utf8 feature lib vars overload);

# Layer 3 framework signals
my %FRAMEWORK  = ('Dancer2' => 'dancer', 'Dancer' => 'dancer', 'Mojolicious::Lite' => 'mojo');
my %ROUTE_VERB = map { $_ => 1 } qw(get post put del delete patch options any);
my %CAT_ATTR   = map { $_ => 1 } qw(Path Local Global Chained Args Method Private Regex LocalRegex);
my %MOOSEY     = map { $_ => 1 } qw(Moo Moose Moo::Role Moose::Role Mouse Mouse::Role);
# accessor-GENERATOR modules. `list`: `use X qw(a b)` -- the imports ARE the accessor names
# (Class::Tiny / Object::Tiny). `xs`: `use Class::XSAccessor getters => {m=>f}, ...` -- the
# accessor names are the KEYS of each option hash / the elements of each option array.
my %ACCESSOR_USE = map { $_ => 'list' } qw(Class::Tiny Object::Tiny Object::Tiny::RW Object::Tiny::XS);
$ACCESSOR_USE{$_} = 'xs' for qw(Class::XSAccessor Class::XSAccessor::Array);
# class-method accessor generators: `__PACKAGE__->mk_accessors(qw(a b))` (Class::Accessor[::Fast]).
my %ACCESSOR_METHOD = map { $_ => 1 } qw(mk_accessors mk_ro_accessors mk_wo_accessors);
# Class::XSAccessor OPTION keywords. In the hashref calling form (`use Class::XSAccessor { getters
# => {...}, constructor => 'new' }`) these are hash KEYS structurally identical to real accessor
# entries (`name => value`), so the key-walk would emit them as bogus accessors -- the keyword set
# is the only way to tell them apart, so it must be the COMPLETE documented set. None is a plausible
# real accessor name.
my %XS_OPTION = map { $_ => 1 } qw(accessors getters setters lvalue_accessors predicates
                                   exists_predicates exists_predicate constructor constructors
                                   true false replace chained);
my %MODIFIER   = map { $_ => 1 } qw(before after around);
# field attributes that generate a getter (`field $x :reader` -> `$self->x`)
my %FIELD_ACCESSOR = map { $_ => 1 } qw(reader accessor mutator);
# native-class / Object::Pad class attributes -> edge kind
my %CLASS_ATTR = (isa => 'extends', does => 'implements');
# CST node types that each add one branch -> cyclomatic complexity. The keyword
# nodes cover both block and statement-modifier forms (`if (..) {}` and `.. if ..`);
# tree-sitter exposes short-circuit operators with the operator string as the type.
my %DECISION = map { $_ => 1 } qw(if unless elsif while until for foreach when
                                  conditional_expression && || // and or);

sub extract ($self, $tree) {
    my $file = $self->_emit({ kind => 'file', name => $self->file_path,
        qualified_name => $self->file_path, start_line => 1, end_line => $tree->{el} });
    $self->{_file} = $file;
    $self->{_pkg}  = undef;
    $self->_walk($tree, undef);
    $self->_postprocess;
    return { nodes => $self->_nodes, edges => $self->_edges, refs => $self->_refs };
}

sub _emit ($self, $n) {
    $n->{file_path} //= $self->file_path;
    $n->{language}  //= 'perl';
    $n->{id} = node_id($n);
    push @{ $self->_nodes }, $n;
    return $n;
}

sub _edge ($self, $src, $tgt, $kind, %extra) {
    push @{ $self->_edges },
        { source => $src, target => $tgt, kind => $kind, provenance => 'static', %extra };
}

sub _walk ($self, $node, $cur_sub) {
    for my $child (@{ $node->{children} }) {
        my $t = $child->{type};
        if ($t eq NODE_PACKAGE || $t eq NODE_CLASS || $t eq NODE_ROLE) {
            my $prev = $self->{_pkg};
            # native `class` and Object::Pad `role` both scope methods/fields like a
            # package and compose via :isa/:does -- handle both as a class-like container.
            $self->{_pkg} = ($t eq NODE_CLASS || $t eq NODE_ROLE) ? $self->_handle_class($child) : $self->_handle_package($child);
            $self->_walk($child, $cur_sub);
            # Block form `package NAME { ... }` / `class NAME { ... }` scopes to its
            # block -> restore the outer package after it. Statement form has no
            # block child and intentionally leaks to following siblings.
            $self->{_pkg} = $prev if grep { $_->{type} eq NODE_BLOCK } @{ $child->{children} };
        }
        elsif ($t eq NODE_SUB || $t eq NODE_METHOD_DECL) {
            my $snode = $self->_handle_sub($child);
            local $self->{_vartype} = {};   # fresh `my $x = Class->new` -> Class scope per sub body
            $self->_walk($child, $snode // $cur_sub);
        }
        elsif ($t eq NODE_VAR_DECL) {
            # `field $x ...` inside a class (first child is the `field` keyword);
            # any other variable_declaration just recurses as before.
            $self->_handle_field($child)
                if @{ $child->{children} } && $child->{children}[0]{type} eq NODE_FIELD;
            $self->_walk($child, $cur_sub);
        }
        elsif ($t eq NODE_USE) {
            $self->_handle_use($child);
        }
        elsif ($t eq NODE_REQUIRE) {
            $self->_handle_require($child);
        }
        elsif ($t eq NODE_ASSIGN) {
            $self->_handle_assign($child);
            $self->_walk($child, $cur_sub);
        }
        elsif ($t eq NODE_METHOD_CALL) {
            if ($self->_mojo_app && $self->_handle_helper($child)) { }   # $app->helper(...) -- body walked inside
            else { $self->_handle_method_call($child, $cur_sub); $self->_walk($child, $cur_sub) }
        }
        elsif ($t eq NODE_REFGEN) {
            $self->_handle_refgen($child, $cur_sub);
            $self->_walk($child, $cur_sub);
        }
        elsif (grep { $_ eq $t } @{ +CALL_TYPES }) {
            if    ($self->_framework_now && $self->_handle_route($child, $cur_sub))    {}
            elsif ($self->_mojo_app      && $self->_handle_helper($child))             {}
            elsif ($self->_moosey_now    && $self->_handle_modifier($child, $cur_sub)) {}
            elsif (($self->_moosey_now || $self->_mojo_now) && $self->_handle_has($child)) {}
            elsif (($self->_moosey_now || $self->_mojo_now)                       # Mojo::Base composes roles with `with` too
                                          && ($self->_handle_isa_fn($child, 'with',    'implements')
                                          || $self->_handle_isa_fn($child, 'extends', 'extends')))     {}
            else  { $self->_handle_call($child, $cur_sub); $self->_walk($child, $cur_sub) }
        }
        else {
            $self->_walk($child, $cur_sub);
        }
    }
}

sub _src_id ($self) { $self->{_pkg} ? $self->{_pkg}{id} : $self->{_file}{id} }

sub _framework_now ($self) { ($self->{_pkg} && $self->{_pkg}{_framework}) || $self->{_framework_file} }
sub _moosey_now    ($self) { ($self->{_pkg} && $self->{_pkg}{_moosey})    || $self->{_moosey_file} }
sub _mojo_now      ($self) { ($self->{_pkg} && $self->{_pkg}{_mojo})      || $self->{_mojo_file} }
sub _mojo_app      ($self) { $self->_mojo_now || (($self->_framework_now // '') eq 'mojo') }

sub _handle_package ($self, $n) {
    my $nm = $n->{fields}{ +F_NAME };
    my $name = $nm ? $nm->{text} : 'main';
    my $pnode = $self->_emit({ kind => 'package', name => $name, qualified_name => $name,
        start_line => $n->{sl}, end_line => $n->{el} });
    $self->_edge($self->{_file}{id}, $pnode->{id}, 'contains');
    $self->_packages->{$name} = $pnode;
    return $pnode;
}

# Native `class NAME :isa(Parent) { ... }` (perl 5.38 feature 'class' / Object::Pad).
# Mirrors _handle_package but emits a class node and turns :isa into an extends edge
# (null target, resolved by name later -- same shape as `use parent` / @ISA).
# an attribute_value arrives as a raw token (`(Parent)`, `'Parent'`); strip the wrapping
sub _attr_value ($v) { (my $t = $v->{text} // '') =~ s/\A[\s('"]+|[\s)'"]+\z//g; $t }

sub _handle_class ($self, $n) {
    my $nm = $n->{fields}{ +F_NAME };
    my $name = $nm ? $nm->{text} : 'main';
    my $cnode = $self->_emit({ kind => 'class', name => $name, qualified_name => $name,
        start_line => $n->{sl}, end_line => $n->{el} });
    $self->_edge($self->{_file}{id}, $cnode->{id}, 'contains');
    $self->_packages->{$name} = $cnode;
    $cnode->{_is_role} = 1 if ($n->{type} // '') eq NODE_ROLE;   # native/Object::Pad `role NAME {...}`
    if (my $attrs = $n->{fields}{ +F_ATTRIBUTES }) {
        for my $a (@{ $attrs->{children} }) {
            next unless $a->{type} eq NODE_ATTRIBUTE;
            my $an = $a->{fields}{ +F_NAME } or next;
            my $kind = $CLASS_ATTR{ $an->{text} } or next;   # :isa -> extends, :does -> implements
            my $v = $a->{fields}{ +F_VALUE } or next;
            my $base = _attr_value($v);
            $self->_edge($cnode->{id}, undef, $kind, metadata => { via => $an->{text}, name => $base })
                if length $base;
        }
    }
    return $cnode;
}

# `field $x :param = ...;` inside a class -> a field node (sigil-stripped name,
# scoped to the class), matching the runtime MOP field naming.
sub _handle_field ($self, $n) {
    my $pkg = $self->{_pkg} or return;   # `field` is only meaningful inside a class
    my $var = $n->{fields}{ +F_VARIABLE } or return;
    my $vn  = $self->_find_descendant($var, NODE_VARNAME) or return;
    my $name = $vn->{text};
    my $node = $self->_emit({ kind => 'field', name => $name,
        qualified_name => qualify($pkg->{qualified_name}, $name),
        start_line => $n->{sl}, end_line => $n->{el},
        visibility => ($name =~ /^_/ ? 'private' : 'public') });
    $self->_edge($pkg->{id}, $node->{id}, 'contains');
    # `:reader` / `:accessor` / `:mutator` generate a getter method (named after the
    # field, or `:reader(custom)` -> custom) so `$self->x` resolves statically.
    my ($attrlist) = grep { $_->{type} eq 'attrlist' } @{ $n->{children} };
    my @attrs = $attrlist ? grep { $_->{type} eq NODE_ATTRIBUTE } @{ $attrlist->{children} } : ();
    # `:isa(Class)` gives any generated getter a return type (so `$self->x->m` chains).
    my $returns;
    for my $a (@attrs) {
        my $an = $a->{fields}{ +F_NAME } or next;
        next unless ($an->{text} // '') eq 'isa';
        my $v = $a->{fields}{ +F_VALUE } or next;
        $returns = _attr_value($v); last;
    }
    for my $a (@attrs) {
        my $an = $a->{fields}{ +F_NAME } or next;
        next unless $FIELD_ACCESSOR{ $an->{text} };
        my $acc = $name;
        if (my $v = $a->{fields}{ +F_VALUE }) { (my $t = $v->{text}) =~ s/\A\s+|\s+\z//g; $acc = $t if length $t }
        $self->_emit_accessor($pkg, $acc, $n, $returns);
    }
}

sub _handle_sub ($self, $n) {
    my $nm = $n->{fields}{ +F_NAME } or return undef;
    my $name = $nm->{text};
    my $pkg  = $self->{_pkg};
    my $pkgq = $pkg ? $pkg->{qualified_name} : 'main';
    my $sig;
    for my $c (@{ $n->{children} }) { $sig = $c->{text}, last if $c->{type} eq 'signature' }
    my $cx = $self->_complexity($n);
    my %meta;
    $meta{complexity} = $cx if $cx > 1;                         # omit the trivial cx=1
    if (my $r = $self->_return_class($n)) { $meta{returns} = $r }   # a `Class->new` builder
    if (my $dup = $self->_body_fingerprint($n)) { $meta{dup} = $dup }  # structural clone fingerprint
    if (my $ts = _taint_source(_decomment($n))) { $meta{taint_source} = $ts }  # reads external input ($ENV/@ARGV/STDIN)
    my ($tflow, $sink_params, $taint_out) = _value_flow($n);   # intra flow + inter-procedural facts
    $meta{taint_flow}  = 1            if $tflow;              # a tainted value reaches a sink ARG within this sub
    $meta{sink_params} = $sink_params if @$sink_params;      # parameter POSITIONS that reach a sink arg
    $meta{taint_out}   = $taint_out   if @$taint_out;        # per outgoing call: arg positions carrying a source / this sub's param
    my $snode = $self->_emit({
        kind           => ($n->{type} eq NODE_METHOD_DECL ? 'method' : 'function'),
        name           => $name,
        qualified_name => qualify($pkgq, $name),
        start_line     => $n->{sl}, end_line => $n->{el},
        signature      => $sig,
        visibility     => ($name =~ /^_/ ? 'private' : 'public'),
        (%meta ? (metadata => \%meta) : ()),
    });
    $self->_edge(($pkg ? $pkg->{id} : $self->{_file}{id}), $snode->{id}, 'contains');
    $snode->{_invocant} = _invocant_name($n);   # first sig param, stashed for _handle_method_call (transient; not stored)
    $self->_handle_catalyst($n, $snode);
    return $snode;
}

# A sub that reads EXTERNAL process input -- the non-web taint sources (CLI / env injection)
# that pcg_taint pairs with command/SQL sinks. Text scan over the sub's source (so it also
# catches reads inside nested closures); the label is shown to the user.
# The sub's source text with its comments removed -- so a `# reads $ENV{X}` note is not mistaken
# for a real read. Comments are separate tree-sitter nodes, so removing their exact text leaves
# code (including `#` inside strings/regexes) untouched, unlike a blanket `s/#.*//`.
sub _decomment ($node) {
    my $text = $node->{text} // '';
    my @stack = ($node);
    while (my $c = pop @stack) {
        if (($c->{type} // '') eq 'comment') { my $ct = $c->{text} // ''; $text =~ s/\Q$ct\E// if length $ct }
        else { push @stack, @{ $c->{children} // [] } }
    }
    return $text;
}

sub _taint_source ($text) {
    return undef unless defined $text;
    return '$ENV'  if $text =~ /\$ENV\s*\{/;                       # $ENV{PATH}
    return '@ARGV' if $text =~ /(?<!\w)\@ARGV\b/ || $text =~ /\$ARGV\s*\[/;   # @ARGV / $ARGV[0]
    return 'STDIN' if $text =~ /<\s*(?:STDIN|ARGV)?\s*>/;          # <STDIN> / <> / <ARGV>
    return undef;
}

# Any taint SOURCE expression -- the external reads above plus web request accessors.
my $TAINT_SOURCE_RX = qr/\$ENV\s*\{|(?<!\w)\@ARGV\b|\$ARGV\s*\[|<\s*(?:STDIN|ARGV)?\s*>
    |(?:->\s*|\b)(?:param|params|cookies?|uploads?|headers?|query_parameters|body_parameters|route_parameters)\s*\(/x;

# Intra-procedural VALUE-FLOW: does a tainted value actually reach a command/SQL sink's
# ARGUMENT inside this one sub? (vs. pcg_taint's default, which only proves the sub both reads
# input AND has a sink -- they might be unrelated.) Heuristic forward taint over the sub's
# assignments: a var assigned from a source is tainted; taint propagates through later
# assignments that mention it; the answer is whether a sink call's argument mentions a tainted
# var (or a source directly). A `local` hit with this set is value-flow-confirmed, not just co-located.
sub _value_flow ($sub) {
    my (@assign, @sink_arg, @call);
    my @stack = ($sub);
    while (my $n = pop @stack) {
        my $t = $n->{type} // '';
        if ($t eq 'assignment_expression') {
            my @k = @{ $n->{children} // [] };
            my ($lhs) = grep { ($_->{type} // '') =~ /variable_declaration|\Ascalar\z|\Aarray\z|\Ahash\z/ } @k;
            my $rhs = $k[-1];
            push @assign, [ [ ($lhs->{text} // '') =~ /([\$\@%]\w+)/g ], $rhs->{text} // '' ]
                if $lhs && $rhs && $rhs != $lhs;
        }
        elsif ($t =~ /function_call_expression|method_call_expression/) {
            my $f = $n->{fields}{ +F_FUNCTION } // $n->{fields}{ +F_METHOD };
            my $nm = $f ? (split /::/, ($f->{text} // ''))[-1] : '';
            my $is_m = $t =~ /method/ ? 1 : 0;
            my $args = ($n->{fields}{ +F_ARGUMENTS } // {})->{text} // '';
            if    (defined sink_type($nm, $is_m)) { push @sink_arg, $args }
            elsif (length $nm)                    { push @call, { callee => $nm, method => $is_m, args => [ _split_args($args) ] } }
        }
        push @stack, @{ $n->{children} // [] };
    }
    return (0, [], []) unless @sink_arg || @call;
    my $hit = sub ($text, $set) { grep { $text =~ /\Q$_\E\b/ } keys %$set };   # a tainted var appears in $text
    # (1) taint_flow: a SOURCE-tainted value reaches a sink argument WITHIN this sub (intra-procedural).
    my %src_seed; for my $a (grep { $_->[1] =~ $TAINT_SOURCE_RX } @assign) { $src_seed{$_} = 1 for @{ $a->[0] } }
    my $src_set = _tainted_set(\@assign, \%src_seed);
    my $flow = (grep { $_ =~ $TAINT_SOURCE_RX } @sink_arg) || (grep { $hit->($_, $src_set) } @sink_arg) ? 1 : 0;
    # (2) INTER-procedural facts. sink_params: which parameter POSITIONS reach a sink argument.
    # taint_out: per outgoing call, which arg positions carry a source (src) or one of this sub's
    # parameters (param) -- so the query can propagate taint arg->param along a call path.
    my @params = _sig_params($sub);
    my (@sink_params, @taint_out);
    for my $i (0 .. $#params) {
        my $pset = _tainted_set(\@assign, { $params[$i] => 1 });
        push @sink_params, $i + 1 if grep { $hit->($_, $pset) } @sink_arg;
        for my $c (@call) {
            for my $j (0 .. $#{ $c->{args} }) {
                push @taint_out, { callee => $c->{callee}, method => $c->{method}, arg => $j + 1, param => $i + 1 }
                    if $hit->($c->{args}[$j], $pset);
            }
        }
    }
    for my $c (@call) {                                            # a SOURCE passed into a call arg (the inter-proc seed)
        for my $j (0 .. $#{ $c->{args} }) {
            push @taint_out, { callee => $c->{callee}, method => $c->{method}, arg => $j + 1, src => 1 }
                if $c->{args}[$j] =~ $TAINT_SOURCE_RX || $hit->($c->{args}[$j], $src_set);
        }
    }
    return ($flow, \@sink_params, \@taint_out);
}

# All signature parameter names of a sub (`sub m ($a, $b, @rest)` -> $a,$b,@rest), in order.
sub _sig_params ($sub) {
    my ($sig) = grep { ($_->{type} // '') eq 'signature' } @{ $sub->{children} // [] };
    return $sig ? (($sig->{text} // '') =~ /([\$\@%]\w+)/g) : ();
}

# Forward-taint fixed point: seed the tainted set, propagate through assignments (a var whose RHS
# mentions a tainted var becomes tainted -- over-taints, the safe direction), return the full set.
sub _tainted_set ($assign, $seed) {
    my %t = %$seed;
    my $changed = 1;
    while ($changed) {
        $changed = 0;
        for my $a (@$assign) {
            next unless grep { !$t{$_} } @{ $a->[0] };
            next unless grep { $a->[1] =~ /\Q$_\E\b/ } keys %t;
            $t{$_} = 1, $changed = 1 for @{ $a->[0] };
        }
    }
    return \%t;
}

# Split a call's argument text on TOP-LEVEL commas into positional args -- bracket-depth AND
# quote aware (with backslash-escape parity), so a comma inside a bracketed sub-expression
# `foo(1,2)`, a bracket-delimited `qq{...}`/`qq(...)`, or a quoted string `"SELECT a, b"` (which
# SQL/command sink args routinely contain) is not a split point. HEURISTIC gap: a bare `'`/`"`
# inside a regex / quote-op literal (`/'/`, `m!...!`, `tr/'/'/`, a non-bracket `qq/.../`) is not
# recognized as pattern text and can mis-split that arg -- acceptable for a taint tier the tool
# already frames as "verify", and rare in real sink args (usually a plain `$var` / `"...$x..."`).
sub _split_args ($str) {
    my @out; my $buf = ''; my $depth = 0; my $q = '';   # $q = the open quote char, '' when not in a string
    my @ch = split //, $str;
    for my $i (0 .. $#ch) {
        my $c = $ch[$i];
        if ($q) {                                        # inside a string: append; a matching quote closes it,
            $buf .= $c;                                   # but only when UNESCAPED -- an even run (incl. 0) of
            if ($c eq $q) {                               # immediately-preceding backslashes means not escaped
                my $bs = 0; $bs++ while $i - 1 - $bs >= 0 && $ch[$i - 1 - $bs] eq '\\';
                $q = '' unless $bs % 2;
            }
        }
        elsif ($c eq "'" || $c eq '"')      { $q = $c;    $buf .= $c }
        elsif ($c =~ /[(\[{]/)              { $depth++;   $buf .= $c }
        elsif ($c =~ /[)\]}]/)              { $depth--;   $buf .= $c }
        elsif ($c eq ',' && $depth == 0)    { push @out, $buf; $buf = '' }
        else                                {             $buf .= $c }
    }
    push @out, $buf if length $buf;
    return @out;
}

# A structural fingerprint of a sub BODY for clone detection: the pre-order sequence
# of CST node TYPES (leaf text -- identifiers and literals -- ignored), so two subs
# with the same shape but different names/values (type-1 and type-2 clones) hash the
# same. Returns "<node-count>:<sha1>" for a non-trivial body, else undef. The count is
# stored in the key so a query can threshold on size without re-hashing.
sub _body_fingerprint ($self, $sub) {
    my ($block) = grep { ($_->{type} // '') eq NODE_BLOCK } @{ $sub->{children} // [] };
    return undef unless $block;
    my @types;
    my @stack = ($block);
    while (my $n = pop @stack) {
        push @types, $n->{type} // '';
        push @stack, reverse @{ $n->{children} // [] };          # pre-order, deterministic
    }
    return undef unless @types >= 12;                            # skip trivial bodies (getters / one-liners)
    return scalar(@types) . ':' . sha1_hex(join "\x1f", @types);
}

# Cyclomatic complexity of a sub: 1 + the decision points in its body (branches,
# loops, ternaries, short-circuit logical ops). A cheap CST node-type count.
sub _complexity ($self, $node) {
    my $c = 1;
    my @stack = ($node);
    while (my $n = shift @stack) {
        $c++ if $DECISION{ $n->{type} // '' };
        push @stack, @{ $n->{children} // [] };
    }
    return $c;
}

# Dancer2/Mojo::Lite: `get '/x' => sub {...}` -> route node + anon handler (scoped).
# Returns true if it consumed the call.
sub _handle_route ($self, $n, $cur_sub) {
    my $fn = $n->{fields}{ +F_FUNCTION } or return 0;
    my $verb = $fn->{text};
    return 0 unless $ROUTE_VERB{$verb};
    my $args = $n->{fields}{ +F_ARGUMENTS } or return 0;
    my $handler = $self->_find_descendant($args, NODE_ANON_SUB);   # inline handler (absent for render-shortcut routes)
    my $path    = $self->_route_path($args);
    # A route is `VERB PATH => sub {...}` or the handler-less render shortcut
    # (`get '/x' => {...}` / `=> 'template'`). Without a sub, require a literal
    # `/`-path so a bareword `get($url)` (e.g. LWP::Simple, which exports get/head)
    # isn't mistaken for a route.
    return 0 unless $handler || (defined $path && $path =~ m{^/});
    $path //= '?';

    my $pkg   = $self->{_pkg};
    my $owner = $pkg ? $pkg->{id} : $self->{_file}{id};
    my $pkgq  = $pkg ? $pkg->{qualified_name} : 'main';

    my $route = $self->_emit({ kind => 'route', name => "\U$verb\E $path",
        qualified_name => "$pkgq \U$verb\E $path", start_line => $n->{sl}, end_line => $n->{el},
        metadata => { provenance => 'framework', verb => uc $verb, path => $path } });
    $self->_edge($owner, $route->{id}, 'contains', provenance => 'framework');

    if ($handler) {
        my $hnode = $self->_emit({ kind => 'function', name => '__ANON__',
            qualified_name => "${pkgq}::__ANON__\@$handler->{sl}", start_line => $handler->{sl},
            end_line => $handler->{el}, visibility => 'private', metadata => { provenance => 'framework' } });
        $self->_edge($owner, $hnode->{id}, 'contains', provenance => 'framework');
        $self->_edge($route->{id}, $hnode->{id}, 'references', provenance => 'framework', metadata => { via => 'route' });

        # walk the handler body with the handler as current sub (its calls attribute to it)
        if (my $body = $handler->{fields}{ +F_BODY }) { $self->_walk($body, $hnode) }
    }
    return 1;
}

# The route path is the first top-level string argument BEFORE the handler sub
# (skips method arrays like `any ['get','post'] => '/x' => sub`, and avoids
# grabbing a string from inside the handler body).
sub _route_path ($self, $args) {
    for my $c (@{ $args->{children} }) {
        last if $c->{type} eq NODE_ANON_SUB;
        next unless $c->{type} eq NODE_INTERP_STRING || $c->{type} eq NODE_STRING_LIT;
        my $sc = $self->_find_descendant($c, NODE_STRING_CONTENT);
        return $sc->{text} if $sc;
    }
    return undef;
}

# Catalyst action: a sub carrying a routing attribute (:Path/:Local/:Chained/...).
sub _handle_catalyst ($self, $n, $snode) {
    my $attrs = $n->{fields}{ +F_ATTRIBUTES } or return;
    my (@routing, $path);
    for my $a (@{ $attrs->{children} }) {
        next unless $a->{type} eq NODE_ATTRIBUTE;
        my $aname = $a->{fields}{ +F_NAME } or next;
        next unless $CAT_ATTR{ $aname->{text} };
        push @routing, $aname->{text};
        if ($aname->{text} eq 'Path' && (my $v = $a->{fields}{ +F_VALUE })) {
            my $t = _attr_value($v);
            $path //= $t if length $t;
        }
    }
    return unless @routing;
    $path //= '/' . $snode->{name};
    my $pkg  = $self->{_pkg};
    my $pkgq = $pkg ? $pkg->{qualified_name} : 'main';
    my $route = $self->_emit({ kind => 'route', name => $path, qualified_name => "$pkgq route $path",
        start_line => $n->{sl}, end_line => $n->{el},
        metadata => { provenance => 'framework', framework => 'catalyst', attrs => \@routing, path => $path } });
    $self->_edge(($pkg ? $pkg->{id} : $self->{_file}{id}), $route->{id}, 'contains', provenance => 'framework');
    $self->_edge($route->{id}, $snode->{id}, 'references', provenance => 'framework', metadata => { via => 'route' });
}

sub _handle_use ($self, $n) {
    my $mod = $n->{fields}{ +F_MODULE } or return;
    my $module = $mod->{text};
    # framework/moosey are tracked per-package (with a file-level fallback for
    # `use Moo; package Foo;`), so they don't leak into a later package in the same file.
    if (my $fw = $FRAMEWORK{$module}) {
        if ($self->{_pkg}) { $self->{_pkg}{_framework} //= $fw } else { $self->{_framework_file} //= $fw }
    }
    if ($MOOSEY{$module}) {
        if ($self->{_pkg}) { $self->{_pkg}{_moosey} = 1 } else { $self->{_moosey_file} = 1 }
        $self->{_pkg}{_is_role} = 1 if $self->{_pkg} && $module =~ /::Role\z/;   # Moo/Moose/Mouse::Role
    }
    $self->{_pkg}{_is_role} = 1 if $self->{_pkg} && $module eq 'Role::Tiny';     # Role::Tiny role declaration
    # `use constant FOO => ...` / `use constant { A => 1, B => 2 }` define callable
    # symbols -> constant nodes (not an import).
    if ($module eq 'constant') {
        $self->_handle_constant($n);
    }
    # inheritance declared via `use`: parent / base, and Mojolicious's
    # `use Mojo::Base 'Parent'` (the canonical Mojo controller/model idiom).
    elsif ($module eq 'parent' || $module eq 'base' || $module eq 'Mojo::Base') {
        my @bases;
        $self->_collect_strings($n, \@bases);
        # `use Mojo::Base -role` -- the -role flag isn't collected as a plain string, so read it
        # off the statement text (the canonical Mojolicious role declaration).
        $self->{_pkg}{_is_role} = 1 if $self->{_pkg} && $module eq 'Mojo::Base' && ($n->{text} // '') =~ /(?<![\w-])-role\b/;
        my $via = $module eq 'Mojo::Base' ? 'mojo_base' : 'parent';
        for my $base (@bases) {
            next if $base =~ /^-/;                       # -norequire / -base / -role / -signatures
            $self->_edge($self->_src_id, undef, 'extends', metadata => { via => $via, name => $base });
        }
        # Mojo::Base always declares a class, even `use Mojo::Base -base;` (no parent).
        $self->{_pkg}{_is_class} = 1 if $self->{_pkg} && ($module eq 'Mojo::Base' || @bases);
        # Mojo::Base classes declare attributes with `has` (always a rw accessor
        # named after the attribute; the optional 2nd arg is a default, not options).
        if ($module eq 'Mojo::Base') {
            if ($self->{_pkg}) { $self->{_pkg}{_mojo} = 1 } else { $self->{_mojo_file} = 1 }
        }
    }
    elsif (my $kind = $ACCESSOR_USE{$module}) {       # accessor-generator: emit the accessor methods + record the import
        $self->_handle_accessor_use($n, $kind);
        $self->_edge($self->_src_id, undef, 'imports', metadata => { via => 'use', module => $module });
    }
    elsif (!$PRAGMA{$module}) {
        # record the explicitly-imported symbols (`use Foo qw(a b)` / `use Foo 'a'`)
        # so the resolver can resolve a later bareword `a()` to Foo::a in this scope.
        my @syms; $self->_collect_strings($n, \@syms);
        $self->_edge($self->_src_id, undef, 'imports',
            metadata => { via => 'use', module => $module, (@syms ? (symbols => \@syms) : ()) });
    }
}

# `use constant FOO => ...` / `use constant { A => 1, B => 2 }` -> constant nodes.
# Hash form: every bareword key is a name. List form (`NAME => VALUE`): only the
# FIRST key is the name (the rest is the value). _constant_keys collects only true
# keys (a bareword before `=>`) and prunes value hashref/arrayref subtrees, so
# neither a value hashref's keys (`MAP => { x => 1 }`) nor a `$ENV{KEY}` subscript
# become phantom constants.
sub _handle_constant ($self, $n) {
    my $pkg  = $self->{_pkg};
    my $pkgq = $pkg ? $pkg->{qualified_name} : 'main';
    my ($hash) = grep { $_->{type} eq 'anonymous_hash_expression' } @{ $n->{children} };
    my @names; $self->_constant_keys($hash // $n, \@names);
    @names = @names[0 .. 0] if !$hash && @names;     # list form names only the first key
    for my $name (@names) {
        my $node = $self->_emit({ kind => 'constant', name => $name,
            qualified_name => qualify($pkgq, $name), start_line => $n->{sl}, end_line => $n->{el},
            visibility => ($name =~ /^_/ ? 'private' : 'public') });
        $self->_edge(($pkg ? $pkg->{id} : $self->{_file}{id}), $node->{id}, 'contains');
    }
}

# Bareword keys (an autoquoted_bareword immediately before `=>`), recursing through
# the spec (the list right-nests, so subsequent pairs are nested) but NEVER into a
# value hashref/arrayref -- their keys are data, not constant names. A subscript
# key like `$ENV{KEY}` isn't collected either (it's not before a `=>`).
sub _constant_keys ($self, $node, $acc) {
    my @kids = @{ $node->{children} };
    for my $i (0 .. $#kids) {
        my $c = $kids[$i];
        push @$acc, $c->{text}
            if $c->{type} eq 'autoquoted_bareword' && $i < $#kids && ($kids[$i + 1]{type} // '') eq '=>';
        next if $c->{type} eq 'anonymous_hash_expression' || $c->{type} eq 'anonymous_array_expression';
        $self->_constant_keys($c, $acc);
    }
}

sub _handle_require ($self, $n) {
    for my $c (@{ $n->{children} }) {
        if ($c->{type} eq NODE_PACKAGE_NAME || $c->{type} eq NODE_BAREWORD) {
            $self->_edge($self->_src_id, undef, 'imports', metadata => { via => 'require', module => $c->{text} });
            return;
        }
    }
}

sub _handle_assign ($self, $n) {
    my $left = $n->{fields}{ +F_LEFT } or return;
    $self->_infer_var_type($left, $n->{fields}{ +F_RIGHT });   # `my $x = Class->new` -> remember $x : Class
    my $pkg  = $self->{_pkg} or return;
    # Require an array (@-sigil) container, so a scalar like `my $ISA = ...` is
    # NOT mistaken for @ISA / @EXPORT.
    my $arr  = $self->_find_descendant($left, 'array') or return;
    my $var  = $self->_find_descendant($arr, NODE_VARNAME) or return;
    my $vname = $var->{text};
    return unless $vname eq 'ISA' || $vname eq 'EXPORT' || $vname eq 'EXPORT_OK';

    my @vals;
    $self->_collect_strings($n, \@vals);
    if ($vname eq 'ISA') {
        $self->_edge($pkg->{id}, undef, 'extends', metadata => { via => 'isa', name => $_ }) for @vals;
        $pkg->{_is_class} = 1 if @vals;
    }
    else {  # EXPORT / EXPORT_OK
        $self->_exports->{$_} = 1 for @vals;
    }
}

# Local type inference: `my $x = Class->new(...)` -> remember the lexical's class
# in the current sub's scope, so a later `$x->method` resolves against Class's MRO
# (deterministic, not a guess). Only the literal-class `->new` constructor idiom
# (high precision); the scope is reset per sub by `local $self->{_vartype}`.
# The class of a `Class->new(...)` literal-constructor expression, or undef.
sub _constructor_class ($self, $node) {
    return undef unless $node && ($node->{type} // '') eq NODE_METHOD_CALL;
    my $m = $node->{fields}{ +F_METHOD } or return undef;
    return undef unless ($m->{text} // '') eq 'new';            # constructor convention
    my $inv = $node->{fields}{ +F_INVOCANT } or return undef;
    my $c = $inv->{text} // '';
    return $c =~ /\A\w+(?:::\w+)*\z/ ? $c : undef;              # a literal class, not a $var/expr
}

# The function name of a bareword-call expression `foo(...)` (a deferred type: $x's
# class is foo's return type, resolved interprocedurally), or undef.
sub _call_name ($self, $node) {
    return undef unless $node && ($node->{type} // '') eq NODE_CALL;
    my $fn = $node->{fields}{ +F_FUNCTION } or return undef;
    my $name = $fn->{text} // '';
    return $name =~ /\A\w+(?:::\w+)*\z/ ? $name : undef;
}

sub _infer_var_type ($self, $left, $right) {
    # only a plain `$x` / `my $x` lvalue -- NOT an element/field/deref assignment like
    # `$self->{parser} = Class->new` or `$a[0] = ...` (those type the SLOT, never the base
    # variable; typing `$self` from them mis-resolves every later `$self->method`).
    return if ($left->{text} // '') =~ /->|[\[{]/;
    my @scalars = $self->_descendants($left, 'scalar');
    return unless @scalars == 1;                                 # a single `my $x` (skip `my ($a,$b)` / arrays)
    my $vn = $self->_find_descendant($scalars[0], NODE_VARNAME) or return;
    if (my $cls = $self->_constructor_class($right)) {          # my $x = Class->new -> $x : Class
        ($self->{_vartype} //= {})->{ '$' . $vn->{text} } = $cls;
    }
    elsif (my $fn = $self->_call_name($right)) {                # my $x = foo() -> $x : (return type of foo)
        ($self->{_vartype} //= {})->{ '$' . $vn->{text} } = { call => $fn };
    }
}

# The return type of a sub when it's a `Class->new` builder: the class of every
# `return Class->new` plus the implicit-return last statement, if they all agree.
sub _return_class ($self, $sub) {
    my ($block) = grep { ($_->{type} // '') eq NODE_BLOCK } @{ $sub->{children} // [] };
    return undef unless $block;
    my %cls;
    # explicit `return Class->new` anywhere in the body (statements are wrapped
    # in expression_statement; the constructor sits under a return_expression)
    for my $re ($self->_descendants($block, 'return_expression')) {
        my ($mc) = grep { ($_->{type} // '') eq NODE_METHOD_CALL } @{ $re->{children} // [] };
        my $c = $self->_constructor_class($mc); $cls{$c}++ if defined $c;
    }
    # implicit return: the last meaningful statement's top expression is Class->new
    my @stmts = grep { ($_->{type} // '') !~ /\A[{}();,;]\z/ } @{ $block->{children} // [] };
    if (my $last = $stmts[-1]) {
        my $expr = ($last->{type} // '') eq NODE_METHOD_CALL ? $last
                 : (grep { ($_->{type} // '') eq NODE_METHOD_CALL } @{ $last->{children} // [] })[0];
        my $c = $self->_constructor_class($expr); $cls{$c}++ if defined $c;
    }
    my @c = keys %cls;
    return @c == 1 ? $c[0] : undef;                              # only when unambiguous
}

sub _descendants ($self, $node, $type) {
    my @out;
    my @stack = ($node);
    while (my $n = shift @stack) {
        push @out, $n if ($n->{type} // '') eq $type;
        push @stack, @{ $n->{children} // [] };
    }
    return @out;
}

# Gather string values from a subtree: string_literal contents, and qw(...) words.
sub _collect_strings ($self, $node, $acc) {
    if ($node->{type} eq NODE_QW) {
        my $c = $node->{fields}{ +F_CONTENT };
        push @$acc, split ' ', $c->{text} if $c;
        return;
    }
    if ($node->{type} eq NODE_STRING_CONTENT) {
        push @$acc, $node->{text};
        return;
    }
    $self->_collect_strings($_, $acc) for @{ $node->{children} };
}

sub _find_descendant ($self, $node, $type) {
    return $node if $node->{type} eq $type;
    for my $c (@{ $node->{children} }) {
        my $f = $self->_find_descendant($c, $type);
        return $f if $f;
    }
    return undef;
}

# Moo/Moose `with 'Role::A', 'Role::B'` -> implements edges and `extends 'Base'`
# -> extends edges (both resolved by name, like @ISA), so composed roles AND
# declared parents feed _mro and `$self->method` resolution. Modern OO declares
# inheritance with `extends`, not `our @ISA`. Option containers
# (`with 'R' => { -alias => {...} }`) are skipped. Returns true if consumed.
sub _handle_isa_fn ($self, $n, $fname, $kind) {
    my $fn = $n->{fields}{ +F_FUNCTION } or return 0;
    return 0 unless ($fn->{text} // '') eq $fname;
    my $pkg = $self->{_pkg} or return 0;
    my @strs; $self->_role_names($n, \@strs);
    my @names = grep { /\A\w+(?:::\w+)*\z/ } @strs;   # package-shaped only (skip -alias / option strings)
    return 0 unless @names;
    $self->_edge($pkg->{id}, undef, $kind, metadata => { via => $fname, name => $_ }) for @names;
    $pkg->{_is_class} = 1;
    return 1;
}

# Like _collect_strings, but never descends into anonymous hash/array refs -- the
# role-options containers (`with 'Role' => { -alias => { m => 'n' } }`), whose
# inner strings (method names) must NOT be mistaken for role names.
sub _role_names ($self, $node, $acc) {
    my $t = $node->{type};
    return if $t eq 'anonymous_hash_expression' || $t eq 'anonymous_array_expression';
    if ($t eq NODE_QW)             { my $c = $node->{fields}{ +F_CONTENT }; push @$acc, split ' ', $c->{text} if $c; return }
    if ($t eq NODE_STRING_CONTENT) { push @$acc, $node->{text}; return }
    $self->_role_names($_, $acc) for @{ $node->{children} };
}

# `has 'x' => (...)` -> accessor method node(s), so `$self->x` resolves statically.
# Moo/Moose: honors reader/writer/accessor renames and `is => 'bare'` so we never
# emit an accessor that doesn't exist (the runtime MOP pass also finds these, as
# `mop`). Mojo::Base: always a rw accessor named after the attribute.
sub _handle_has ($self, $n) {
    my $fn = $n->{fields}{ +F_FUNCTION } or return 0;
    return 0 unless ($fn->{text} // '') eq 'has';
    my $pkg  = $self->{_pkg} or return 0;
    my $args = $n->{fields}{ +F_ARGUMENTS } or return 0;
    # `has 'x'` / `has [qw(a b)]` pass the attribute spec directly; `has x => (...)`
    # / `has x => $default` wrap the args in a list_expression (spec is child 0).
    my $list  = ($args->{type} // '') eq 'list_expression';
    my @attrs = $self->_has_names($list ? $args->{children}[0] : $args) or return 0;
    # Mojo::Base `has` always generates a rw accessor named after each attribute
    # (no is/reader/writer -- the optional 2nd arg is a default value).
    if ($self->_mojo_now) {
        $self->_emit_accessor($pkg, $_, $n) for grep { /\A\w+\z/ } @attrs;
        $pkg->{_is_class} = 1;
        return 1;
    }
    my %opt    = $self->_has_options($list ? $args->{children} : []);
    my $single = @attrs == 1;        # reader/writer/accessor renames apply to a single attribute only
    for my $attr (@attrs) {
        next unless $attr =~ /\A\w+\z/;
        my @acc;
        if    ($single && defined $opt{accessor}) { @acc = ($opt{accessor}) }
        elsif ($single && defined $opt{reader})   { @acc = ($opt{reader}) }
        elsif (defined $opt{is} && $opt{is} ne 'bare') { @acc = ($attr) }   # default accessor = attribute name (needs an `is`)
        push @acc, $opt{writer} if $single && defined $opt{writer};
        push @acc, "_set_$attr" if ($opt{is} // '') eq 'rwp';              # Moo `is => 'rwp'` -> private writer _set_<attr>
        $self->_emit_accessor($pkg, $_, $n, $opt{isa}) for grep { defined && /\A\w+\z/ } @acc;
    }
    $pkg->{_is_class} = 1;
    return 1;
}

# attribute name(s) from `has`'s first argument: a string, an autoquoted bareword,
# or an array ref of them (`has [qw(a b)] => ...`).
sub _has_names ($self, $spec) {
    return () unless $spec;
    my $t = $spec->{type};
    return ($spec->{text}) if $t eq 'autoquoted_bareword';
    if ($t eq NODE_STRING_LIT || $t eq NODE_INTERP_STRING) {
        my $sc = $self->_find_descendant($spec, NODE_STRING_CONTENT);
        return $sc ? ($sc->{text}) : ();
    }
    if ($t eq 'anonymous_array_expression') { my @n; $self->_collect_strings($spec, \@n); return @n }
    return ();
}

# accessor-naming options (is / reader / writer / accessor) -> their string values.
sub _has_options ($self, $kids) { my %o; $self->_scan_opts($_, \%o) for @$kids; return %o }
sub _scan_opts ($self, $node, $opt) {
    # never mine option pairs out of a VALUE container -- a default/builder sub or
    # a hashref/arrayref default can contain `accessor => '...'` that is not a has
    # option (real has-options are flat in the argument list).
    return if $node->{type} eq NODE_ANON_SUB
           || $node->{type} eq 'anonymous_hash_expression'
           || $node->{type} eq 'anonymous_array_expression';
    my @c = @{ $node->{children} // [] };
    for my $i (0 .. $#c) {
        my $key = $self->_word($c[$i]) // next;
        next unless $key =~ /\A(?:is|reader|writer|accessor|isa)\z/;   # isa => 'Class' gives the accessor a return type
        next unless $i < $#c && (($c[$i+1]{text} // '') eq '=>');
        my $val = $self->_word($c[$i+2]) // next;
        $opt->{$key} //= $val;
    }
    $self->_scan_opts($_, $opt) for @c;
}
# literal value of a string-literal / autoquoted-bareword node, else undef
sub _word ($self, $node) {
    return undef unless $node;
    my $t = $node->{type};
    return $node->{text} if $t eq 'autoquoted_bareword';
    if ($t eq NODE_STRING_LIT || $t eq NODE_INTERP_STRING) {
        my $sc = $self->_find_descendant($node, NODE_STRING_CONTENT);
        return $sc ? $sc->{text} : undef;
    }
    return undef;
}

sub _emit_accessor ($self, $pkg, $name, $n, $returns = undef) {
    my %meta = (accessor => 1);
    $meta{returns} = $returns if defined $returns && $returns =~ /\A\w+(?:::\w+)*\z/;   # a literal class -> getter return type
    my $node = $self->_emit({ kind => 'method', name => $name,
        qualified_name => qualify($pkg->{qualified_name}, $name),
        start_line => $n->{sl}, end_line => $n->{el},
        visibility => ($name =~ /^_/ ? 'private' : 'public'),
        metadata => \%meta });
    $self->_edge($pkg->{id}, $node->{id}, 'contains');
    return $node;
}

# `use Class::Tiny qw(a b)` / `use Class::XSAccessor getters => {m=>f}, accessors => [qw/x y/]`
# -> accessor methods. `list`: the imported strings ARE the names. `xs`: the names are the KEYS
# of each option hash (left of `=>`) and the elements of each option array.
sub _handle_accessor_use ($self, $n, $kind) {
    my $pkg = $self->{_pkg} or return;
    my @names;
    if ($kind eq 'list') {
        # `use Class::Tiny qw(a b)` -- the list elements ARE the names; `use Class::Tiny { a => $def }`
        # (Class::Tiny's hash-default form) -- the KEYS are the names, the string defaults are NOT. So
        # collect qw/string list elements + hash keys, but do not descend into hash VALUES.
        my @stack = ($n);
        while (my $x = pop @stack) {
            my $t = $x->{type} // '';
            if    ($t eq 'anonymous_hash_expression') { _keys_before_fatcomma($x, \@names) }
            elsif ($t eq NODE_QW)             { my $c = $x->{fields}{ +F_CONTENT }; push @names, split ' ', $c->{text} if $c }
            elsif ($t eq NODE_STRING_CONTENT) { push @names, $x->{text} }
            else  { push @stack, @{ $x->{children} // [] } }
        }
    }
    else {
        my @stack = ($n);
        while (my $x = pop @stack) {
            my $t = $x->{type} // '';
            if    ($t eq 'anonymous_hash_expression')  { _keys_before_fatcomma($x, \@names) }
            elsif ($t eq 'anonymous_array_expression') { $self->_collect_strings($x, \@names) }
            push @stack, @{ $x->{children} // [] };
        }
        @names = grep { !$XS_OPTION{$_} } @names;                  # drop option keywords the hashref-wrapper form collects
    }
    my %seen;
    $self->_emit_accessor($pkg, $_, $n) for grep { /\A\w+\z/ && !$seen{$_}++ } @names;
    $pkg->{_is_class} = 1 if @names;
}

# Hash keys = each token immediately followed by a `=>` sibling, recursively (Perl flattens
# `a => b, c => d` into nested lists, so the keys can appear at any depth).
sub _keys_before_fatcomma ($node, $acc) {
    my @kids = @{ $node->{children} // [] };
    for my $i (0 .. $#kids) {
        if ((($kids[$i + 1] // {})->{type} // '') eq '=>') {
            (my $name = $kids[$i]{text} // '') =~ s/\A['"]|['"]\z//g;
            push @$acc, $name;
        }
        _keys_before_fatcomma($kids[$i], $acc);
    }
}

# Mojolicious helper registration: `helper name => sub {...}` or
# `$app->helper(name => sub {...})`. A helper is callable as `$c->name` on any
# controller, so it becomes a method node the resolver matches by name (framework
# provenance). Only simple (non-dotted) helper names are handled.
sub _handle_helper ($self, $n) {
    my $kw = $n->{fields}{ +F_FUNCTION } // $n->{fields}{ +F_METHOD };
    return 0 unless $kw && ($kw->{text} // '') eq 'helper';
    my $args = $n->{fields}{ +F_ARGUMENTS } or return 0;
    my $name = $self->_method_arg($args);
    return 0 unless defined $name && $name =~ /\A\w+\z/;
    my $handler = $self->_find_descendant($args, NODE_ANON_SUB);
    my $pkg  = $self->{_pkg};
    my $pkgq = $pkg ? $pkg->{qualified_name} : 'main';
    my $node = $self->_emit({ kind => 'method', name => $name,
        qualified_name => qualify($pkgq, $name),
        start_line => ($handler // $n)->{sl}, end_line => ($handler // $n)->{el},
        metadata => { provenance => 'framework', helper => 1 } });
    $self->_edge(($pkg ? $pkg->{id} : $self->{_file}{id}), $node->{id}, 'contains', provenance => 'framework');
    if ($handler && (my $body = $handler->{fields}{ +F_BODY })) { $self->_walk($body, $node) }
    return 1;
}

sub _handle_modifier ($self, $n, $cur_sub) {
    my $fn = $n->{fields}{ +F_FUNCTION } or return 0;
    my $type = $fn->{text};
    return 0 unless $MODIFIER{$type};
    my $args = $n->{fields}{ +F_ARGUMENTS } or return 0;
    my $handler = $self->_find_descendant($args, NODE_ANON_SUB) or return 0;
    my $meth = $self->_method_arg($args);
    return 0 unless defined $meth && length $meth;

    my $pkg   = $self->{_pkg};
    my $pkgq  = $pkg ? $pkg->{qualified_name} : 'main';
    my $owner = $pkg ? $pkg->{id} : $self->{_file}{id};
    my $mod = $self->_emit({ kind => 'method', name => "__${type}__", visibility => 'private',
        qualified_name => "${pkgq}::__${type}_${meth}\@$n->{sl}",
        start_line => $handler->{sl}, end_line => $handler->{el},
        metadata => { provenance => 'framework', modifier => $type } });
    $self->_edge($owner, $mod->{id}, 'contains', provenance => 'framework');
    $self->_edge($mod->{id}, undef, 'overrides', provenance => 'framework',
        metadata => { via => 'modifier', modifier => $type, name => qualify($pkgq, $meth) });
    if (my $body = $handler->{fields}{ +F_BODY }) { $self->_walk($body, $mod) }
    return 1;
}

# The first method-name argument (string or autoquoted bareword) before the handler sub.
sub _method_arg ($self, $args) {
    for my $c (@{ $args->{children} }) {
        last if $c->{type} eq NODE_ANON_SUB;
        if ($c->{type} eq NODE_INTERP_STRING || $c->{type} eq NODE_STRING_LIT) {
            my $sc = $self->_find_descendant($c, NODE_STRING_CONTENT);
            return $sc->{text} if $sc;
        }
        return $c->{text} if $c->{type} eq 'autoquoted_bareword';
    }
    return undef;
}

sub _from_id ($self, $cur_sub) {
    return $cur_sub      ? $cur_sub->{id}
         : $self->{_pkg} ? $self->{_pkg}{id}
         :                 $self->{_file}{id};
}

sub _handle_call ($self, $n, $cur_sub) {
    my $fn = $n->{fields}{ +F_FUNCTION } or return;
    my $name = $fn->{text};
    return unless defined $name && length $name;
    push @{ $self->_refs }, {
        from_node_id   => $self->_from_id($cur_sub),
        reference_name => $name, reference_kind => 'call',
        line => $n->{sl}, col => $n->{sc}, file_path => $self->file_path,
    };
    $self->_edge($self->_from_id($cur_sub), undef, 'sink',
        metadata => { sink => $_, name => $name, dynamic => $self->_sink_dynamic($n->{fields}{ +F_ARGUMENTS }) })
        for grep { defined } sink_type($name, 0);   # command-execution sink
}

# Is a sink call's argument DYNAMICALLY constructed -- the injection-shaped pattern?
# True when the command/SQL string itself is built from a variable: an interpolated
# string embedding a $var, a concatenation, or a bare variable/expression as the string.
# A plain string literal (even with separate bind/list args) is parameterized/constant.
sub _sink_dynamic ($self, $args) {
    return 0 unless $args;
    my $first = ($args->{type} // '') eq 'list_expression'
        ? (grep { ($_->{type} // '') !~ /\A[[:punct:]]+\z/ } @{ $args->{children} // [] })[0]
        : $args;
    return 0 unless $first;
    my $t = $first->{type} // '';
    return 1 if $t =~ /\Ascalar\z|\Aarray\z|deref|binary_expression|ternary|method_call|function_call/;  # $sql / "..".$x / cond
    return 1 if $t =~ /string|heredoc/ && _has_interp_var($first);   # "...$x..."
    return 0;
}
sub _has_interp_var ($node) {
    return 1 if ($node->{type} // '') =~ /\Ascalar\z|\Aarray\z|scalar_deref|array_element|hash_element|hash_deref/;
    _has_interp_var($_) && return 1 for @{ $node->{children} // [] };
    return 0;
}

# \&name -> a code reference. Record it as a `references` ref so callback-wired
# subs (dispatch tables, sort comparators, event handlers) aren't seen as dead
# -- and so they surface in callers/impact. Only the literal \&name form (a
# direct varname child); \&$x / \&{...} are dynamic and skipped.
sub _handle_refgen ($self, $n, $cur_sub) {
    my $fn = $self->_find_descendant($n, NODE_FUNCTION) or return;
    my ($vn) = grep { $_->{type} eq NODE_VARNAME } @{ $fn->{children} };
    return unless $vn && defined $vn->{text} && length $vn->{text};
    push @{ $self->_refs }, {
        from_node_id   => $self->_from_id($cur_sub),
        reference_name => $vn->{text}, reference_kind => 'references',
        line => $n->{sl}, col => $n->{sc}, file_path => $self->file_path,
    };
}

# A sub whose first signature parameter is a CONVENTIONAL invocant name is (heuristically) a method,
# and that parameter is `$self`. We accept only the well-known spellings -- `$self`/`$class`/`$this` and
# Mojolicious's `$c` -- NOT any first parameter: a plain helper `sub _fmt ($thing, $opt) {...}` inside a
# class must NOT get `$thing` typed as an invocant just because the param happens to match a later
# `$thing->render` receiver. Returns the invocant var text (`$self`) or undef.
my %INVOCANT_PARAM = map { $_ => 1 } qw($self $class $this $c);
sub _invocant_name ($sub) {
    return undef unless $sub;
    my ($sig) = grep { ($_->{type} // '') eq 'signature' } @{ $sub->{children} // [] };
    return undef unless $sig && ($sig->{text} // '') =~ /\A\s*\(\s*(\$\w+)/;
    return $INVOCANT_PARAM{$1} ? $1 : undef;
}

sub _handle_method_call ($self, $n, $cur_sub) {
    my $m = $n->{fields}{ +F_METHOD } or return;
    my $meth = $m->{text};
    return unless defined $meth && length $meth;
    # `__PACKAGE__->mk_accessors(qw/a b/)` -> accessor methods. Only when the invocant is the CLASS
    # (__PACKAGE__, the current package name, or a Capitalized bareword) -- NOT `$obj->mk_accessors`
    # on a real instance / a same-named method on some other class, which would attach phantom
    # accessors here + swallow the call edge.
    if ($ACCESSOR_METHOD{$meth} && $self->{_pkg}) {
        my $inv = (($n->{fields}{ +F_INVOCANT }) // {})->{text} // '';
        if ($inv eq '__PACKAGE__' || $inv eq ($self->{_pkg}{name} // "\0") || $inv =~ /\A[A-Z][\w:]*\z/) {
            my @names;
            $self->_collect_strings($n->{fields}{ +F_ARGUMENTS }, \@names) if $n->{fields}{ +F_ARGUMENTS };
            my %seen;
            $self->_emit_accessor($self->{_pkg}, $_, $n) for grep { /\A\w+\z/ && !$seen{$_}++ } @names;
            if (@names) { $self->{_pkg}{_is_class} = 1; return }
        }
    }
    my $inv  = $n->{fields}{ +F_INVOCANT };
    my $recv = $inv ? $inv->{text} : undef;
    my %cand;
    $cand{receiver}      = $recv if defined $recv;
    # A method's FIRST signature parameter, when named a CONVENTIONAL invocant -- $self/$class/$this/$c,
    # see %INVOCANT_PARAM / _invocant_name -- IS the invocant: resolve `$c->method` against this OO class
    # exactly like `$self->method`. Mojolicious controllers use `sub action ($c) { $c->stash... }`, which
    # was otherwise fully opaque. (An arbitrarily-named first param, e.g. a helper's `$thing`, is NOT typed.)
    $cand{invocant} = 1 if defined $recv && $self->{_pkg} && $self->{_pkg}{_is_class}
                        && defined($cur_sub) && $recv eq ($cur_sub->{_invocant} // "\0");
    my $rtype = defined $recv ? ($self->{_vartype} // {})->{$recv} : undef;   # inferred via `my $recv = ...`
    if    (ref $rtype eq 'HASH' && $rtype->{call}) { $cand{receiver_call} = $rtype->{call} }   # my $recv = foo()
    elsif ($rtype)                                 { $cand{receiver_type} = $rtype }            # my $recv = Class->new
    # chained `BASE->attr->method`: type the inner BASE so the resolver can read
    # the intermediate accessor's declared return type (`has attr => isa => ...`).
    if ($inv && $inv->{type} eq NODE_METHOD_CALL) {
        my $bm = $inv->{fields}{ +F_METHOD };
        my $bi = $inv->{fields}{ +F_INVOCANT };
        my $bt = $bi ? ($bi->{text} // '') : '';
        if ($bm && length($bm->{text} // '') && length $bt) {
            my %ch = (method => $bm->{text});
            if    ($bt =~ /\A\$(?:self|class)\z/)            { $ch{base_self} = 1 }
            elsif ($bt =~ /\A\w+(?:::\w+)*\z/)               { $ch{base_type} = $bt }
            elsif (my $t = ($self->{_vartype} // {})->{$bt}) { $ch{base_type} = $t }
            $cand{chain} = \%ch if $ch{base_self} || $ch{base_type};
        }
    }
    # chained `func()->method`: the resolver reads func's inferred return type.
    elsif ($inv && ($inv->{type} // '') eq NODE_CALL) {
        my $fn = $inv->{fields}{ +F_FUNCTION }
              // (grep { ($_->{type} // '') eq NODE_FUNCTION } @{ $inv->{children} // [] })[0];
        $cand{chain} = { base_func => $fn->{text} }
            if $fn && ($fn->{text} // '') =~ /\A[\w:]+\z/;
    }
    push @{ $self->_refs }, {
        from_node_id   => $self->_from_id($cur_sub),
        reference_name => $meth, reference_kind => 'method_call',
        line => $n->{sl}, col => $n->{sc}, file_path => $self->file_path,
        candidates => (%cand ? \%cand : undef),
    };
    $self->_edge($self->_from_id($cur_sub), undef, 'sink',
        metadata => { sink => $_, name => $meth, dynamic => $self->_sink_dynamic($n->{fields}{ +F_ARGUMENTS }) })
        for grep { defined } sink_type($meth, 1);   # SQL-execution sink
}

sub _postprocess ($self) {
    for my $p (values %{ $self->_packages }) {
        $p->{kind} = 'class' if delete $p->{_is_class};
        ($p->{metadata} //= {})->{role} = 1 if delete $p->{_is_role};   # a role: composed into unknown consumers
    }
    if (my @ex = keys %{ $self->_exports }) {
        my %want = map { $_ => 1 } @ex;
        for my $node (@{ $self->_nodes }) {
            $node->{is_exported} = 1
                if $node->{kind} =~ /function|method|constant/ && $want{ $node->{name} };
        }
    }
    # attach POD docstrings (=head2/=item <name>) to matching subs/methods
    if (length $self->source) {
        my $pod = App::PerlGraph::Pod::extract($self->source);
        if (%$pod) {
            for my $node (@{ $self->_nodes }) {
                next unless $node->{kind} =~ /function|method/;
                $node->{docstring} //= $pod->{ $node->{name} };
            }
        }
    }
}

1;

__END__

=head1 NAME

App::PerlGraph::Extractor - walk a parse tree into graph nodes, edges and references

=head1 DESCRIPTION

Turns one file tree-sitter parse into package/class/sub/method/field/constant/route nodes plus call, reference and inheritance edges.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
