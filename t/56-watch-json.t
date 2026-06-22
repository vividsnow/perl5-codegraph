use v5.36;
use Test2::V0;
use Path::Tiny qw(path);
use Cpanel::JSON::XS qw(decode_json);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::CLI;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

# --- sync returns the add / change / delete lists ---------------------------
my $dir = Path::Tiny->tempdir;
$dir->child('lib')->mkpath;
$dir->child('lib/A.pm')->spew("package A;\nsub a { 1 }\n");
$dir->child('lib/B.pm')->spew("package B;\nsub b { 1 }\n");

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
my $idx = App::PerlGraph::Indexer->new(store => $store, root => "$dir");
$idx->index_all;

$dir->child('lib/A.pm')->spew("package A;\nsub a { 2 }\n");   # modified
$dir->child('lib/C.pm')->spew("package C;\nsub c { 1 }\n");   # added
$dir->child('lib/B.pm')->remove;                              # deleted

my $st = $idx->sync;
is [ sort @{ $st->{changes}{added} } ],   ['lib/C.pm'], 'sync reports the added file';
is [ sort @{ $st->{changes}{changed} } ], ['lib/A.pm'], 'sync reports the modified file';
is [ sort @{ $st->{changes}{deleted} } ], ['lib/B.pm'], 'sync reports the deleted file';

# --- `pcg watch --once --json` emits a structured event ---------------------
my $proj = Path::Tiny->tempdir;
$proj->child('lib')->mkpath; $proj->child('t')->mkpath;
$proj->child('lib/Foo.pm')->spew("package Foo;\nsub run { 1 }\n");
$proj->child('t/01.t')->spew("use Foo;\nFoo::run();\n");

sub capture {
    my $code = shift;
    my $buf = '';
    { local *STDOUT; open STDOUT, '>', \$buf or die $!; $code->(); }
    return $buf;
}
capture(sub { App::PerlGraph::CLI->run('index', "$proj") });        # build $proj/.pcg (quietly)
$proj->child('lib/Foo.pm')->spew("package Foo;\nsub run { 2 }\n");  # change it
my $out = capture(sub { App::PerlGraph::CLI->run('watch', '--once', '--json', "$proj") });

my ($line) = grep { /\S/ } split /\n/, $out;
my $ev = eval { decode_json($line) };
ok $ev, 'watch --once --json emits a JSON object' or diag "got: $out";
ok scalar(grep { m{lib/Foo\.pm$} } @{ $ev->{changed} // [] }), 'event lists the changed file';
ok exists $ev->{affected_tests}, 'event carries affected_tests';
ok scalar(grep { m{t/01\.t$} } @{ $ev->{affected_tests} // [] }), 'the test that exercises Foo is in affected_tests';

# a newly ADDED file appears in event.added
$proj->child('lib/New.pm')->spew("package New;\nsub n { 1 }\n");
my $aout = capture(sub { App::PerlGraph::CLI->run('watch', '--once', '--json', "$proj") });
my ($aline) = grep { /\S/ } split /\n/, $aout;
my $aev = eval { decode_json($aline) } // {};
ok scalar(grep { m{lib/New\.pm$} } @{ $aev->{added} // [] }), 'a newly added file appears in event.added';

# a DELETED file appears in event.deleted
$proj->child('lib/New.pm')->remove;
my $dout = capture(sub { App::PerlGraph::CLI->run('watch', '--once', '--json', "$proj") });
my ($dline) = grep { /\S/ } split /\n/, $dout;
my $dev = eval { decode_json($dline) } // {};
ok scalar(grep { m{lib/New\.pm$} } @{ $dev->{deleted} // [] }), 'a removed file appears in event.deleted';

# no change -> no event at all (a defined contract for a line-oriented monitor)
my $quiet = capture(sub { App::PerlGraph::CLI->run('watch', '--once', '--json', "$proj") });
is $quiet, '', 'watch --once --json with no changes emits nothing';

done_testing;
