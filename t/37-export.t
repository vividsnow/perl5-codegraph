use v5.36;
use Test2::V0;
use Cpanel::JSON::XS ();
use App::PerlGraph::Store;
use App::PerlGraph::Query;
use App::PerlGraph::Format;
use App::PerlGraph::CLI;

# hand-built graph (no parser needed): a->b->c->d (calls), a->c (references), Pkg extends Base
my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
my %id = (a=>'na', b=>'nb', c=>'nc', d=>'nd', Pkg=>'npkg', Base=>'nbase', file=>'nfile');
$s->insert_node({ id=>$id{$_}, kind=>'function', name=>$_, qualified_name=>"P::$_", file_path=>'lib/P.pm', start_line=>1 })
    for qw(a b c d);
$s->insert_node({ id=>$id{Pkg},  kind=>'package', name=>'Pkg',  qualified_name=>'Pkg',  file_path=>'lib/Pkg.pm', start_line=>1 });
$s->insert_node({ id=>$id{Base}, kind=>'package', name=>'Base', qualified_name=>'Base', file_path=>'lib/Base.pm',start_line=>1 });
$s->insert_node({ id=>$id{file}, kind=>'file',    name=>'lib/P.pm', qualified_name=>'lib/P.pm', start_line=>1 });
# a route node whose label carries mermaid-hostile chars (" and ])
$s->insert_node({ id=>'nroute', kind=>'route', name=>'GET /x', qualified_name=>'P GET /a"b]c', file_path=>'lib/P.pm', start_line=>1 });
$s->insert_node({ id=>'nconst', kind=>'constant', name=>'MAX', qualified_name=>'P::MAX', file_path=>'lib/P.pm', start_line=>1 });
$s->insert_edge({ source=>$id{a}, target=>$id{b}, kind=>'calls',      provenance=>'static' });
$s->insert_edge({ source=>$id{b}, target=>$id{c}, kind=>'calls',      provenance=>'static' });
$s->insert_edge({ source=>$id{c}, target=>$id{d}, kind=>'calls',      provenance=>'static' });
$s->insert_edge({ source=>$id{a}, target=>$id{c}, kind=>'references', provenance=>'static' });
$s->insert_edge({ source=>$id{Pkg}, target=>$id{Base}, kind=>'extends', provenance=>'static' });
$s->insert_edge({ source=>'nroute', target=>$id{a}, kind=>'references', provenance=>'framework' });
$s->insert_edge({ source=>$id{a}, target=>'nconst', kind=>'calls', provenance=>'static' });
$s->insert_edge({ source=>$id{file}, target=>$id{a}, kind=>'contains', provenance=>'static' });  # noise

my $q = App::PerlGraph::Query->new(store => $s);

# --- full graph ---
my $g = $q->graph;
my %names = map { ($_->{qualified_name} => 1) } @{$g->{nodes}};
ok $names{'P::a'} && $names{'Pkg'} && $names{'Base'}, 'graph includes function and package nodes';
ok $names{'P GET /a"b]c'},                           'graph includes route nodes (endpoint context)';
ok $names{'P::MAX'},                                 'graph includes constant nodes (full-graph export)';
ok !$names{'lib/P.pm'},                              'graph excludes file nodes';
my %ek = map { ($_->{kind} => 1) } @{$g->{edges}};
ok $ek{calls} && $ek{references} && $ek{extends},   'graph includes calls/references/extends edges';
ok !$ek{contains},                                  'graph excludes structural contains edges';

# --- subgraph around a, depth 1: a + immediate neighbors (b via calls, c via references); NOT d ---
my $sub = $q->graph(around => 'P::a', depth => 1);
my %sn = map { ($_->{qualified_name} => 1) } @{$sub->{nodes}};
ok  $sn{'P::a'} && $sn{'P::b'} && $sn{'P::c'}, 'around(a,1) includes a and its immediate neighbors';
ok !$sn{'P::d'},                               'around(a,1) excludes nodes two hops away';

# --- mermaid ---
my $mer = App::PerlGraph::Format::export($g, 'mermaid');
like $mer, qr/^graph TD/,           'mermaid: header';
like $mer, qr/\["P::a"\]/,          'mermaid: quoted node label';
like $mer, qr/-->/,                 'mermaid: edges';
like $mer, qr/&quot;/,              'mermaid: escapes " in a label';
like $mer, qr/&#93;/,               'mermaid: escapes ] in a label';
unlike $mer, qr/\["[^"\n]*"[^"\n]*"\]/, 'mermaid: no raw inner quote breaks the label';

# --- dot ---
my $dot = App::PerlGraph::Format::export($g, 'dot');
like $dot, qr/^digraph/,            'dot: header';
like $dot, qr/"P::a"\s*->\s*"P::b"/,'dot: directed edge';

# --- json ---
my $json = App::PerlGraph::Format::export($g, 'json');
my $data = Cpanel::JSON::XS->new->decode($json);
ok ref $data->{nodes} eq 'ARRAY' && ref $data->{edges} eq 'ARRAY', 'json: nodes/edges arrays';
ok +(grep { $_->{from} eq 'P::a' && $_->{to} eq 'P::b' && $_->{kind} eq 'calls' } @{$data->{edges}}),
   'json: edge carries from/to/kind';

# --- CLI ---
my $rc;
{ open my $fh,'>',\my $out; local *STDERR=$fh;
  $rc = App::PerlGraph::CLI->run('export', '--format', 'badfmt');
}
is $rc, 2, 'unknown --format is a usage error';

{ open my $fh,'>',\my $err; local *STDERR=$fh;
  is App::PerlGraph::CLI->run('export', '--format'), 2, '--format with no value is a usage error';
}

# --- empty-result branches ---
is [ $q->cycles ], [], 'cycles: empty list when there are no import/inheritance cycles';
like App::PerlGraph::Format::cycles([]), qr/_none found_/, 'format cycles: no-cycles message';
is $q->graph(around => 'P::does_not_exist'), { nodes => [], edges => [] },
   'graph(around => unknown symbol) returns an empty graph';
like App::PerlGraph::Format::export({ nodes => [], edges => [] }, 'mermaid'), qr/graph TD/,
   'mermaid export of an empty graph is still valid';

# dot escapes a special char in a node label (the route node carries a `"`)
like $dot, qr/P GET \/a\\"b/, 'dot: escapes a " inside a node name';

# html: a self-contained interactive export -- valid HTML with the data injected inline
# (placeholder fully replaced) and no external/CDN script dependency
my $html = App::PerlGraph::Format::export($g, 'html');
like   $html, qr/<!DOCTYPE html>/,  'html export: a valid document';
like   $html, qr/const DATA = \{/,  'html export: the graph data is injected inline';
unlike $html, qr/__DATA__/,         'html export: the placeholder is fully replaced';
like   $html, qr/createElementNS/,  'html export: a self-contained inline renderer';
unlike $html, qr/<script\s+src=/,   'html export: no external/CDN dependency';
like   App::PerlGraph::Format::export({ nodes => [], edges => [] }, 'html'), qr/<!DOCTYPE html>/,
       'html export of an empty graph is still a valid document';

# CLI export flag validation (error paths)
{ open my $fh,'>',\my $err; local *STDERR=$fh;
  is App::PerlGraph::CLI->run('export', '--depth'),      2, 'export --depth with no value is a usage error';
  is App::PerlGraph::CLI->run('export', '--depth', 'x'), 2, 'export --depth non-numeric is a usage error';
  is App::PerlGraph::CLI->run('export', '--around'),     2, 'export --around with no value is a usage error';
}

done_testing;
