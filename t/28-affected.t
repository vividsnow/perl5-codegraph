use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Query;
use App::PerlGraph::CLI;

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

my $cap     = sub ($c) { open my $fh, '>', \my $o; local *STDOUT = $fh; $c->(); $o // '' };
my $cap_err = sub ($c) { open my $fh, '>', \my $o; local *STDERR = $fh; my $rc = $c->(); ($rc, $o // '') };

# --since: take the changed file set from `git diff --name-only REF` (CLI integration)
SKIP: {
    skip "git unavailable", 1 unless eval { my $v = `git --version 2>/dev/null`; $? == 0 && $v =~ /git/ };
    my $g = tempdir;
    $g->child('lib')->mkpath;
    $g->child('lib/A.pm')->spew_utf8("package A;\nsub helper { 1 }\n1;\n");
    $g->child('lib/B.pm')->spew_utf8("package B;\nuse A;\nsub run { A::helper() }\n1;\n");
    system @$_ for ['git','-C',"$g",'init','-q'], ['git','-C',"$g",'config','user.email','t@t'],
                   ['git','-C',"$g",'config','user.name','t'], ['git','-C',"$g",'add','-A'],
                   ['git','-C',"$g",'commit','-qm','init'];
    $cap->(sub { App::PerlGraph::CLI->run('index', "$g") });
    $g->child('lib/A.pm')->spew_utf8("package A;\nsub helper { 2 }\n1;\n");   # modify (uncommitted)
    my $out = $cap->(sub { App::PerlGraph::CLI->run('affected', '--since', 'HEAD', '--path', "$g") });
    like $out, qr{lib/B\.pm}, 'affected --since HEAD: the git-diffed change to A.pm pulls in B.pm';
}

# --since in a non-git dir is fail-soft: warns, yields no files -> usage exit (not a crash)
{
    my $ng = tempdir;
    my ($rc, $err) = $cap_err->(sub { App::PerlGraph::CLI->run('affected', '--since', 'HEAD', '--path', "$ng") });
    is $rc, 2, 'affected --since in a non-git dir -> usage exit (no files), no crash';
}

done_testing;
