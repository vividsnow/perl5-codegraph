use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use Cpanel::JSON::XS ();
use IPC::Open2;
use App::PerlGraph::Parser;
use App::PerlGraph::CLI;

# End-to-end through the REAL `pcg lsp` binary + LSP framing, the way an editor
# drives it: index a project, then initialize / didOpen / go-to-definition / exit
# over Content-Length-framed stdio, and confirm the definition lands on the right
# file + line. The closest portable proxy for an actual editor client.
my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

my $dir = tempdir;
$dir->child('lib')->mkpath;
$dir->child('lib/A.pm')->spew_utf8("package A;\nsub run {\n    B::help();\n}\n1;\n");   # call on line 3
$dir->child('lib/B.pm')->spew_utf8("package B;\nsub help { 1 }\n1;\n");                 # def  on line 2

{ open my $fh, '>', \my $o; local *STDOUT = $fh; App::PerlGraph::CLI->run('index', "$dir"); }   # build .pcg/graph.db

my $enc  = Cpanel::JSON::XS->new->utf8->canonical;
my $uriA = "file://$dir/lib/A.pm";
my @msgs = (
    { jsonrpc => '2.0', id => 1, method => 'initialize',  params => { rootUri => "file://$dir" } },
    { jsonrpc => '2.0', method => 'initialized', params => {} },
    { jsonrpc => '2.0', method => 'textDocument/didOpen',
      params => { textDocument => { uri => $uriA, languageId => 'perl', version => 1,
                                    text => $dir->child('lib/A.pm')->slurp_utf8 } } },
    { jsonrpc => '2.0', id => 2, method => 'textDocument/definition',
      params => { textDocument => { uri => $uriA }, position => { line => 2, character => 4 } } },  # the B::help() call (LSP line 2)
    { jsonrpc => '2.0', method => 'exit' },
);
my $feed = join '', map { my $b = $enc->encode($_); "Content-Length: " . length($b) . "\r\n\r\n" . $b } @msgs;

my $pid = open2(my $out, my $in, $^X, '-Ilib', 'bin/pcg', 'lsp', "$dir");
binmode $in;  print $in $feed;  close $in;
binmode $out; local $/; my $raw = <$out> // ''; waitpid $pid, 0;

# unframe the Content-Length-delimited responses
my @resp;
while ($raw =~ /Content-Length:\s*(\d+)\r\n\r\n/gc) {
    my $body = substr $raw, pos($raw), $1;
    pos($raw) += $1;
    push @resp, scalar eval { $enc->decode($body) };
}
my ($init) = grep { ($_->{id} // 0) == 1 } @resp;
my ($def)  = grep { ($_->{id} // 0) == 2 } @resp;

ok $init && $init->{result}{capabilities}{definitionProvider}, 'real binary: initialize advertises definitionProvider';
ok $def  && $def->{result} && @{ $def->{result} },             'real binary: go-to-definition returned a location';
like $def->{result}[0]{uri}, qr{lib/B\.pm$},                   '... resolved across files into B.pm';
is   $def->{result}[0]{range}{start}{line}, 1,                 '... at B::help (graph line 2 -> LSP line 1)';

done_testing;
