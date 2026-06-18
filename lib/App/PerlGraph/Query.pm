package App::PerlGraph::Query;
use v5.36;
our $VERSION = q{0.001};
use Moo;

# Read-only graph queries over a Store. Symbols may be bare names ('run') or
# qualified ('Foo::run').
has store => (is => 'ro', required => 1);

sub _defs ($self, $symbol) {
    my $s = $self->store;
    return $symbol =~ /::/ ? $s->nodes_by_qname($symbol) : $s->nodes_by_name($symbol);
}

sub search ($self, $query, $limit = 50) { $self->store->search($query, $limit) }

sub callees ($self, $symbol) {
    my $s = $self->store;
    my @out;
    for my $def ($self->_defs($symbol)) {
        for my $e ($s->outgoing_edges($def->{id}, 'calls')) {
            next unless $e->{target};
            my $t = $s->node($e->{target}) or next;
            $t->{_provenance} = $e->{provenance};
            push @out, $t;
        }
    }
    return @out;
}

sub callers ($self, $symbol) {
    my $s = $self->store;
    my @out;
    for my $def ($self->_defs($symbol)) {
        for my $e ($s->incoming_edges($def->{id}, 'calls')) {
            my $f = $s->node($e->{source}) or next;
            $f->{_provenance} = $e->{provenance};
            push @out, $f;
        }
    }
    return @out;
}

sub impact ($self, $symbol, $depth = 5) {
    my $s = $self->store;
    my %seen;
    my @q = map { $_->{id} } $self->_defs($symbol);
    my @result;
    while (@q && $depth-- > 0) {
        my @next;
        for my $id (@q) {
            for my $e ($s->incoming_edges($id, 'calls', 'references')) {
                next if $seen{ $e->{source} }++;
                my $n = $s->node($e->{source}) or next;
                $n->{_provenance} = $e->{provenance};
                push @result, $n;
                push @next, $e->{source};
            }
        }
        @q = @next;
    }
    return @result;
}

# Shortest call path from $from to $to: a forward BFS over calls/references
# edges, seeded from every node matching $from, stopping at the first node
# matching $to. Returns the node chain [from .. to] (each hop past the first
# tagged with _via, the edge kind that reached it) or an empty list if $to is
# unreachable. Mirrors impact(), which walks the same edges in reverse.
sub path ($self, $from, $to) {
    my $s = $self->store;
    my %target = map { $_->{id} => 1 } $self->_defs($to);
    my @starts = $self->_defs($from);
    return () unless %target && @starts;

    my (%seen, %prev, %via);
    for my $n (@starts) {
        return ($n) if $target{ $n->{id} };   # a symbol trivially reaches itself
        $seen{ $n->{id} } = 1;
    }
    my @q = sort keys %seen;   # stable seed order -> deterministic chain among equal-length ties
    my $hit;
    BFS: while (@q) {
        my @next;
        for my $id (@q) {
            for my $e ($s->outgoing_edges($id, 'calls', 'references')) {
                my $t = $e->{target} // next;
                next if $seen{$t}++;
                $prev{$t} = $id; $via{$t} = $e->{kind};
                if ($target{$t}) { $hit = $t; last BFS }
                push @next, $t;
            }
        }
        @q = @next;
    }
    return () unless defined $hit;

    my @ids = ($hit);
    unshift @ids, $prev{ $ids[0] } while defined $prev{ $ids[0] };
    return map { my $n = $s->node($_); $n->{_via} = $via{$_} if $via{$_}; $n } @ids;
}

