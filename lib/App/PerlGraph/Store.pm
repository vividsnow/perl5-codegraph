package App::PerlGraph::Store;
use v5.36;
our $VERSION = q{0.053};
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

# Batch lookups (avoid the N+1 of calling node()/nodes_by_name once per item over a
# large unresolved set). Chunked to stay under SQLite's bound-variable limit.
sub _in_chunks ($self, @ids) { my @u; my %s; push @u, $_ for grep { defined && !$s{$_}++ } @ids; @u }
sub node_qnames ($self, @ids) {   # { id => qualified_name } for the given node ids
    my %qn; my @k = $self->_in_chunks(@ids);
    while (my @c = splice @k, 0, 900) {
        $qn{ $_->{id} } = $_->{qualified_name}
            for $self->_rows('select id, qualified_name from nodes where id in (' . join(',', ('?') x @c) . ')', @c);
    }
    return %qn;
}
sub callables_by_name ($self, @names) {   # { name => [ callable nodes, file_path/start_line order ] }
    my %by; my @k = $self->_in_chunks(@names);
    while (my @c = splice @k, 0, 900) {
        push @{ $by{ $_->{name} } }, $_ for grep { ($_->{kind} // '') =~ /method|function/ }
            $self->_nodes('select * from nodes where name in (' . join(',', ('?') x @c) . ') order by file_path, start_line', @c);
    }
    return %by;
}

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

# --- position lookups (back LSP go-to-definition / find-references) ---
# Resolved call/reference edges whose call SITE is at $file line $line (a node may
# host several calls on one line; ordered by col for finer cursor matching).
sub edges_at_source ($self, $file, $line) {
    $self->_edges("select e.* from edges e join nodes n on n.id = e.source
        where n.file_path = ? and e.line = ? and e.target is not null
          and e.kind in ('calls','references') order by e.col", $file, $line);
}
# The definition declared on $line (cursor on a sub/method/field name).
sub node_at_start ($self, $file, $line) {
    ($self->_nodes("select * from nodes where file_path = ? and start_line = ?
        and kind != 'file' order by length(qualified_name) desc limit 1", $file, $line))[0];
}
# The innermost definition whose body spans $line (cursor anywhere inside a sub).
sub node_covering ($self, $file, $line) {
    ($self->_nodes("select * from nodes where file_path = ? and kind != 'file'
        and start_line <= ? and (end_line is null or end_line >= ?)
        order by start_line desc limit 1", $file, $line, $line))[0];
}

sub search ($self, $query, $limit = 50) {
    # phrase-quote so fts5 treats ':', '-', '+', '*' etc. as literal text.
    my $match = '"' . ($query =~ s/"/""/gr) . '"';
    return $self->_nodes(
        'select n.* from nodes_fts f join nodes n on n.id = f.id where nodes_fts match ? limit ?',
        $match, $limit);
}

# Substring symbol match for LSP workspace/symbol ("go to symbol in workspace"):
# case-insensitive LIKE on name/qualified_name, shortest (most relevant) first.
# Editors want incremental substring matching, which fts5 phrase queries don't do.
sub symbols_like ($self, $q, $limit = 100) {
    my $like = '%' . ($q =~ s/([%_\\])/\\$1/gr) . '%';
    $self->_nodes("select * from nodes where kind != 'file'
        and (name like ? escape '\\' or qualified_name like ? escape '\\')
        order by length(qualified_name) limit ?", $like, $like, $limit);
}

sub insert_edge ($self, $e) {
    $self->dbh->do(
        'insert into edges (source,target,kind,line,col,provenance,metadata) values (?,?,?,?,?,?,?)',
        undef, @{$e}{qw(source target kind line col provenance)}, $self->_enc($e->{metadata}));
    return $self->dbh->last_insert_id('', '', 'edges', '');
}

# provenance authority: higher rank wins on upsert. The pre-static tiers
# (llm < heuristic < inferred) are all guesses sitting below `static`, so a certain
# edge is never relabeled as a guess; a later static/optree resolution upgrades them.
my %PROV_RANK = (llm => -3, heuristic => -2, inferred => -1, static => 0, framework => 1, symtab => 2, xs => 2, optree => 3, mop => 3);
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
# call-graph centrality: nodes ranked by inbound (fan-in, most depended-upon) or
# outbound (fan-out, most complex) calls/references. Returns [{id, n}], n desc.
sub top_fan_in ($self, $limit) {
    $self->_rows("select target as id, count(*) as n from edges
        where target is not null and kind in ('calls','references')
        group by target order by n desc, id limit ?", $limit);
}
sub top_fan_out ($self, $limit) {
    $self->_rows("select source as id, count(*) as n from edges
        where kind in ('calls','references')
        group by source order by n desc, id limit ?", $limit);
}
# subs ranked by cyclomatic complexity (only the >1 ones carry it). The LIKE
# narrows the scan; the decode+sort happens in Perl (no reliance on the JSON1 ext).
sub top_complex ($self, $limit) {
    my @n = grep { ($_->{metadata} // {})->{complexity} }
            $self->_nodes("select * from nodes where metadata like '%complexity%' and kind in ('function','method')");
    @n = sort { $b->{metadata}{complexity} <=> $a->{metadata}{complexity}
             || ($a->{qualified_name} // '') cmp ($b->{qualified_name} // '') } @n;
    return @n > $limit ? @n[0 .. $limit - 1] : @n;
}

sub null_target_edges ($self, @kinds) {
    my $sql = 'select * from edges where target is null';
    $sql .= ' and kind in (' . join(',', ('?') x @kinds) . ')' if @kinds;
    $self->_edges($sql, @kinds);
}
sub edges_of_kind ($self, $kind) { $self->_edges('select * from edges where kind = ?', $kind) }

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

# (caller_qname, method, receiver) for a method-call unresolved ref, or () if it
# isn't a method call or has no resolvable caller -- the shared "anchor" used to
# group, match, and persist agent resolutions. The receiver may be undef.
sub ref_anchor ($self, $ref, $qn = undef) {
    return () unless ($ref->{reference_kind} // '') eq 'method_call';
    my $id = $ref->{from_node_id};
    my $caller = !defined $id ? undef
        : $qn ? $qn->{$id}                                    # batched id->qname cache (hot loops)
        :       ($self->node($id) // {})->{qualified_name};
    return () unless defined $caller;
    return ($caller, $ref->{reference_name}, ($ref->{candidates} // {})->{receiver});
}

# Unresolved method calls that *have* a candidate definition in the graph -- the
# subset an agent can resolve to a real node. Grouped by (caller, method,
# receiver) and ranked by how often the call appears (highest-impact first).
# Each: { caller, method, receiver, count, file, line, candidates => [{qname,file,line}] }.
sub unresolved_with_candidates ($self, %opt) {
    my @refs = $self->all_unresolved;
    my %qn   = $self->node_qnames(map { $_->{from_node_id} // () } @refs);   # batch: id -> caller qname
    my %group;
    for my $ref (@refs) {
        my ($caller, $method, $recv) = $self->ref_anchor($ref, \%qn) or next;
        next if $opt{name} && $method ne $opt{name};
        next unless defined $recv && $recv =~ /\A\$/;   # only variable receivers ($x, $self->{x}) --
                                                        # a literal `Class->m` that didn't resolve is external
        my $key = join "\x1f", $caller, $method, $recv;
        ($group{$key} //= { caller => $caller, method => $method, receiver => $recv,
                            count => 0, file => $ref->{file_path}, line => $ref->{line} })->{count}++;
    }
    my %cand = $self->callables_by_name(map { $_->{method} } values %group);   # batch: one query, not one per group
    my @out;
    for my $g (values %group) {
        my $c = $cand{ $g->{method} } or next;
        $g->{candidates} = [ map { { qname => $_->{qualified_name}, file => $_->{file_path}, line => $_->{start_line} } } @$c ];
        push @out, $g;
    }
    @out = sort { $b->{count} <=> $a->{count} || ($a->{caller} // '') cmp ($b->{caller} // '') } @out;
    my $limit = $opt{limit} // 50;
    return @out > $limit ? @out[0 .. $limit - 1] : @out;
}

# learned LLM/agent resolutions, persisted so they survive a reindex
sub learn_resolution ($self, $caller, $method, $receiver, $target_qname) {
    $self->dbh->do('insert or replace into resolutions (caller_qname,method,receiver,target_qname) values (?,?,?,?)',
        undef, $caller, $method, $receiver, $target_qname);
}
sub learned_resolutions ($self) { $self->_rows('select * from resolutions') }

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
        'insert or replace into files (path,hash,mtime,language,node_count,parse_errors,indexed_at,extraction_version)
         values (?,?,?,?,?,?,?,?)', undef,
        @{$f}{qw(path hash mtime language node_count parse_errors)}, time, $f->{extraction_version});
}

# A file is "fresh" only if BOTH its content hash AND the extractor version match --
# so bumping the extractor (new node kinds / resolution) forces a re-extract on the
# next index/sync even when the file's bytes are unchanged.
sub file_fresh ($self, $path, $hash, $ev) {
    my ($r) = $self->_rows('select hash, extraction_version from files where path = ?', $path);
    return $r && ($r->{hash} // '') eq $hash && ($r->{extraction_version} // 0) == $ev;
}
sub file_states ($self) { map { $_->{path} => $_ } $self->_rows('select path, hash, extraction_version from files') }
sub file_hash ($self, $path) {
    my $r = $self->dbh->selectrow_arrayref('select hash from files where path = ?', undef, $path);
    return $r ? $r->[0] : undef;
}
sub delete_file_nodes ($self, $path) {
    my @ids = map { $_->{id} } $self->nodes_in_file($path);
    if (@ids) {
        my $ph = join ',', ('?') x @ids;
        # delete only edges originating here; inbound edges survive (stable ids).
        $self->dbh->do("delete from edges where source in ($ph)", undef, @ids);
        $self->dbh->do("delete from nodes_fts where id in ($ph)", undef, @ids);
        $self->dbh->do("delete from embeddings where node_id in ($ph)", undef, @ids);
        $self->dbh->do("delete from nodes where id in ($ph)", undef, @ids);
    }
    $self->dbh->do('delete from unresolved_refs where file_path = ?', undef, $path);
}

# --- semantic-search embeddings (optional; built by `pcg index --embed`) ------
sub upsert_embedding ($self, $node_id, $vec) {
    $self->dbh->do('insert or replace into embeddings (node_id, dim, vec) values (?,?,?)',
        undef, $node_id, scalar(@$vec), pack('f*', @$vec));
}
# node_id => [floats]; the packed blob is unpacked back to a Perl vector.
sub all_embeddings ($self) {
    map { ($_->{node_id} => [ unpack 'f*', $_->{vec} ]) }
        $self->_rows('select node_id, vec from embeddings');
}
sub embedding_count ($self) { ($self->_rows('select count(*) n from embeddings'))[0]{n} }
# Drop embeddings whose node is gone (a symbol deleted since the last --embed).
sub prune_embeddings ($self) {
    $self->dbh->do('delete from embeddings where node_id not in (select id from nodes)');
}

sub file_paths   ($self) { map { $_->{path} } $self->_rows('select path from files') }
# distinct file_paths that actually have nodes (works without the files table, e.g.
# in-memory graphs); used to find test files for the untested-surface query.
sub node_file_paths ($self) { map { $_->{file_path} } $self->_rows('select distinct file_path from nodes where file_path is not null') }

# Is there any call/reference/import/inheritance edge between the two files (either
# direction)? Tells co-change coupling apart from real static coupling.
sub files_statically_linked ($self, $fa, $fb) {
    my @r = $self->_rows(
        "select 1 from edges e join nodes ns on ns.id = e.source join nodes nt on nt.id = e.target
          where ((ns.file_path = ? and nt.file_path = ?) or (ns.file_path = ? and nt.file_path = ?))
            and e.kind in ('calls','references','imports','extends','implements') limit 1",
        $fa, $fb, $fb, $fa);
    return @r ? 1 : 0;
}

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
        $self->dbh->do("delete from embeddings where node_id in ($ph)", undef, @ids);
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

# --- codebase-overview aggregations (pcg overview / pcg_overview) ---
sub kind_counts ($self) { map { ($_->{kind} => $_->{n}) } $self->_rows('select kind, count(*) n from nodes group by kind') }
# classes ranked by how many subclasses extend them (incoming extends edges).
sub most_subclassed ($self, $limit) {
    $self->_rows("select target as id, count(*) as n from edges where kind = 'extends' and target is not null
        group by target order by n desc, id limit ?", $limit);
}
# qualified names of the given kinds only -- lightweight, for namespace grouping.
sub qnames_of ($self, @kinds) {
    map { $_->{qualified_name} } grep { defined $_->{qualified_name} }
        $self->_rows('select qualified_name from nodes where kind in (' . join(',', ('?') x @kinds) . ')', @kinds);
}

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
