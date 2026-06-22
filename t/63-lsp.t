use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use Cpanel::JSON::XS ();
use App::PerlGraph::Store;
use App::PerlGraph::Query;
use App::PerlGraph::LSP;

my $root = tempdir;   # absolute path, for file:// URI round-tripping
my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
$s->insert_node({ id => 'run',  kind => 'function', name => 'run',  qualified_name => 'P::run',
    file_path => 'lib/P.pm', start_line => 2, end_line => 4 });
$s->insert_node({ id => 'help', kind => 'function', name => 'help', qualified_name => 'P::help',
    file_path => 'lib/P.pm', start_line => 6, end_line => 8, signature => '($x)', docstring => 'the helper' });
$s->insert_edge({ source => 'run', target => 'help', kind => 'calls', line => 3, col => 5, provenance => 'static' });

my $lsp = App::PerlGraph::LSP->new(query => App::PerlGraph::Query->new(store => $s), root => "$root");
my $uri = "file://$root/lib/P.pm";
sub req ($method, $params, $id = 1) { { jsonrpc => '2.0', id => $id, method => $method, params => $params } }
sub at  ($line) { { textDocument => { uri => $uri }, position => { line => $line, character => 0 } } }

# initialize advertises the four navigation capabilities
my $init = $lsp->dispatch(req('initialize', { rootUri => "file://$root" }));
ok $init->{result}{capabilities}{definitionProvider}, 'advertises definitionProvider';
ok $init->{result}{capabilities}{referencesProvider}, 'advertises referencesProvider';
is $init->{result}{serverInfo}{name}, 'pcg',          'serverInfo names pcg';

# go-to-definition: cursor on the call (LSP line 2 = graph 3) -> help's def (graph 6 = LSP 5)
my $def = $lsp->dispatch(req('textDocument/definition', at(2)));
is scalar(@{ $def->{result} }), 1,                 'one definition location';
is $def->{result}[0]{uri}, $uri,                   '... in the same file (uri round-trips)';
is $def->{result}[0]{range}{start}{line}, 5,       '... at help def (0-indexed line 5)';
is $lsp->dispatch(req('textDocument/definition', at(6)))->{result}, [], 'no definition off a call site';

# find-references: cursor on help def name (LSP 5 = graph 6) -> the call site (graph 3 = LSP 2)
my $refs = $lsp->dispatch(req('textDocument/references', at(5)));
is scalar(@{ $refs->{result} }), 1,                'one reference location';
is $refs->{result}[0]{range}{start}{line}, 2,      '... at the call-site line (LSP 2)';
is $refs->{result}[0]{range}{start}{character}, 4, '... at the call-site column (col 5 -> 0-indexed 4)';

# hover renders the symbol + signature + doc
my $hov = $lsp->dispatch(req('textDocument/hover', at(5)));
like $hov->{result}{contents}{value}, qr/\*\*P::help\*\*/, 'hover names the symbol';
like $hov->{result}{contents}{value}, qr/\(\$x\)/,         'hover shows the signature';
like $hov->{result}{contents}{value}, qr/the helper/,      'hover shows the docstring';

# documentSymbol: both subs, with LSP SymbolKind numbers
my $ds = $lsp->dispatch(req('textDocument/documentSymbol', { textDocument => { uri => $uri } }));
is scalar(@{ $ds->{result} }), 2,                                       'two document symbols';
ok +(grep { $_->{name} eq 'P::run' && $_->{kind} == 12 } @{ $ds->{result} }), 'run is a Function (kind 12)';

# workspace/symbol: project-wide substring symbol search (editor "go to symbol")
ok $init->{result}{capabilities}{workspaceSymbolProvider}, 'advertises workspaceSymbolProvider';
my $ws = $lsp->dispatch(req('workspace/symbol', { query => 'help' }));
ok +(grep { $_->{name} eq 'P::help' } @{ $ws->{result} }), 'workspace/symbol finds P::help by substring';
ok +(grep { $_->{location}{uri} eq $uri } @{ $ws->{result} }), '... with a resolvable location';
is scalar(@{ $lsp->dispatch(req('workspace/symbol', { query => 'zzqq' }))->{result} }), 0, 'workspace/symbol: no match -> empty';
is scalar(@{ $lsp->dispatch(req('workspace/symbol', { query => '' }))->{result} }), 0, 'workspace/symbol: empty query -> empty';

# a real editor's didOpen / didChange notifications are safely ignored (no response, no crash)
is $lsp->dispatch({ jsonrpc => '2.0', method => 'textDocument/didOpen',
    params => { textDocument => { uri => $uri, languageId => 'perl', version => 1, text => "1;\n" } } }),
   undef, 'a textDocument/didOpen notification is ignored';

# protocol edges: shutdown -> null; unknown method -> error; notification -> no response
ok exists $lsp->dispatch(req('shutdown', undef, 9))->{result}, 'shutdown returns a (null) result';
is $lsp->dispatch(req('shutdown', undef, 9))->{result}, undef,  'shutdown result is null';
is $lsp->dispatch(req('no/such', {}, 10))->{error}{code}, -32601, 'unknown request method -> method-not-found';
is $lsp->dispatch({ jsonrpc => '2.0', method => 'initialized', params => {} }), undef, 'a notification gets no response';

# base-protocol framing: read a Content-Length-framed message and write one back
my $body = Cpanel::JSON::XS->new->utf8->canonical->encode(req('textDocument/definition', at(2)));
open my $rfh, '<', \(my $wire = "Content-Length: " . length($body) . "\r\n\r\n" . $body);
is $lsp->_read_message($rfh)->{method}, 'textDocument/definition', 'reads a framed message';
open my $wfh, '>', \my $wbuf;
$lsp->_write_message($wfh, { ok => \1 });
like $wbuf, qr/\AContent-Length: \d+\r\n\r\n\{/, 'writes Content-Length framing';

# full run() loop over in-memory handles: an `initialize` then `exit` notification
my $enc = Cpanel::JSON::XS->new->utf8->canonical;
my $feed = '';
for my $m (req('initialize', { rootUri => "file://$root" }, 1), { jsonrpc => '2.0', method => 'exit' }) {
    my $b = $enc->encode($m);
    $feed .= "Content-Length: " . length($b) . "\r\n\r\n" . $b;
}
open my $ih, '<', \$feed;
open my $oh, '>', \my $ob;
App::PerlGraph::LSP->new(query => App::PerlGraph::Query->new(store => $s), root => "$root",
    in => $ih, out => $oh)->run;
like $ob, qr/Content-Length: \d+\r\n\r\n.*definitionProvider/s, 'run() answers initialize and stops on exit';

# a well-framed but MALFORMED body must be skipped, not kill the server: a bad frame
# followed by a valid initialize still gets answered (regression -- it used to exit).
my $good = $enc->encode(req('initialize', { rootUri => "file://$root" }, 7));
my $exit = $enc->encode({ jsonrpc => '2.0', method => 'exit' });
my $feed2 = "Content-Length: 5\r\n\r\nHELLO"
    . "Content-Length: " . length($good) . "\r\n\r\n" . $good
    . "Content-Length: " . length($exit) . "\r\n\r\n" . $exit;
open my $ih2, '<', \$feed2;
open my $oh2, '>', \my $ob2;
App::PerlGraph::LSP->new(query => App::PerlGraph::Query->new(store => $s), root => "$root",
    in => $ih2, out => $oh2)->run;
like $ob2, qr/"id":7/, 'a malformed frame is skipped (not fatal) -- the next valid request is still answered';

done_testing;
