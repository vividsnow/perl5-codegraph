package App::PerlGraph::Resolver;
use v5.36;
our $VERSION = q{0.047};
use Moo;
use App::PerlGraph::Model qw(package_of qualify is_builtin is_external is_universal);

# Resolves the graph after extraction:
#  - fills target on null-target extends/imports edges (by matching their metadata name)
#  - resolves unresolved_refs (calls / method calls) to definition nodes
has store => (is => 'ro', required => 1);

sub resolve_all ($self) {
    $self->_resolve_named_edges;
    $self->_resolve_refs;
    $self->_apply_learned;   # re-apply past agent/LLM resolutions (survive reindex)
    return $self;
}

# Re-apply persisted agent/LLM resolutions: any still-unresolved method call whose
# (caller, method, receiver) was learned earlier resolves to the recorded target
# (provenance 'llm', so a later static/runtime resolution overrides it).
sub _apply_learned ($self) {
    my $s = $self->store;
    my @learned = $s->learned_resolutions or return;
    my %map = map { join("\x1f", @{$_}{qw(caller_qname method receiver)}) => $_->{target_qname} } @learned;
    for my $ref ($s->all_unresolved) {
        my ($caller, $method, $recv) = $s->ref_anchor($ref) or next;
        my $tq = $map{ join("\x1f", $caller, $method, $recv // '') } // next;
        my ($tn) = grep { ($_->{kind} // '') =~ /method|function/ } $s->nodes_by_qname($tq);
        $s->resolve_ref($ref->{id}, $tn->{id}, 'llm') if $tn;
    }
}

# extends/imports edges carry metadata { via, name } / { via, module }.
sub _resolve_named_edges ($self) {
    my $s = $self->store;
    for my $e ($s->null_target_edges('extends', 'imports', 'overrides', 'implements')) {
        my $m = $e->{metadata} || {};
        my $name = $m->{name} // $m->{module};
        next unless $name;
        my ($pkg) = $s->nodes_by_qname($name);
        next unless $pkg;
        $s->dbh->do('update edges set target = ? where id = ?', undef, $pkg->{id}, $e->{id});
    }
}

sub _resolve_refs ($self) {
    my $s = $self->store;
    for my $ref ($s->all_unresolved) {
        my $name = $ref->{reference_name};
        my $is_method = ($ref->{reference_kind} // '') eq 'method_call';
        # a bareword call to a builtin is noise to consume; but `$obj->print` is a
        # method, never the builtin -- so only consume builtins in call position.
        if (!$is_method && is_builtin($name)) { $self->_consume($ref->{id}); next }

        my ($target, $prov);
        if ($is_method) {
            ($target, $prov) = $self->_resolve_method($ref);
            # a Mojolicious helper is callable as `$c->name` on any controller, so
            # an otherwise-unresolved method call matching a registered helper
            # resolves to it (framework convention, not a proven call).
            if (!$target && (my $h = $self->_helper_index->{$name})) { ($target, $prov) = ($h, 'framework') }
            # $obj->can/isa/DOES/VERSION is a UNIVERSAL method, not a project gap.
            if (!$target && is_universal($name)) { $self->_consume($ref->{id}); next }
        } else {
            $target = $self->_resolve_call($ref);
            # a known-external call (Test::More, Carp, AE::*, List::Util, ...) that
            # didn't resolve is not a project gap -- consume it so it stops inflating
            # the unresolved count. Guard: keep a bare name unresolved if the project
            # actually defines it (could be the project's own, just not disambiguated).
            if (!$target && is_external($name) && ($name =~ /::/ || !$s->nodes_by_name($name))) {
                $self->_consume($ref->{id}); next;
            }
            $prov = 'static';
        }
        $s->resolve_ref($ref->{id}, $target->{id}, $prov // 'static') if $target;
        # else: leave the ref unresolved (a genuine static-analysis frontier)
    }
}

sub _consume ($self, $id) {
    $self->store->dbh->do('delete from unresolved_refs where id = ?', undef, $id);
}

sub _from_package ($self, $ref) {
    my $id = $ref->{from_node_id} or return 'main';
    # memoize per enclosing node: a sub with N calls would otherwise re-fetch its
    # node N times in one resolve_all (cache lives on this per-pass Resolver instance).
    return $self->{_pkg_cache}{$id} //= do {
        my $from = $self->store->node($id);
        !$from                                              ? 'main'
        : ($from->{kind} // '') =~ /\A(?:package|class)\z/  ? ($from->{qualified_name} // 'main')   # a package/class node IS the package
        :                                                     package_of($from->{qualified_name} // $from->{name} // 'main');
    };
}

sub _resolve_call ($self, $ref) {
    my $s = $self->store;
    my $name = $ref->{reference_name};
    my $callable = sub ($q) { (grep { $_->{kind} =~ /function|method|constant/ } $s->nodes_by_qname($q))[0] };
    return $callable->($name) if $name =~ /::/;
    my $pkg = $self->_from_package($ref);
    if (my $n = $callable->(qualify($pkg, $name))) { return $n }   # a local definition shadows any import
    if (my $mod = $self->_import_index->{$pkg}{$name}) {           # `use Mod qw(name)` -> Mod::name
        if (my $n = $callable->("${mod}::${name}")) { return $n }
    }
    return $s->unique_callable($name);   # unambiguous global definition (O(1), not O(all same-named))
}

# { helper_name => method_node }, for resolving `$c->name` method calls to a
# Mojolicious helper registered anywhere in the app.
has _helper_index => (is => 'lazy');
sub _build__helper_index ($self) {
    my $s = $self->store;
    my %idx;
    for my $n ($s->all_nodes('method')) {
        next unless ($n->{metadata} // {})->{helper};
        $idx{ $n->{name} } //= $n;
    }
    return \%idx;
}

# { package => { imported_symbol => exporting_module } }, built once from the
# imports edges' recorded symbol lists -- lets a bareword call resolve to the
# module it was imported from even when the name is globally ambiguous.
has _import_index => (is => 'lazy');
sub _build__import_index ($self) {
    my $s = $self->store;
    my %idx;
    for my $e ($s->edges_of_kind('imports')) {
        my $m = $e->{metadata} || {};
        my ($mod, $syms) = ($m->{module}, $m->{symbols});
        next unless $mod && $syms;
        my $src = $s->node($e->{source}) or next;
        my $pkg = ($src->{kind} // '') eq 'file' ? 'main' : ($src->{qualified_name} // next);
        $idx{$pkg}{$_} //= $mod for @$syms;
    }
    return \%idx;
}

# Resolve a method call to a definition, returning ($node, $provenance) or ().
# Literal receivers (Foo->m) resolve exactly (static). $self->m / $class->m
# resolve against the *enclosing* package and its static @ISA -- a high-value
# heuristic for idiomatic OO, but only when the method actually exists locally or
# in an ancestor (never a guess edge). Those carry provenance 'heuristic' so a
# later optree/MOP pass overrides them and the output stays honest.
sub _resolve_method ($self, $ref) {
    my $meth = $ref->{reference_name};
    my $cand = $ref->{candidates} || {};

    # $self->SUPER::method -> the named method on the enclosing class's ANCESTORS
    # (the static @ISA, in MRO order), skipping the class itself.
    if (my ($m) = $meth =~ /\ASUPER::(.+)\z/) {
        my $s = $self->store;
        my $cls = $self->_from_package($ref);
        my @anc = @{ $self->{_mro_cache}{$cls} //= [ $self->_mro($cls) ] };
        shift @anc;
        for my $c (@anc) {
            if (my ($n) = grep { ($_->{kind} // '') =~ /method|function/ } $s->nodes_by_qname(qualify($c, $m))) {
                return ($n, 'heuristic');   # via static @ISA, like $self->m -- runtime can override
            }
        }
        return;
    }

    # chained `BASE->attr->meth` / `func()->meth`: resolve the producer (attr on
    # BASE's type, or the bareword function), read its declared/inferred return
    # type (`has attr => isa => 'R'` / `sub { R->new }`), then meth on R's MRO.
    if (my $ch = $cand->{chain}) {
        my $producer = $ch->{base_func}
            ? $self->_resolve_call({ reference_name => $ch->{base_func}, from_node_id => $ref->{from_node_id} })
            : do {
                my $base = $ch->{base_type} // ($ch->{base_self} ? $self->_from_package($ref) : undef);
                defined $base ? $self->_method_in($base, $ch->{method}) : undef;
              };
        my $r = $producer ? ($producer->{metadata} || {})->{returns} : undef;
        return unless $r;
        my $n = $self->_method_in($r, $meth) or return;
        return ($n, 'inferred');
    }

    my $recv = $cand->{receiver} // '';
    my ($start, $prov);
    if    ($cand->{receiver_type})          { $start = $cand->{receiver_type};    $prov = 'inferred'  }   # my $x = Class->new
    elsif ($cand->{receiver_call}) {                                                                       # my $x = foo(); $x->m
        # interprocedural: $x's type is the return type of foo(), so resolve foo and
        # read its inferred `returns` (a `Class->new` builder).
        my $fn = $self->_resolve_call({ reference_name => $cand->{receiver_call}, from_node_id => $ref->{from_node_id} });
        $start = $fn ? ($fn->{metadata} || {})->{returns} : undef;
        $prov  = 'inferred';
    }
    elsif ($recv =~ /\A\$(?:self|class)\z/) { $start = $self->_from_package($ref); $prov = 'heuristic' }
    elsif ($recv =~ /\A[\w:]+\z/)           { $start = $recv;                      $prov = 'static'    }
    else                                    { return }   # unknown receiver ($obj, expression, chain)
    return unless defined $start;

    my $n = $self->_method_in($start, $meth) or return;
    return ($n, $prov);
}

# First method/function node named $meth found walking $type's MRO. The @ISA/role
# chain is stable across one resolve_all, but this runs per unresolved ref -- so
# cache each type's MRO; a deep chain isn't re-walked (with DB lookups) per call.
sub _method_in ($self, $type, $meth) {
    my $s = $self->store;
    for my $cls (@{ $self->{_mro_cache}{$type} //= [ $self->_mro($type) ] }) {
        if (my ($n) = grep { $_->{kind} =~ /method|function/ } $s->nodes_by_qname(qualify($cls, $meth))) {
            return $n;
        }
    }
    return undef;
}

# Public: the method/function node $meth resolves to on $class's MRO, or undef.
# Lets the LLM resolver type a receiver once and resolve all its calls (only the
# ones the class actually has -- never a fabricated edge).
sub method_in_mro ($self, $class, $meth) { $self->_method_in($class, $meth) }

# A class followed by its ancestors in Perl's default (depth-first, left-to-right)
# method resolution order, walked transitively through @ISA `extends` edges. The
# %seen guard visits each class once, so diamond and (malformed) cyclic
# inheritance are safe and never loop. C3 ordering is out of scope.
sub _mro ($self, $cls, $seen = {}) {
    return () if $seen->{$cls}++;
    my $s = $self->store;
    my @order = ($cls);
    # first node only: a class split across files may truncate that branch's parents.
    if (my ($c) = $s->nodes_by_qname($cls)) {
        # @ISA parents AND composed roles (`with`) both contribute methods.
        for my $parent (grep { defined } map { ($_->{metadata} || {})->{name} } $s->outgoing_edges($c->{id}, 'extends', 'implements')) {
            push @order, $self->_mro($parent, $seen);
        }
    }
    return @order;
}

1;

__END__

=head1 NAME

App::PerlGraph::Resolver - resolve calls, references and inheritance into edges

=head1 DESCRIPTION

Post-extraction pass linking unresolved refs to definitions -- bareword/imported
calls, literal-class, C<$self>/C<$class> and C<SUPER::> method calls resolved up the MRO, type
inference (C<my $x = Class-E<gt>new> receivers, and chained C<$self-E<gt>attr-E<gt>m>
/ C<f()-E<gt>m> through a typed accessor or C<Class-E<gt>new> builder return type;
provenance C<inferred>), and re-applied learned (LLM)
resolutions -- and filling inheritance edges by name.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
