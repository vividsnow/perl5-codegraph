use v5.36;
use Test2::V0;
use Path::Tiny qw(path);
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

# a multi-file project with cross-file calls/inheritance (so resolution matters)
my $dir = Path::Tiny->tempdir;
for my $i (1 .. 16) {
    my $base = $i > 1 ? "Pkg" . ($i - 1) : "";
    my $isa  = $base ? "use parent -norequire, '$base';\n" : "";
    my $call = $base ? "${base}::run();" : "1;";
    path($dir, "lib/Pkg$i.pm")->parent->mkpath;
    path($dir, "lib/Pkg$i.pm")->spew(
        "package Pkg$i;\n${isa}use constant K$i => $i;\nsub run { helper(); $call }\nsub helper { K$i }\n1;\n");
}

# a stable signature of the whole graph (node ids are content-hashed -> order-independent)
sub signature ($jobs) {
    my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
    my $stats = App::PerlGraph::Indexer->new(store => $s, root => "$dir", jobs => $jobs)->index_all;
    my $nodes = join "\n", sort map { "$_->[0]|$_->[1]|$_->[2]" }
        @{ $s->dbh->selectall_arrayref("select kind, qualified_name, file_path from nodes") };
    my $edges = join "\n", sort map { "$_->[0]|$_->[1]|$_->[2]" }
        @{ $s->dbh->selectall_arrayref("select source, target, kind from edges") };
    return { stats => $stats, sig => "$nodes\n==EDGES==\n$edges",
             ncall => scalar @{ $s->dbh->selectall_arrayref("select 1 from edges where kind='calls'") } };
}

my $serial = signature(1);
my $par2   = signature(2);
my $par4   = signature(4);

is $par2->{sig}, $serial->{sig}, 'jobs=2 produces a byte-identical graph to jobs=1';
is $par4->{sig}, $serial->{sig}, 'jobs=4 produces a byte-identical graph to jobs=1';
ok $serial->{ncall} > 0, 'cross-file calls were actually resolved (the test is meaningful)';
is $par4->{stats}{files}, 16, 'all files counted';

# unchanged-skip still works under parallelism: a second pass re-indexes nothing
{
    my $s = App::PerlGraph::Store->new(path => path($dir, 'reindex.db') . "");
    $s->init;
    my $idx = App::PerlGraph::Indexer->new(store => $s, root => "$dir", jobs => 4);
    my $first = $idx->index_all;
    my $again = $idx->index_all;
    is $first->{reindexed}, 16, 'first parallel index processes every file';
    is $again->{reindexed}, 0,  'second parallel index skips unchanged files (hash-skip preserved)';

    # a stale extraction_version (an older pcg) forces re-extraction even under parallelism
    $s->dbh->do('update files set extraction_version = 0');
    is $idx->index_all->{reindexed}, 16, 'a version-stale graph is fully re-extracted in the parallel path';
    is $idx->index_all->{reindexed}, 0,  '... and is fresh again afterwards';
}

# the parallel path is actually selected for explicit --jobs (not silently serial)
{
    my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
    my $mk = sub ($j) { App::PerlGraph::Indexer->new(store => $s, root => "$dir", jobs => $j) };
    is $mk->(4)->_effective_jobs(100), 4, 'explicit jobs=4 selects 4 workers';
    is $mk->(4)->_effective_jobs(5),   4, 'explicit jobs is honored even for a few files';
    is $mk->(1)->_effective_jobs(9999), 1, 'jobs=1 forces serial';
    is $mk->(0)->_effective_jobs(10),   1, 'auto mode keeps a small tree serial';
}

# fork-safety: a worker that DIES mid-extract must exit via POSIX::_exit, never escape
# the child block to run on as a rogue process. (Without the guard the child would
# unwind past the fork block and re-enter this test harness as a second runner.) We make
# extraction die for one file in a forced-parallel run and confirm the failure surfaces
# in the single PARENT process -- the test itself completing once proves no child ran on.
{
    package DieMidExtract;
    use parent -norequire, 'App::PerlGraph::Indexer';
    sub _extract_src ($self, $path, $src, $hash) {
        die "boom\n" if $path =~ /die_here/;
        return $self->SUPER::_extract_src($path, $src, $hash);
    }
}
my $fd = Path::Tiny->tempdir; $fd->child('lib')->mkpath;
$fd->child('lib/die_here.pm')->spew_utf8("package DieHere;\nsub x { 1 }\n1;\n");
$fd->child("lib/Ok$_.pm")->spew_utf8("package Ok$_;\nsub y { 1 }\n1;\n") for 1 .. 70;   # >=64 -> parallel
my $fs = App::PerlGraph::Store->new(path => ':memory:'); $fs->init;
my $survived = eval { DieMidExtract->new(store => $fs, root => "$fd", jobs => 2)->index_all; 1 };
ok !$survived, 'a worker dying mid-extract surfaces in the parent (clean _exit), not as a rogue child';

done_testing;
