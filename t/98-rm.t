use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Refactor;
use App::PerlGraph::Format;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

sub setup ($code) {
    my $d = tempdir; $d->child('lib')->mkpath; $d->child('.pcg')->mkpath;
    $d->child('lib/P.pm')->spew_utf8($code);
    my $st = App::PerlGraph::Store->new(path => $d->child('.pcg/graph.db')->stringify); $st->init;
    App::PerlGraph::Indexer->new(store => $st, root => "$d")->index_all;
    return ($d, App::PerlGraph::Refactor->new(store => $st, root => "$d"));
}

# run -> live -> _shared ; dead -> _helper, _shared
my ($d, $rf) = setup(<<'PL');
package P;
use v5.36;
sub run     { live() }
sub live    { _shared(); 1 }
sub dead    { _helper(); _shared() }
sub _helper { 42 }
sub _shared { 7 }
1;
PL

# a sub that is still called -> refused, with the caller listed
my $r1 = $rf->rm('P::live');
like  $r1->{error}, qr/still called/,        'a still-called sub is refused';
is    $r1->{blocked_by}, ['P::run'],         'the refusal lists the caller';

# a dead sub -> removed, and the now-dead PRIVATE helper it solely used cascades; the
# shared helper (also used by live) survives
my $r2 = $rf->rm('P::dead', apply => 1);
is $r2->{applied}, 2,                                                  'the dead sub and its sole-use helper are removed';
my %removed = map { ($_->{name} => $_) } @{ $r2->{removed} };
ok $removed{'P::dead'},                                                'the target is removed';
ok $removed{'P::_helper'} && $removed{'P::_helper'}{cascade},          '_helper cascades (only dead used it)';
ok !$removed{'P::_shared'},                                            '_shared survives (live still uses it)';

my $after = $d->child('lib/P.pm')->slurp_utf8;
unlike $after, qr/sub\s+dead/,    'dead is gone from disk';
unlike $after, qr/sub\s+_helper/, '_helper is gone from disk';
like   $after, qr/sub\s+_shared/, '_shared remains';
like   $after, qr/sub\s+live/,    'live remains';
ok eval { $parser->parse_string($d->child('lib/P.pm')->slurp_raw); 1 }, 'the file still parses';

# dry-run writes nothing
my ($d2, $rf2) = setup("package P;\nsub orphan { my \$x = 1; \$x + 1 }\n1;\n");
my $dry = $rf2->rm('P::orphan');
is $dry->{applied}, 0,                                  'dry-run applies nothing';
is scalar @{ $dry->{removed} }, 1,                      'dry-run still reports the plan';
like $d2->child('lib/P.pm')->slurp_utf8, qr/sub\s+orphan/, 'dry-run leaves the file unchanged';

# an exported sub is refused (it may have out-of-repo consumers)
my ($d3, $rf3) = setup("package P;\nuse Exporter 'import';\nour \@EXPORT_OK = qw(api);\nsub api { my \$x = 1; \$x }\n1;\n");
like $rf3->rm('P::api')->{error}, qr/exported/, 'an exported sub is refused';

like App::PerlGraph::Format::rm($r2), qr/Remove `P::dead`/, 'renders a header';

done_testing;
