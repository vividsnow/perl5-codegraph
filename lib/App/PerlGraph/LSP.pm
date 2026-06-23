package App::PerlGraph::LSP;
use v5.36;
our $VERSION = q{0.053};
use Moo;
use Cpanel::JSON::XS ();
use Path::Tiny qw(path);

# A minimal Language Server over the pcg graph: go-to-definition, find-references,
# hover and document symbols, answered from the *resolved* call graph -- so
# go-to-def follows the dynamic dispatch the resolver tied down, which a plain
# tags/parser LSP can't. Read-only; the graph is the source of truth (rebuilt by
# `pcg sync`/`pcg watch`), so we don't track in-editor document edits.

has query => (is => 'ro', required => 1);
has root  => (is => 'rw', default => sub { '.' });   # workspace root; refined on `initialize`
has in    => (is => 'ro', default => sub { \*STDIN });
has out   => (is => 'ro', default => sub { \*STDOUT });
has _json => (is => 'lazy');
sub _build__json ($self) { Cpanel::JSON::XS->new->utf8->canonical }

# LSP SymbolKind numbers
my %SYM_KIND = (package => 4, class => 5, method => 6, field => 8, function => 12, constant => 14, route => 12);

sub run ($self) {
    my ($in, $out) = ($self->in, $self->out);
    binmode $in, ':raw'; binmode $out, ':raw';
    { my $old = select($out); $| = 1; select($old); }
    while (defined(my $msg = $self->_read_message($in))) {
        my $resp = $self->dispatch($msg);
        $self->_write_message($out, $resp) if defined $resp;
        last if $self->{_exit};
    }
    return $self;
}

# --- LSP base protocol framing: `Content-Length: N\r\n\r\n` + exactly N bytes ---
sub _read_message ($self, $in) {
    my %h;
    while (defined(my $line = readline $in)) {
        $line =~ s/\r?\n\z//;
        last if $line eq '';
        $h{ lc $1 } = $2 if $line =~ /\A([\w-]+):\s*(.*)\z/;
    }
    my $len = $h{'content-length'};
    return undef unless defined $len && $len =~ /\A\d+\z/;
    my $body = '';
    while (length($body) < $len) {
        my $chunk;
        my $n = read $in, $chunk, $len - length($body);
        last unless $n;
        $body .= $chunk;
    }
    # A well-framed but malformed/non-object body is SKIPPED (return a method-less
    # message -- dispatch ignores it), not fatal: one bad frame must not kill the
    # server (run() exits only on a true EOF, which returns undef at the header above).
    my $msg = eval { $self->_json->decode($body) };
    return ref $msg eq 'HASH' ? $msg : {};
}

sub _write_message ($self, $out, $msg) {
    my $body = $self->_json->encode($msg);
    print {$out} "Content-Length: " . length($body) . "\r\n\r\n" . $body;
}

sub dispatch ($self, $msg) {
    my $method = $msg->{method} // return undef;
    my $id     = $msg->{id};
    my $is_req = defined $id;   # requests carry an id; notifications don't
    my $result = eval {
        if    ($method eq 'initialize')                 { $self->_initialize($msg->{params}) }
        elsif ($method eq 'shutdown')                   { undef }                     # null result
        elsif ($method eq 'textDocument/definition')    { $self->_definition($msg->{params}) }
        elsif ($method eq 'textDocument/references')    { $self->_references($msg->{params}) }
        elsif ($method eq 'textDocument/hover')         { $self->_hover($msg->{params}) }
        elsif ($method eq 'textDocument/documentSymbol'){ $self->_doc_symbols($msg->{params}) }
        elsif ($method eq 'workspace/symbol')           { $self->_workspace_symbols($msg->{params}) }
        elsif ($method eq 'exit')                       { $self->{_exit} = 1; return undef }
        elsif (!$is_req)                                { return undef }              # ignore other notifications
        else  { die { code => -32601, message => "method not found: $method" } }
    };
    return undef unless $is_req;                                                      # notifications: no response
    if (my $err = $@) {
        my $e = ref $err eq 'HASH' ? $err : { code => -32603, message => "$err" };
        return { jsonrpc => '2.0', id => $id, error => $e };
    }
    return { jsonrpc => '2.0', id => $id, result => $result };
}

