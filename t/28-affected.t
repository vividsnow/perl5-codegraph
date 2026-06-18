use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Query;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built";

my $dir = tempdir;
$dir->child('lib')->mkpath;
$dir->child('lib/A.pm')->spew_utf8("package A;\nsub helper { 1 }\n1;\n");
$dir->child('lib/B.pm')->spew_utf8("package B;\nuse A;\nsub run { A::helper() }\n1;\n");
$dir->child('t')->mkpath;
$dir->child('t/a.t')->spew_utf8("use A;\nA::helper();\n");

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
App::PerlGraph::Indexer->new(store => $store, root => "$dir")->index_all;
my $q = App::PerlGraph::Query->new(store => $store);

# changing A.pm affects B.pm (calls A::helper) and t/a.t (calls A::helper)
my @aff = $q->affected(["lib/A.pm"]);   # git-relative path matched by suffix
ok( (grep { m{lib/B\.pm$} } @aff), 'B.pm affected by a change to A.pm' );
ok( (grep { m{t/a\.t$} }    @aff), 'test a.t affected' );

# --tests narrows to test files
my @tests = $q->affected(["lib/A.pm"], tests_only => 1);
ok( @tests && !(grep { !/\.t$/ } @tests), 'tests_only returns only .t files' );
ok( (grep { m{t/a\.t$} } @tests),         'a.t present in tests_only output' );
done_testing;
