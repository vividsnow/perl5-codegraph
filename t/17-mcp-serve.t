use v5.36;
use Test2::V0;
use App::PerlGraph::Store;
use App::PerlGraph::Query;
use App::PerlGraph::MCP;
use Cpanel::JSON::XS qw(decode_json);

# Drive the real newline-framed run() loop through in-memory filehandles.
my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
$s->insert_node({ id => 'r', kind => 'function', name => 'run',  qualified_name => 'P::run',  file_path => 'f', start_line => 2 });
$s->insert_node({ id => 'h', kind => 'function', name => 'help', qualified_name => 'P::help', file_path => 'f', start_line => 5 });
$s->insert_edge({ source => 'r', target => 'h', kind => 'calls', provenance => 'static' });

my $input = join "\n",
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
    'this is not valid json {{{',                              # malformed line must not crash the loop
    '{"jsonrpc":"2.0","method":"notifications/initialized"}',
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"pcg_callers","arguments":{"symbol":"P::help"}}}',
    '';
open my $in,  '<', \$input or die;
my $out = '';
open my $ofh, '>', \$out   or die;

App::PerlGraph::MCP->new(
    query => App::PerlGraph::Query->new(store => $s),
    in => $in, out => $ofh,
)->run;
close $ofh;

my @lines = grep { length } split /\n/, $out;
is scalar(@lines), 2, 'two responses (the notification produced none)';
my $r1 = decode_json($lines[0]);
is $r1->{result}{protocolVersion}, '2024-11-05', 'line 1 is the initialize result';
my $r2 = decode_json($lines[1]);
like $r2->{result}{content}[0]{text}, qr/P::run/, 'line 2 is the pcg_callers result through the stdio loop';
done_testing;
