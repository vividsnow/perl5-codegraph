use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir tempfile);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::MCP;
use App::PerlGraph::CLI;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

# A NON-git project that HAS an index: the git-history commands must fail cleanly
# (exit 1 + a stderr message), rather than crash or silently return nothing.
my $dir = tempdir;
$dir->child('lib')->mkpath;
$dir->child('lib/A.pm')->spew_utf8("package A;\nsub x { 1 }\n1;\n");

# Capture via real temp files: Git::_run dups STD{OUT,ERR} with '>&', which needs a
# real fd (an in-memory scalar filehandle can't be dup'd that way).
sub capture ($fh, @argv) {
    my $f = tempfile;
    open my $old, '>&', $fh; open $fh, '>', "$f" or die "redirect: $!";
    my $rc = App::PerlGraph::CLI->run(@argv);
    open $fh, '>&', $old;
    return ($rc, $f->slurp_utf8);
}

my ($idx_rc) = capture(\*STDOUT, 'index', "$dir");
is $idx_rc, 0, 'indexed the non-git project';

# risk/cochange take an optional [path]; diff/review take <ref> [path]
for my $c ([qw(risk)], [qw(cochange)], ['diff', 'HEAD'], ['review', 'HEAD']) {
    my ($cmd, @a) = @$c;
    my ($rc, $err) = capture(\*STDERR, $cmd, @a, "$dir");
    is $rc, 1,           "pcg $cmd in a non-git dir exits 1";
    like $err, qr/git/i, "pcg $cmd explains it needs git";
}

# MCP pcg_affected with `since` derives its file list from `git diff`, so it too
# needs a work tree -- and it must reach that check (not be stopped by the index gate).
my $store = App::PerlGraph::Store->new(path => $dir->child('.pcg/graph.db')->stringify)->init;
my $mcp = App::PerlGraph::MCP->new(indexer => App::PerlGraph::Indexer->new(store => $store, root => "$dir"), base => "$dir");
my $aff = $mcp->dispatch({ jsonrpc => '2.0', id => 1, method => 'tools/call',
    params => { name => 'pcg_affected', arguments => { since => 'HEAD' } } });
like $aff->{result}{content}[0]{text}, qr/git work tree/, 'MCP pcg_affected since=... reports the git requirement';

# --- happy paths: the git-history commands through CLI->run on a REAL repo with churn ---
SKIP: {
    skip "git unavailable", 9 unless eval { my $v = `git --version 2>/dev/null`; $? == 0 && $v =~ /git/ };
    my $g = tempdir; my @gc = ('git', '-C', "$g"); $g->child('lib')->mkpath;
    $g->child('lib/M.pm')->spew_utf8("package M;\nsub run { helper() }\nsub helper { 1 }\n1;\n");
    $g->child('lib/N.pm')->spew_utf8("package N;\nsub go { 1 }\n1;\n");
    system @gc, 'init', '-q'; system @gc, 'config', 'user.email', 't@t'; system @gc, 'config', 'user.name', 't';
    system @gc, 'add', '-A'; system @gc, 'commit', '-qm', 'v1';
    $g->child('lib/M.pm')->spew_utf8("package M;\nsub run { helper(); 2 }\nsub helper { 1 }\n1;\n");   # churn + co-change
    $g->child('lib/N.pm')->spew_utf8("package N;\nsub go { 2 }\n1;\n");
    system @gc, 'add', '-A'; system @gc, 'commit', '-qm', 'v2';
    $g->child('lib/M.pm')->spew_utf8("package M;\nsub run (\$x) { helper(); 2 }\nsub helper { 1 }\n1;\n");   # working-tree change
    capture(\*STDOUT, 'index', "$g");
    my ($rrc, $rout) = capture(\*STDOUT, 'risk', "$g");
    is $rrc, 0, 'pcg risk on a git repo exits 0';
    like $rout, qr/Risk|churn/i,      '... and renders risk output';
    my ($src) = capture(\*STDOUT, 'risk', '--since', 'HEAD~1', "$g");
    is $src, 0, 'pcg risk --since REF exits 0';
    my ($crc, $cout) = capture(\*STDOUT, 'cochange', "$g");
    is $crc, 0, 'pcg cochange on a git repo exits 0';
    like $cout, qr/Co-change/i,       '... and renders the co-change report';
    my ($drc, $dout) = capture(\*STDOUT, 'diff', 'HEAD', "$g");
    is $drc, 0, 'pcg diff <ref> exits 0';
    like $dout, qr/Diff vs HEAD/,     '... and renders the structural diff';
    my ($vrc, $vout) = capture(\*STDOUT, 'review', 'HEAD', "$g");
    is $vrc, 0, 'pcg review <ref> exits 0';
    like $vout, qr/Review/,           '... and renders the review';
}

done_testing;
