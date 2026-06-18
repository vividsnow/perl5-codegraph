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

done_testing;
