use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Store;
use App::PerlGraph::Query;
use App::PerlGraph::Format;
use App::PerlGraph::CLI;

# hand-built call graph (no parser): hub() is called by a/b/c/spread (fan-in 4);
# spread() calls a/b/c/hub (fan-out 4).
my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
$s->insert_node({ id => $_, kind => 'function', name => $_, qualified_name => "P::$_",
    file_path => 'lib/P.pm', start_line => 1 }) for qw(hub a b c spread);
$s->insert_edge({ source => $_, target => 'hub', kind => 'calls', provenance => 'static' }) for qw(a b c spread);
$s->insert_edge({ source => 'spread', target => $_, kind => 'calls', provenance => 'static' }) for qw(a b c);
# a transitive layer: outer -> spread, so hub's BLAST RADIUS (5: a,b,c,spread,outer)
# exceeds its direct fan-in (4).
$s->insert_node({ id => 'outer', kind => 'function', name => 'outer', qualified_name => 'P::outer',
    file_path => 'lib/P.pm', start_line => 1 });
$s->insert_edge({ source => 'outer', target => 'spread', kind => 'calls', provenance => 'static' });
# packages with import deps, for the efferent-coupling (god-package) metric: A->B,C ; B->C
$s->insert_node({ id => "p$_", kind => 'package', name => $_, qualified_name => $_,
    file_path => "lib/$_.pm", start_line => 1 }) for qw(A B C);
$s->insert_edge({ source => 'pA', target => 'pB', kind => 'imports', provenance => 'static' });
$s->insert_edge({ source => 'pA', target => 'pC', kind => 'imports', provenance => 'static' });
$s->insert_edge({ source => 'pB', target => 'pC', kind => 'imports', provenance => 'static' });
# a branchy sub, for the "most complex" ranking
$s->insert_node({ id => 'cxfn', kind => 'function', name => 'cxfn', qualified_name => 'P::cxfn',
    file_path => 'lib/P.pm', start_line => 9, metadata => { complexity => 11 } });

my $q = App::PerlGraph::Query->new(store => $s);
my $h = $q->hotspots(limit => 3);

is $h->{fan_in}[0]{node}{qualified_name}, 'P::hub',    'highest fan-in is the hub';
is $h->{fan_in}[0]{count},                4,          'hub has 4 inbound callers';
is $h->{fan_in}[0]{impact},               5,          'hub blast radius is 5 transitive callers';
is $h->{packages}[0]{module},             'A',        'most efferently-coupled module is A';
is $h->{packages}[0]{count},              2,          'A depends on 2 modules';
is $h->{fan_out}[0]{node}{qualified_name}, 'P::spread','highest fan-out is the spreader';
is $h->{fan_out}[0]{count},               4,          'spread makes 4 outbound calls';
is $h->{complex}[0]{node}{qualified_name}, 'P::cxfn',  'most complex sub is cxfn';
is $h->{complex}[0]{cx},                  11,         '... at cyclomatic complexity 11';
ok @{ $h->{fan_in} } <= 3, 'limit caps each list';

# only callable nodes appear (a package/file node is never a hotspot row)
ok !(grep { ($_->{node}{kind} // '') !~ /function|method|constant/ } @{ $h->{fan_in} }),
   'fan-in rows are callables only';

# format
my $txt = App::PerlGraph::Format::hotspots($h);
like $txt, qr/Most depended-upon/,            'format: fan-in section header';
like $txt, qr/`P::hub`.*4 callers, 5 transitive/, 'format: hub with caller count + blast radius';
like $txt, qr/`P::spread`.*calls 4/,          'format: spread with its callee count';
like $txt, qr/Most coupled modules/,          'format: efferent-coupling section header';
like $txt, qr/`A`.*2 modules/,                'format: god-package A with its dep count';
like $txt, qr/Most complex.*`P::cxfn`.*complexity 11/s, 'format: most-complex section lists cxfn';
like App::PerlGraph::Format::hotspots({ fan_in => [], fan_out => [], packages => [], complex => [] }), qr/_none_/, 'format: empty graph';

# CLI glue (empty project -> still renders, exits 0; bad flag -> usage)
{
    my $dir = tempdir;
    path_init($dir);
    open my $fh, '>', \my $out; local *STDOUT = $fh;
    is App::PerlGraph::CLI->run('hotspots', "$dir"), 0, 'hotspots on an indexed project exits 0';
}
{
    open my $eh, '>', \my $err; local *STDERR = $eh;
    is App::PerlGraph::CLI->run('hotspots', '--bogus'), 2, 'hotspots rejects an unknown flag';
    is App::PerlGraph::CLI->run('hotspots', '--limit', '0'), 2, 'hotspots rejects --limit 0';
}

sub path_init ($dir) {
    my $db = Path::Tiny::path($dir)->child('.pcg/graph.db');
    $db->parent->mkpath;
    App::PerlGraph::Store->new(path => "$db")->init;
}

done_testing;
