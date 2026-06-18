package App::PerlGraph::MCP;
use v5.36;
our $VERSION = q{0.001};
use Moo;
use Cpanel::JSON::XS ();
use App::PerlGraph ();
use App::PerlGraph::Format;

# A minimal MCP server: newline-delimited JSON-RPC 2.0 over stdio, wrapping the
# read-only Query engine. `dispatch` is a pure request->response function (so it
# is unit-testable); `run` is the stdio loop.

has query       => (is => 'ro');                         # App::PerlGraph::Query or undef (no index)
has base        => (is => 'ro', default => '.');         # project root, for reading source
has server_name => (is => 'ro', default => 'pcg');
has watch       => (is => 'ro', default => 0);           # lazily re-sync before tool calls
has indexer     => (is => 'ro');                          # App::PerlGraph::Indexer (for --watch)
has in          => (is => 'ro', default => sub { \*STDIN });
has out         => (is => 'ro', default => sub { \*STDOUT });
has _json       => (is => 'lazy');
sub _build__json ($self) { Cpanel::JSON::XS->new->utf8->canonical }

use constant PROTOCOL_VERSION => '2024-11-05';
use constant INSTRUCTIONS => <<'MD';
`pcg` is a Perl code knowledge graph. Prefer these tools over grep/Read when reasoning about Perl code structure:
pcg_explore (symbols + source + relationships in one call — best first stop), pcg_search (find symbols), pcg_node (a symbol's definition + location), pcg_callers / pcg_callees (who calls X / what X calls), pcg_impact (transitive callers — blast radius), pcg_path (how A reaches B — shortest call chain), pcg_unused (dead-code candidates — subs nothing references), pcg_affected (files/tests impacted by changing given files — CI triage). Results are authoritative for statically-resolved relationships. If a tool reports "no index", run `pcg index` in the project root first.
MD

my @TOOLS = (
    { name => 'pcg_search', handler => 'search', description => 'Search Perl symbols by name.',
      inputSchema => { type => 'object', properties => { query => { type => 'string', description => 'Symbol name or term' } }, required => ['query'] } },
    { name => 'pcg_node', handler => 'node', description => "A symbol's definition(s): verbatim source + immediate callers/callees.",
      inputSchema => { type => 'object', properties => { symbol => { type => 'string', description => 'Bare name or Foo::bar' } }, required => ['symbol'] } },
    { name => 'pcg_explore', handler => 'explore', description => 'Explore an area: matching symbols with their source and immediate relationships, in one call. Prefer this over grep/Read.',
      inputSchema => { type => 'object', properties => { query => { type => 'string', description => 'Symbol name or term to explore' } }, required => ['query'] } },
    { name => 'pcg_callers', handler => 'callers', description => 'All call sites of a function/method.',
      inputSchema => { type => 'object', properties => { symbol => { type => 'string', description => 'Symbol name' } }, required => ['symbol'] } },
    { name => 'pcg_callees', handler => 'callees', description => 'What a function/method calls.',
      inputSchema => { type => 'object', properties => { symbol => { type => 'string', description => 'Symbol name' } }, required => ['symbol'] } },
    { name => 'pcg_impact', handler => 'impact', description => 'Blast radius: transitive callers of a symbol.',
      inputSchema => { type => 'object', properties => { symbol => { type => 'string', description => 'Symbol name' } }, required => ['symbol'] } },
    { name => 'pcg_path', handler => 'path', description => 'Shortest call path from one symbol to another -- how A reaches B (or that it cannot).',
      inputSchema => { type => 'object', properties => { from => { type => 'string', description => 'Start symbol' }, to => { type => 'string', description => 'Target symbol' } }, required => ['from', 'to'] } },
    { name => 'pcg_unused', handler => 'unused', description => 'Dead-code candidates: defined subs nothing in the indexed code references. The output notes its own blind spots (dynamic/string dispatch, cross-distribution callers). Set all=true to also include exported and lifecycle subs.',
      inputSchema => { type => 'object', properties => { all => { type => 'boolean', description => 'Include exported + lifecycle subs (default false)' } } } },
    { name => 'pcg_affected', handler => 'affected', description => 'Files (or tests, with tests_only) impacted by changing the given files -- the reverse-dependency closure. Useful for CI triage (which tests to run for a diff).',
      inputSchema => { type => 'object', properties => {
          files      => { type => 'array', items => { type => 'string' }, description => 'Changed file paths' },
          tests_only => { type => 'boolean', description => 'Restrict to .t test files (default false)' },
      }, required => ['files'] } },
);

# Tool names, for the installer's permission allow-list (single source of truth).
sub tool_names ($class) { map { $_->{name} } @TOOLS }

sub _result ($self, $id, $result) { return { jsonrpc => '2.0', id => $id, result => $result } }
sub _error  ($self, $id, $code, $msg) { return { jsonrpc => '2.0', id => $id, error => { code => $code, message => $msg } } }

sub dispatch ($self, $req) {
    # A well-formed JSON line that isn't an object (a bare number/string/array,
    # which decode accepts via allow_nonref) is not a valid request -> ignore it
    # rather than crash the server loop on $req->{method}.
    return undef unless ref $req eq 'HASH';
    my $method = $req->{method} // '';
    my $id     = $req->{id};
    # JSON-RPC 2.0: a message with no id is a notification — never reply.
    return undef unless defined $id;
    if ($method eq 'initialize') {
        return $self->_result($id, {
            protocolVersion => PROTOCOL_VERSION,
            capabilities    => { tools => {} },
            serverInfo      => { name => $self->server_name, version => $App::PerlGraph::VERSION },
            instructions    => INSTRUCTIONS,
        });
    }
    if ($method eq 'tools/list') {
        return $self->_result($id, { tools => [
            map { +{ name => $_->{name}, description => $_->{description}, inputSchema => $_->{inputSchema} } } @TOOLS
        ] });
    }
    if ($method eq 'tools/call') { return $self->_call_tool($id, $req->{params} // {}) }
    return $self->_error($id, -32601, "Method not found: $method");
}

sub _maybe_sync ($self) {
    return unless $self->watch && $self->indexer;
    my $now = time;
    return if defined $self->{_last_sync} && $now - $self->{_last_sync} < 2;   # debounce
    $self->{_last_sync} = $now;
    eval { $self->indexer->sync };   # fail-soft: stale data beats a crashed server
}

sub _call_tool ($self, $id, $params) {
    $self->_maybe_sync;
    my $name = $params->{name} // '';
    my ($tool) = grep { $_->{name} eq $name } @TOOLS;
    return $self->_error($id, -32602, "Unknown tool: $name") unless $tool;
    my $text = eval { $self->_run_tool($tool->{handler}, $params->{arguments} // {}) };
    return $self->_result($id, { content => [{ type => 'text', text => "Error: $@" }], isError => \1 }) if $@;
    return $self->_result($id, { content => [{ type => 'text', text => $text }] });
}

sub _run_tool ($self, $handler, $args) {
    my $q = $self->query or return "No index found. Run `pcg index` in the project root first.";
    my $sym = $args->{symbol} // '';
    return App::PerlGraph::Format::search($args->{query} // '', [ $q->search($args->{query} // '') ]) if $handler eq 'search';
    return App::PerlGraph::Format::callers($sym, [ $q->callers($sym) ]) if $handler eq 'callers';
    return App::PerlGraph::Format::callees($sym, [ $q->callees($sym) ]) if $handler eq 'callees';
    return App::PerlGraph::Format::impact($sym,  [ $q->impact($sym) ])  if $handler eq 'impact';
    return App::PerlGraph::Format::node_view($sym, [ $q->node_view($sym) ], $self->base) if $handler eq 'node';
    return App::PerlGraph::Format::explore($args->{query} // '', [ $q->explore($args->{query} // '') ], $self->base)
        if $handler eq 'explore';
    return App::PerlGraph::Format::unused([ $q->unused(all => $args->{all}) ]) if $handler eq 'unused';
    return App::PerlGraph::Format::path($args->{from} // '', $args->{to} // '', [ $q->path($args->{from} // '', $args->{to} // '') ])
        if $handler eq 'path';
    if ($handler eq 'affected') {
        my $files = ref $args->{files} eq 'ARRAY' ? $args->{files} : [];
        return App::PerlGraph::Format::affected($files, [ $q->affected($files, tests_only => $args->{tests_only}) ]);
    }
    die "unhandled tool: $handler\n";
}

sub run ($self) {
    my ($in, $out) = ($self->in, $self->out);
    # We do our own UTF-8 via Cpanel::JSON::XS->utf8, so byte-orient both handles
    # regardless of any ambient encoding layer (e.g. bin/pcg sets STDOUT utf8).
    binmode $in,  ':raw';
    binmode $out, ':raw';
    { my $old = select($out); $| = 1; select($old); }   # autoflush responses
    while (defined(my $line = readline $in)) {
        chomp $line;
        next unless length $line;
        my $req = eval { $self->_json->decode($line) } or next;
        my $resp = $self->dispatch($req);
        next unless defined $resp;
        print {$out} $self->_json->encode($resp), "\n";
    }
}

1;

__END__

=head1 NAME

App::PerlGraph::MCP - Model Context Protocol server over the graph

=head1 DESCRIPTION

A hand-rolled JSON-RPC 2.0 server over stdio that exposes the query API as MCP tools for AI agents.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