sub _initialize ($self, $params) {
    my $root = $self->_uri_to_path($params->{rootUri}) // $params->{rootPath};
    $self->root($root) if defined $root && length $root;
    return {
        capabilities => {
            definitionProvider      => \1,
            referencesProvider      => \1,
            hoverProvider           => \1,
            documentSymbolProvider  => \1,
            workspaceSymbolProvider => \1,
            textDocumentSync        => 0,   # None: we answer from the graph, not buffer state
        },
        serverInfo => { name => 'pcg', version => $VERSION },
    };
}

sub _definition ($self, $params) {
    my ($file, $line) = $self->_loc($params) or return undef;
    return [ map { $self->_node_location($_) } $self->query->definition_at($file, $line) ];
}

sub _references ($self, $params) {
    my ($file, $line) = $self->_loc($params) or return undef;
    return [ map { $self->_location($_->{file}, $_->{line}, $_->{col}) }
             $self->query->references_at($file, $line) ];
}

sub _hover ($self, $params) {
    my ($file, $line) = $self->_loc($params) or return undef;
    my $n = $self->query->symbol_at($file, $line) or return undef;
    my $md = sprintf '**%s** _(%s)_', $n->{qualified_name} // $n->{name}, $n->{kind} // 'symbol';
    $md .= "\n\n```perl\n$n->{signature}\n```" if $n->{signature};
    if (my $doc = $n->{docstring}) { ($md .= "\n\n$doc") =~ s/\s+\z//; }
    return { contents => { kind => 'markdown', value => $md } };
}

sub _doc_symbols ($self, $params) {
    my $abs = $self->_uri_to_path($params->{textDocument}{uri}) or return [];
    my $rel = $self->_rel($abs);
    return [ map { {
        name     => $_->{qualified_name} // $_->{name},
        kind     => $SYM_KIND{ $_->{kind} // '' } // 12,
        location => $self->_node_location($_),
    } } grep { ($_->{kind} // '') ne 'file' } $self->query->store->nodes_in_file($rel) ];
}

sub _workspace_symbols ($self, $params) {
    my $q = $params->{query} // '';
    return [] unless length $q;
    return [ map { {
        name     => $_->{qualified_name} // $_->{name},
        kind     => $SYM_KIND{ $_->{kind} // '' } // 12,
        location => $self->_node_location($_),
    } } $self->query->store->symbols_like($q) ];
}

# --- position / URI helpers (LSP is 0-indexed; the graph is 1-indexed) ---
sub _loc ($self, $params) {
    my $abs = $self->_uri_to_path($params->{textDocument}{uri}) or return;
    my $line = ($params->{position}{line} // 0) + 1;
    return ($self->_rel($abs), $line);
}
sub _node_location ($self, $n) { $self->_location($n->{file_path}, $n->{start_line}, $n->{start_col}) }
sub _location ($self, $rel_file, $line, $col = undef) {
    my $l = ($line // 1) - 1; $l = 0 if $l < 0;
    my $c = ($col  // 1) - 1; $c = 0 if $c < 0;
    return { uri => $self->_path_to_uri($self->_abs($rel_file)),
        range => { start => { line => $l, character => $c }, end => { line => $l, character => $c } } };
}

sub _uri_to_path ($self, $uri) {
    return undef unless defined $uri && $uri =~ m{\Afile://};
    (my $p = $uri) =~ s{\Afile://}{};
    $p =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
    return $p;
}
sub _path_to_uri ($self, $abs) {
    (my $u = $abs) =~ s{([^A-Za-z0-9_.~/-])}{sprintf '%%%02X', ord $1}ge;
    return "file://$u";
}
sub _rel ($self, $abs) { path($abs)->relative(path($self->root)->absolute)->stringify }
sub _abs ($self, $rel) { path($self->root)->absolute->child($rel)->stringify }

1;

__END__

=head1 NAME

App::PerlGraph::LSP - a minimal Language Server backed by the pcg graph

=head1 DESCRIPTION

Answers C<textDocument/definition>, C<textDocument/references>,
C<textDocument/hover>, C<textDocument/documentSymbol> and C<workspace/symbol>
from the resolved pcg graph, so editor navigation follows the dynamic dispatch
the resolver tied down.
Read-only and stateless; the graph (kept fresh by C<pcg watch>) is the source of
truth, so in-editor edits are not tracked. Run via C<pcg lsp>.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
