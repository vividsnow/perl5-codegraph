package App::PerlGraph::Runtime;
use v5.36;
our $VERSION = q{0.053};
use Moo;
use Cpanel::JSON::XS ();
use POSIX ();

# Opt-in runtime introspection. LOADS the target code (executes BEGIN/use), so it
# runs in a forked child with an alarm timeout and is fail-soft: any error ->
# introspect() returns undef and the caller keeps the static graph.
#
# introspect(\@pm_files, \@packages) -> { nodes => [...], edges => [...] } | undef
#   nodes: { kind, name, qualified_name, package, provenance, metadata }
#   edges: { source_qname, target_qname, kind, provenance, line, metadata }

has lib_dirs => (is => 'ro', default => sub { [] });
has timeout  => (is => 'ro', default => 10);
has _json    => (is => 'lazy');
sub _build__json ($self) { Cpanel::JSON::XS->new->canonical }

sub introspect ($self, $pm_files, $packages) {
    pipe(my $rd, my $wr) or return undef;
    my $pid = fork;
    return undef unless defined $pid;

    if (!$pid) {                                   # ---- child ----
        close $rd;
        my $json = eval {
            local $SIG{ALRM} = sub { die "pcg-runtime-timeout\n" };
            alarm($self->timeout);
            unshift @INC, @{ $self->lib_dirs };
            for my $f (@$pm_files) {
                eval { require $f };                            # fail-soft per file
                die $@ if $@ && $@ =~ /pcg-runtime-timeout/;    # but let the timeout escape
            }
            my $r = $self->_introspect($packages);
            alarm(0);
            $self->_json->encode($r);
        };
        print {$wr} ($json // '');
        close $wr;
        POSIX::_exit(0);                            # skip parent/global destructors
    }

    close $wr;                                     # ---- parent ----
    my $data = eval {
        local $SIG{ALRM} = sub { die "pcg-parent-timeout\n" };
        alarm($self->timeout + 2);                 # backstop: never block on a wedged child
        my $d = do { local $/; <$rd> };
        alarm(0);
        $d;
    };
    close $rd;
    if (!defined $data) { kill 'KILL', $pid; waitpid $pid, 0; return undef }
    waitpid $pid, 0;
    return undef unless length $data;
    my $decoded = eval { $self->_json->decode($data) };
    return ref $decoded eq 'HASH' ? $decoded : undef;
}

sub _introspect ($self, $packages) {
    require Devel::Symdump; require mro; require B;
    my (@nodes, @edges);
    for my $pkg (@$packages) {
        next unless _pkg_exists($pkg);
        my @subs = _own_subs($pkg);

        # MOP first, so symtab does not re-list attribute accessors as plain methods.
        my %accessor;
        _mop($pkg, \@nodes, \@edges, \%accessor);

        # symtab: own subs that aren't MOP attribute accessors
        push @nodes, { kind => 'method', name => $_, qualified_name => "${pkg}::$_",
            package => $pkg, provenance => 'symtab' } for grep { !$accessor{$_} } @subs;

        # real @ISA -> extends
        { no strict 'refs';
          for my $parent (@{"${pkg}::ISA"}) {
              push @edges, { source_qname => $pkg, target_qname => $parent, kind => 'extends',
                  provenance => 'symtab', metadata => { via => 'isa' } };
          } }

        # optree-resolved calls
        for my $sub (@subs) {
            my $code = do { no strict 'refs'; *{"${pkg}::${sub}"}{CODE} } or next;
            my $cv = B::svref_2object($code);
            next unless $cv->isa('B::CV') && ref $cv->ROOT && !$cv->ROOT->isa('B::NULL');
            for my $c (_optree_calls($cv)) {
                my $target;
                if ($c->{type} eq 'func') { $target = $c->{name} }
                elsif (defined $c->{recv}) {                    # method call w/ a known receiver
                    my $cls = $c->{recv} eq '__SELF__' ? $pkg : $c->{recv};
                    $target = _method_owner($cls, $c->{name});
                }
                next unless defined $target;                    # unknown receiver -> leave to static
                push @edges, { source_qname => "${pkg}::${sub}", target_qname => $target,
                    kind => 'calls', provenance => 'optree', line => $c->{line}, metadata => { via => $c->{type} } };
            }
        }
    }
    return { nodes => \@nodes, edges => \@edges };
}

sub _pkg_exists ($pkg) { no strict 'refs'; return scalar keys %{"${pkg}::"} }

# the package a CODE ref actually belongs to (its GV's stash), or undef
sub _cv_owner ($code) { eval { B::svref_2object($code)->GV->STASH->NAME } }

# Subs whose CV actually belongs to $pkg (excludes imported/inherited).
sub _own_subs ($pkg) {
    my @subs;
    for my $qsub (Devel::Symdump->new($pkg)->functions) {
        my ($name) = $qsub =~ /::(\w+)\z/ or next;
        my $code = do { no strict 'refs'; *{$qsub}{CODE} } or next;
        my $owner = _cv_owner($code);
        push @subs, $name if defined $owner && $owner eq $pkg;
    }
    return sort @subs;
}

# Resolve a method name along $pkg's real MRO to its defining Pkg::method.
sub _method_owner ($pkg, $method) {
    my $code = $pkg->can($method) or return undef;
    my $owner = _cv_owner($code);
    return defined $owner ? "${owner}::${method}" : undef;
}

# Moo/Moose meta (best-effort, Moose/Class::MOP path): roles -> implements, has -> field.
sub _mop ($pkg, $nodes, $edges, $accessors) {
    my $meta = eval { require Class::MOP; Class::MOP::class_of($pkg) } or return;
    if ($meta->can('calculate_all_roles')) {
        for my $role (eval { $meta->calculate_all_roles }) {
            push @$edges, { source_qname => $pkg, target_qname => $role->name, kind => 'implements',
                provenance => 'mop', metadata => { via => 'with' } };
        }
    }
    if ($meta->can('get_all_attributes')) {
        for my $attr (eval { $meta->get_all_attributes }) {
            my $name = $attr->name;
            push @$nodes, { kind => 'field', name => $name, qualified_name => "${pkg}::${name}",
                package => $pkg, provenance => 'mop', metadata => { via => 'has' } };
            $accessors->{$name} = 1;
            $accessors->{$_} = 1 for grep { defined } eval { ($attr->get_read_method, $attr->get_write_method) };
        }
    }
}

sub _optree_calls ($cv) {
    my @calls;
    _walk_op($cv->ROOT, { line => 0, cv => $cv }, \@calls);
    return @calls;
}

# The method name of a method_named op. Non-threaded: the name SV hangs off the op
# (meth_sv). Threaded: meth_sv is a null B::SPECIAL and the name lives in the CV's pad
# VALUES at op->targ (mirrors the gv-in-pad case in _find_gv, but METHOP uses ->targ,
# not ->padix). eval-guarded so an unexpected shape degrades to undef, not a die.
sub _meth_name ($op, $cv) {
    my $sv = eval { $op->meth_sv };
    return $sv->PV if ref $sv && $sv->can('PV');
    my $pad = eval { (($cv->PADLIST->ARRAY)[1]->ARRAY)[$op->targ] };
    return (ref $pad && $pad->can('PV')) ? $pad->PV : undef;
}

sub _walk_op ($op, $ctx, $calls) {
    return unless ref $op && $$op;
    $ctx->{line} = $op->line if $op->isa('B::COP');
    if ($op->name eq 'entersub') {
        # gather children; the called sub / method op is the LAST child.
        my @kids; for (my $k = $op->first; ref $k && $$k; $k = $k->sibling) { push @kids, $k }
        my $last = $kids[-1];
        if ($last && $last->name eq 'method_named') {
            my $meth = _meth_name($last, $ctx->{cv});
            push @$calls, { type => 'method', name => $meth, line => $ctx->{line},
                recv => _invocant($kids[1], $ctx->{cv}) }       # kids[0] is pushmark
                if defined $meth && length $meth;
        }
        elsif ($last) {
            my $tgt = _find_gv($last, $ctx->{cv});
            push @$calls, { type => 'func', name => $tgt, line => $ctx->{line} } if defined $tgt;
        }
    }
    if ($op->can('flags') && ($op->flags & B::OPf_KIDS())) {
        for (my $k = $op->first; ref $k && $$k; $k = $k->sibling) { _walk_op($k, $ctx, $calls) }
    }
}

# Classify a method-call invocant: '__SELF__' for $self/$class, a literal class
# name for Class->m / __PACKAGE__->m, or undef (unknown receiver -> don't resolve).
sub _invocant ($op, $cv) {
    return undef unless ref $op && $$op;
    my $n = $op->name;
    if ($n eq 'const') {
        my $sv = eval { $op->sv };
        return (ref $sv && $sv->can('PV')) ? $sv->PV : undef;
    }
    if ($n eq 'padsv') {
        my $name = _pad_name($cv, $op->targ);
        return (defined $name && ($name eq '$self' || $name eq '$class')) ? '__SELF__' : undef;
    }
    return undef;
}

sub _pad_name ($cv, $targ) {
    return undef unless $cv && $targ;
    my $names = eval { ($cv->PADLIST->ARRAY)[0] } or return undef;
    my $nv = eval { ($names->ARRAY)[$targ] } or return undef;
    return (ref $nv && $nv->can('PVX')) ? $nv->PVX : undef;
}

sub _find_gv ($op, $cv = undef) {
    return undef unless ref $op && $$op;
    if ($op->name eq 'gv') {
        # the GV is in the op on a non-threaded perl (B::SVOP), or in the CV's pad at
        # op->padix on a threaded perl (B::PADOP -- the common distro/macOS build, where
        # PADOP->gv returns a null B::SPECIAL, not the GV). eval-guarded -> any unexpected
        # shape degrades to undef rather than dying inside the forked enricher.
        my $gv = $op->isa('B::SVOP')  ? eval { $op->gv }
               : $op->isa('B::PADOP') ? eval { (($cv->PADLIST->ARRAY)[1]->ARRAY)[$op->padix] }
               :                        undef;
        return (ref $gv && $gv->can('STASH')) ? $gv->STASH->NAME . '::' . $gv->NAME : undef;
    }
    if ($op->can('flags') && ($op->flags & B::OPf_KIDS())) {
        for (my $k = $op->first; ref $k && $$k; $k = $k->sibling) {
            my $r = _find_gv($k, $cv); return $r if defined $r;
        }
    }
    return undef;
}

1;

__END__

=head1 NAME

App::PerlGraph::Runtime - opt-in runtime enrichment (symtab / optree / MOP)

=head1 DESCRIPTION

Loads the target code in a forked, timeout-guarded child and introspects it (L<Devel::Symdump>, C<B::>, Moo/Moose MOP); fail-soft, keeps the static graph on any error.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
