package App::PerlGraph::Store;
use v5.36;
our $VERSION = q{0.001};
use Moo;
use DBI;
use Cpanel::JSON::XS ();
use App::PerlGraph::Schema qw(DDL);

has path  => (is => 'ro', required => 1);
has dbh   => (is => 'lazy');
has _json => (is => 'lazy');
sub _build__json ($self) { Cpanel::JSON::XS->new->canonical }

sub _build_dbh ($self) {
    my $dbh = DBI->connect("dbi:SQLite:dbname=@{[$self->path]}", '', '',
        { RaiseError => 1, AutoCommit => 1, sqlite_unicode => 1 });
    unless ($self->path eq ':memory:') {
        $dbh->do('pragma journal_mode=wal');
        # WAL + synchronous=NORMAL: fsync at checkpoints, not on every commit. The
        # graph is a rebuildable cache, so trading "lose the last few commits on a
        # power cut" (never corruption) for far fewer fsyncs is the right call --
        # the difference between minutes and hours on a large tree.
        $dbh->do('pragma synchronous=normal');
    }
    $dbh->do('pragma foreign_keys=on');
    return $dbh;
}

sub init ($self) { $self->dbh->do($_) for grep /\S/, split /;\s*\n/, DDL; return $self }

# metadata/candidates are stored as JSON text; hashrefs in, hashrefs out.
sub _enc ($self, $v) { defined $v && ref $v ? $self->_json->encode($v) : $v }
sub _dec ($self, $v) { (defined $v && $v =~ /\A\s*[\[{]/) ? scalar(eval { $self->_json->decode($v) }) : $v }

# prepare_cached: resolution fires the same handful of lookup SQLs 100k+ times on
# a large tree, so reusing the prepared statement (vs re-parsing/planning each
# call) is a big win. Each call fully fetches before returning -> no reentrancy.
sub _rows  ($self, $sql, @bind) {
    my $sth = $self->dbh->prepare_cached($sql);
    $sth->execute(@bind);
    return @{ $sth->fetchall_arrayref({}) };
}
sub _nodes ($self, $sql, @bind) { map { $_->{metadata} = $self->_dec($_->{metadata}); $_ } $self->_rows($sql, @bind) }
sub _edges ($self, $sql, @bind) { map { $_->{metadata} = $self->_dec($_->{metadata}); $_ } $self->_rows($sql, @bind) }

sub insert_node ($self, $n) {
    my @cols = qw(id kind name qualified_name file_path language
        start_line end_line start_col end_col signature docstring
        visibility is_exported metadata);
    my $sql = 'insert or replace into nodes (' . join(',', @cols) . ') values ('
        . join(',', ('?') x @cols) . ')';
    $self->dbh->do($sql, undef, map { $_ eq 'metadata' ? $self->_enc($n->{$_}) : $n->{$_} } @cols);
    $self->dbh->do('delete from nodes_fts where id = ?', undef, $n->{id});   # keep fts upsert-safe
    $self->dbh->do('insert into nodes_fts (id,name,qualified_name,docstring) values (?,?,?,?)',
        undef, @{$n}{qw(id name qualified_name docstring)})
        unless ($n->{kind} // '') eq 'file';   # files aren't searchable symbols
    return $n->{id};
}

sub nodes_by_name  ($self, $name) { $self->_nodes('select * from nodes where name = ? order by file_path, start_line', $name) }
sub nodes_by_qname ($self, $q)    { $self->_nodes('select * from nodes where qualified_name = ? order by file_path, start_line', $q) }

# The single callable (function/method/constant) named $name, or undef if there
# are zero or several. LIMIT 2 keeps this O(1) even when a common name has
# thousands of definitions: the resolver runs it per unresolved bareword ref, so
# fetching every same-named row was O(refs x defs) -- the large-tree slowdown.
sub unique_callable ($self, $name) {
    my @n = $self->_nodes("select * from nodes where name = ? and kind in ('function','method','constant') limit 2", $name);
    return @n == 1 ? $n[0] : undef;
}
sub nodes_in_file  ($self, $f)    { $self->_nodes('select * from nodes where file_path = ?', $f) }
sub node           ($self, $id)   { ($self->_nodes('select * from nodes where id = ?', $id))[0] }

sub search ($self, $query, $limit = 50) {
    # phrase-quote so fts5 treats ':', '-', '+', '*' etc. as literal text.
    my $match = '"' . ($query =~ s/"/""/gr) . '"';
    return $self->_nodes(
        'select n.* from nodes_fts f join nodes n on n.id = f.id where nodes_fts match ? limit ?',
        $match, $limit);
}

sub insert_edge ($self, $e) {
    $self->dbh->do(
        'insert into edges (source,target,kind,line,col,provenance,metadata) values (?,?,?,?,?,?,?)',
        undef, @{$e}{qw(source target kind line col provenance)}, $self->_enc($e->{metadata}));
    return $self->dbh->last_insert_id('', '', 'edges', '');
}

# provenance authority: higher rank wins on upsert. `heuristic` (inferred
# $self->method) sits below `static` so a certain edge is never relabeled as a
# guess, and a later static/optree resolution upgrades it.
my %PROV_RANK = (heuristic => -1, static => 0, framework => 1, symtab => 2, xs => 2, optree => 3, mop => 3);
sub _prov_rank ($self, $p) { $PROV_RANK{ $p // 'static' } // 0 }

# Insert an edge, or upgrade an existing (source,target,kind) edge to a higher
# provenance, merging metadata. Returns the edge id.
sub upsert_edge ($self, $e) {
    my ($src, $tgt, $kind) = @{$e}{qw(source target kind)};
    if (defined $tgt) {
        my ($exist) = $self->_rows(
            'select * from edges where source = ? and target = ? and kind = ?', $src, $tgt, $kind);
        if ($exist) {
            my $newp = $e->{provenance} // 'static';
            if ($self->_prov_rank($newp) > $self->_prov_rank($exist->{provenance})) {
                my $merged = { %{ $self->_dec($exist->{metadata}) || {} }, %{ $e->{metadata} || {} } };
                $self->dbh->do(
                    'update edges set provenance = ?, metadata = ?, line = coalesce(?,line), col = coalesce(?,col) where id = ?',
                    undef, $newp, $self->_enc($merged), $e->{line}, $e->{col}, $exist->{id});
            }
            return $exist->{id};
        }
    }
    return $self->insert_edge($e);
}

sub outgoing_edges ($self, $id, @kinds) {
    my $sql = 'select * from edges where source = ?';
    $sql .= ' and kind in (' . join(',', ('?') x @kinds) . ')' if @kinds;
    $self->_edges($sql, $id, @kinds);
}
sub incoming_edges ($self, $id, @kinds) {
    my $sql = 'select * from edges where target = ?';
    $sql .= ' and kind in (' . join(',', ('?') x @kinds) . ')' if @kinds;
    $self->_edges($sql, $id, @kinds);
}
sub null_target_edges ($self, @kinds) {
    my $sql = 'select * from edges where target is null';
    $sql .= ' and kind in (' . join(',', ('?') x @kinds) . ')' if @kinds;
    $self->_edges($sql, @kinds);
}

sub insert_unresolved ($self, $r) {
    $self->dbh->do(
        'insert into unresolved_refs (from_node_id,reference_name,reference_kind,line,col,file_path,candidates)
         values (?,?,?,?,?,?,?)', undef,
        @{$r}{qw(from_node_id reference_name reference_kind line col file_path)}, $self->_enc($r->{candidates}));
    return $self->dbh->last_insert_id('', '', 'unresolved_refs', '');
}
sub all_unresolved ($self) {
    map { $_->{candidates} = $self->_dec($_->{candidates}); $_ } $self->_rows('select * from unresolved_refs');
}

sub resolve_ref ($self, $ref_id, $target_id, $provenance = 'static') {
    my $ref = ($self->_rows('select * from unresolved_refs where id = ?', $ref_id))[0] or return;
    my $kind = ($ref->{reference_kind} // '') =~ /method/ ? 'calls' : ($ref->{reference_kind} // 'references');
    $kind = 'calls' if $kind eq 'call';
    $self->upsert_edge({ source => $ref->{from_node_id}, target => $target_id, kind => $kind,
        line => $ref->{line}, col => $ref->{col}, provenance => $provenance });
    $self->dbh->do('delete from unresolved_refs where id = ?', undef, $ref_id);
}

sub upsert_file ($self, $f) {
    $self->dbh->do(
        'insert or replace into files (path,hash,mtime,language,node_count,parse_errors,indexed_at)
         values (?,?,?,?,?,?,?)', undef,
        @{$f}{qw(path hash mtime language node_count parse_errors)}, time);
}
sub file_hash ($self, $path) {
    my $r = $self->dbh->selectrow_arrayref('select hash from files where path = ?', undef, $path);
    return $r ? $r->[0] : undef;
}
# All known path => hash pairs in one query (parallel index reads this once,
# before forking, so workers can skip unchanged files without a DB handle).
sub file_hashes ($self) { map { $_->{path} => $_->{hash} } $self->_rows('select path, hash from files') }
sub delete_file_nodes ($self, $path) {
    my @ids = map { $_->{id} } $self->nodes_in_file($path);
    if (@ids) {
        my $ph = join ',', ('?') x @ids;
        # delete only edges originating here; inbound edges survive (stable ids).
        $self->dbh->do("delete from edges where source in ($ph)", undef, @ids);
        $self->dbh->do("delete from nodes_fts where id in ($ph)", undef, @ids);
        $self->dbh->do("delete from nodes where id in ($ph)", undef, @ids);
    }
    $self->dbh->do('delete from unresolved_refs where file_path = ?', undef, $path);
}

sub file_paths   ($self) { map { $_->{path} } $self->_rows('select path from files') }

# Files (by path) whose nodes have an edge INTO a node in any of @files -- the
# callers/referencers of those files. sync() uses this to refresh edges that
# would otherwise dangle when a target symbol is renamed or removed.
sub dependents_of ($self, @files) {
    return () unless @files;
    my $ph = join ',', ('?') x @files;
    map { $_->{file_path} } $self->_rows(
        "select distinct ns.file_path
           from edges e
           join nodes nt on nt.id = e.target
           join nodes ns on ns.id = e.source
          where nt.file_path in ($ph)", @files);
}

# Fully remove a file that no longer exists on disk: its nodes, all edges
# touching them (inbound and outbound), refs, and the files row.
sub forget_file ($self, $path) {
    my @ids = map { $_->{id} } $self->nodes_in_file($path);
    if (@ids) {
        my $ph = join ',', ('?') x @ids;
        $self->dbh->do("delete from edges where source in ($ph) or target in ($ph)", undef, @ids, @ids);
        $self->dbh->do("delete from nodes_fts where id in ($ph)", undef, @ids);
        $self->dbh->do("delete from nodes where id in ($ph)", undef, @ids);
    }
    $self->dbh->do('delete from unresolved_refs where file_path = ?', undef, $path);
    $self->dbh->do('delete from files where path = ?', undef, $path);
}
sub all_nodes ($self, @kinds) {
    my $sql = 'select * from nodes';
    $sql .= ' where kind in (' . join(',', ('?') x @kinds) . ')' if @kinds;
    $self->_nodes("$sql order by file_path, start_line", @kinds);
}
sub package_nodes ($self) { $self->_nodes("select * from nodes where kind in ('package','class')") }
sub module_files  ($self) { map { $_->{path} } $self->_rows("select path from files where path like '%.pm'") }

# Dead-code support: function nodes with no inbound calls/references/overrides
# edge (the structural `contains` from the owning package is ignored). Skips
# synthetic __ANON__/__before__ nodes; skips exported public-API subs unless
# $include_exported.
sub unreferenced_functions ($self, $include_exported = 0) {
    my $sql = q{
        select n.* from nodes n
        where n.kind = 'function'
          and n.name not like '\_\_%' escape '\'
          and not exists (
              select 1 from edges e
              where e.target = n.id and e.kind in ('calls','references','overrides'))
    };
    $sql .= ' and coalesce(n.is_exported, 0) = 0' unless $include_exported;
    $sql .= ' order by n.file_path, n.start_line';
    return $self->_nodes($sql);
}
sub unresolved_ref_names ($self) {
    map { $_->{reference_name} } $self->_rows('select distinct reference_name from unresolved_refs');
}
1;

__END__

=head1 NAME

App::PerlGraph::Store - SQLite-backed graph storage

=head1 DESCRIPTION

Nodes, edges and unresolved refs with FTS5 search and provenance-ranked edge upserts.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
