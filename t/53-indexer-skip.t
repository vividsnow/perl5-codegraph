use v5.36;
use Test2::V0;
use Path::Tiny qw(path);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

my $dir = Path::Tiny->tempdir;
$dir->child('.git')->mkpath;                                              # root IS a repo (must NOT be pruned)
$dir->child('lib')->mkpath;
$dir->child('lib/Main.pm')->spew("package Main;\nsub run { 1 }\n");
$dir->child('.vscode/perl-lang')->mkpath;                                 # editor-bundled Perl -> skip
$dir->child('.vscode/perl-lang/Ext.pm')->spew("package Ext;\nsub x { 1 }\n");
$dir->child('worktree/wt')->mkpath;
$dir->child('worktree/wt/.git')->spew("gitdir: ../../.git/worktrees/wt\n");  # nested worktree (.git FILE)
$dir->child('worktree/wt/Dup.pm')->spew("package Dup;\nsub y { 1 }\n");
$dir->child('vendored')->mkpath;
$dir->child('vendored/.git')->mkpath;                                     # nested clone (.git DIR)
$dir->child('vendored/Dep.pm')->spew("package Dep;\nsub z { 1 }\n");

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
App::PerlGraph::Indexer->new(store => $store, root => "$dir")->index_all;
my @paths = $store->file_paths;

ok  scalar(grep { m{lib/Main\.pm$} } @paths), 'real project code is indexed';
ok !scalar(grep { m{Ext\.pm$}      } @paths), '.vscode editor-bundled Perl is skipped';
ok !scalar(grep { m{Dup\.pm$}      } @paths), 'nested git worktree (.git file) is skipped';
ok !scalar(grep { m{Dep\.pm$}      } @paths), 'nested git repo (.git dir) is skipped';

is \@paths, [ grep { m{lib/Main\.pm$} } @paths ], 'only the one real file made it in';

done_testing;
