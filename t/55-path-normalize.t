use v5.36;
use Test2::V0;
use Path::Tiny qw(path);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

my $dir = Path::Tiny->tempdir;
$dir->child('lib')->mkpath;
$dir->child('lib/Foo.pm')->spew("package Foo;\nsub a { 1 }\n");
$dir->child('lib/Bar.pm')->spew("package Bar;\nsub b { 1 }\n");

# (1) indexing with an ABSOLUTE root stores paths canonically (relative to root),
# not prefixed with the absolute spelling.
my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
App::PerlGraph::Indexer->new(store => $store, root => "$dir")->index_all;
is [ sort $store->file_paths ], ['lib/Bar.pm', 'lib/Foo.pm'],
   'file paths stored relative to root regardless of absolute root spelling';
my ($foo) = $store->nodes_by_qname('Foo::a');
is $foo->{file_path}, 'lib/Foo.pm', 'node file_path is canonical too';

# (2) the bug: a sync under a DIFFERENT root spelling ('.') must NOT see every
# file as deleted/new (it did, because paths were keyed by the root spelling).
my $cwd = Path::Tiny->cwd;
chdir "$dir" or die "chdir: $!";
my $st = eval { App::PerlGraph::Indexer->new(store => $store, root => '.')->sync };
my $err = $@;
chdir "$cwd" or die "chdir back: $!";
die $err if $err;
is $st->{deleted},   0, 'no spurious deletions when index (abs root) and sync (".") spell the root differently';
is $st->{reindexed}, 0, 'and nothing re-indexed -- hashes match on the canonical key';

done_testing;
