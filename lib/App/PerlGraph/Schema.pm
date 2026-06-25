package App::PerlGraph::Schema;
use v5.36;
our $VERSION = q{0.065};
use Exporter 'import';
our @EXPORT_OK = qw(DDL);

use constant DDL => <<'SQL';
create table if not exists files (
  path text primary key, hash text not null, mtime integer,
  language text, node_count integer default 0, parse_errors text,
  indexed_at integer, extraction_version integer default 1
);
create table if not exists nodes (
  id text primary key, kind text not null, name text not null,
  qualified_name text, file_path text, language text,
  start_line integer, end_line integer, start_col integer, end_col integer,
  signature text, docstring text, visibility text,
  is_exported integer default 0, metadata text
);
create index if not exists idx_nodes_name  on nodes(name);
create index if not exists idx_nodes_qname on nodes(qualified_name);
create index if not exists idx_nodes_file  on nodes(file_path);
create table if not exists edges (
  id integer primary key autoincrement, source text not null, target text,
  kind text not null, line integer, col integer, provenance text, metadata text
);
create index if not exists idx_edges_source on edges(source);
create index if not exists idx_edges_target on edges(target);
create index if not exists idx_edges_kind   on edges(kind);
create table if not exists unresolved_refs (
  id integer primary key autoincrement, from_node_id text,
  reference_name text not null, reference_kind text, line integer, col integer,
  file_path text, candidates text
);
create index if not exists idx_unresolved_name on unresolved_refs(reference_name);
create table if not exists resolutions (
  caller_qname text not null, method text not null, receiver text not null,
  target_qname text not null, provenance text default 'llm',
  primary key (caller_qname, method, receiver)
);
create virtual table if not exists nodes_fts using fts5(
  id unindexed, name, qualified_name, docstring, tokenize='unicode61'
);
create table if not exists embeddings (
  node_id text primary key, dim integer not null, vec blob not null
);
SQL
1;

__END__

=head1 NAME

App::PerlGraph::Schema - the SQLite DDL for the graph

=head1 DESCRIPTION

CREATE statements for the nodes, edges, unresolved_refs, resolutions and files
tables plus their indexes and the FTS5 search table.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
