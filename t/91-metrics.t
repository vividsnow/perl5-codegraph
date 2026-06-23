use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Query;
use App::PerlGraph::Format;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

my $d = tempdir; $d->child('lib')->mkpath; $d->child('.pcg')->mkpath;
$d->child('lib/P.pm')->spew_utf8(<<'PL');
package P;
sub alpha { my ($x) = @_; $x > 0 ? ($x > 1 ? 'big' : 'one') : 'none' }
sub _helper { 42 }
1;
PL
my $s = App::PerlGraph::Store->new(path => $d->child('.pcg/graph.db')->stringify); $s->init;
App::PerlGraph::Indexer->new(store => $s, root => "$d")->index_all;
my $m = App::PerlGraph::Query->new(store => $s)->metrics;

is $m->{subs}, 2,            'counts the subs (alpha + _helper)';
ok $m->{public_api} >= 1,   'public API counted (alpha is public)';
ok $m->{nodes} > 0,         'scale: node count present';
for my $pct (qw(tested_pct documented_pct resolved_pct)) {
    ok $m->{$pct} >= 0 && $m->{$pct} <= 100, "$pct is a percentage in [0,100]";
}
ok exists $m->{$_}, "metric `$_` present" for qw(cycles unused clone_groups complex max_complexity untested undocumented);

my $txt = App::PerlGraph::Format::metrics($m);
like $txt, qr/Code health metrics/,          'format: header';
like $txt, qr/\*\*Scale\*\* -- \d+ files/,    'format: scale line';
like $txt, qr/\*\*Resolution\*\*.*%/,         'format: resolution line';
like $txt, qr/test coverage:/,                'format: coverage line';
like $txt, qr/Concerns:|No major concerns/,   'format: concerns summary';

done_testing;