# The call graph as { nodes => [...], edges => [...] } for export/visualization.
# Nodes are function/method/package/class/route (never `file`); edges are the
# meaningful relations calls/references/extends (structural `contains` is noise).
# With around => SYM, BFS-bounds to radius depth (default 2) in BOTH directions.
my @GRAPH_EDGES = qw(calls references extends);
sub graph ($self, %opt) {
    my $s = $self->store;
    my %keep;
    if (defined $opt{around}) {
        my $depth = $opt{depth} // 2;
        my @frontier = map { $_->{id} } $self->_defs($opt{around});
        return { nodes => [], edges => [] } unless @frontier;
        my %seen = map { $_ => 1 } @frontier;
        for (1 .. $depth) {
            my @next;
            for my $id (@frontier) {
                push @next, grep { !$seen{$_}++ }
                    map { $_->{target} // () } $s->outgoing_edges($id, @GRAPH_EDGES);
                push @next, grep { !$seen{$_}++ }
                    map { $_->{source} } $s->incoming_edges($id, @GRAPH_EDGES);
            }
            @frontier = @next;
        }
        for my $id (keys %seen) {
            my $n = $s->node($id);
            $keep{$id} = $n if $n && ($n->{kind} // '') ne 'file';
        }
    }
    else {
        %keep = map { ($_->{id} => $_) } $s->all_nodes(qw(function method package class route constant));
    }
    my @edges;
    for my $id (keys %keep) {
        for my $e ($s->outgoing_edges($id, @GRAPH_EDGES)) {
            next unless defined $e->{target} && $keep{ $e->{target} };
            push @edges, { from => $id, to => $e->{target}, kind => $e->{kind}, provenance => $e->{provenance} };
        }
    }
    # Stable edge order (by endpoint name, then kind) -> diff-friendly export output.
    my %name = map { ($_->{id} => ($_->{qualified_name} // $_->{name} // '')) } values %keep;
    @edges = sort { $name{ $a->{from} } cmp $name{ $b->{from} }
                 || $name{ $a->{to} }   cmp $name{ $b->{to} }
                 || ($a->{kind} // '')  cmp ($b->{kind} // '') } @edges;
    return { nodes => [ values %keep ], edges => \@edges };
}

# A "view" of a node: the node plus its immediate callers and callees, for the
# source-bearing node/explore commands.
sub _view ($self, $node) {
    my $qn = $node->{qualified_name};
    return {
        node    => $node,
        callers => [ defined $qn ? $self->callers($qn) : () ],
        callees => [ defined $qn ? $self->callees($qn) : () ],
    };
}

# Files affected by changing @$files: the transitive reverse closure (who
# calls/references symbols in those files), as a set of file paths. With
# tests_only, restricted to .t files -- i.e. which tests to re-run for a change.
sub affected ($self, $files, %opt) {
    my $s = $self->store;
    my @allpaths = $s->file_paths;
    my %changed;
    for my $c (@$files) {
        (my $cn = $c) =~ s{^\./}{};
        next unless length $cn;
        $changed{$_} = 1 for grep { $_ eq $c || m{(?:\A|/)\Q$cn\E\z} } @allpaths;
    }
    my (%seen, %afile, @queue);
    for my $p (keys %changed) {
        $afile{$p} = 1;
        push @queue, map { $_->{id} } grep { !$seen{$_->{id}}++ } $s->nodes_in_file($p);
    }
    my $depth = $opt{depth} // 25;
    while (@queue && $depth-- > 0) {
        my @next;
        for my $id (@queue) {
            for my $e ($s->incoming_edges($id, 'calls', 'references')) {
                next if $seen{ $e->{source} }++;
                my $src = $s->node($e->{source}) or next;
                $afile{ $src->{file_path} } = 1 if defined $src->{file_path};
                push @next, $e->{source};
            }
        }
        @queue = @next;
    }
    my @out = sort keys %afile;
    @out = grep { /\.t\z/ } @out if $opt{tests_only};
    return @out;
}

# Subs that nothing in the indexed code references -- dead-code candidates.
# Beyond having no inbound call/reference edge, two filters keep precision high:
# lifecycle/magic names are skipped, and any sub whose short name is invoked
# dynamically is spared -- `$obj->name` can't resolve to an edge but leaves an
# unresolved method_call ref of that name, so we treat the name as "in use".
# %opt: all => also include exported + lifecycle subs.
my %LIFECYCLE = map { $_ => 1 }
    qw(new import unimport BUILD BUILDARGS DEMOLISH DESTROY AUTOLOAD CLONE meta);
sub unused ($self, %opt) {
    my $s = $self->store;
    my %dynamic = map { $_ => 1 } $s->unresolved_ref_names;
    my @out;
    for my $n ($s->unreferenced_functions($opt{all})) {
        my $name = $n->{name} // '';
        # Moo/Moose lazy builders (_build_<attr>) are invoked by the framework.
        next if !$opt{all} && ($LIFECYCLE{$name} || $name =~ /^_build_/);
        next if $dynamic{$name};
        push @out, $n;
    }
    return @out;
}

sub node_view ($self, $symbol) { map { $self->_view($_) } $self->_defs($symbol) }
# explore omits whole-file nodes so it never dumps an entire file.
sub explore ($self, $query, $max = 8) {
    map { $self->_view($_) } grep { ($_->{kind} // '') ne 'file' } $self->search($query, $max);
}

1;

__END__

=head1 NAME

App::PerlGraph::Query - read-only graph queries

=head1 DESCRIPTION

callers / callees / impact / path / affected / unused / search / explore over a L<App::PerlGraph::Store>.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
