use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

# Pathological huge files in a dep tree are almost always generated data (e.g.
# Module::CoreList: 18 subs, 25k data lines, ~2 minutes to parse) -- they
# dominate a large index for almost no code graph. --max-file-size skips them.
my $dir = tempdir;
$dir->child('lib')->mkpath;
$dir->child('lib/Small.pm')->spew("package Small;\nsub keep { 1 }\n1;\n");
$dir->child('lib/Big.pm')->spew("package Big;\nsub drop { 1 }\nour %data = (\n" . ("  k=>1,\n" x 40000) . ");\n1;\n");
ok -s $dir->child('lib/Big.pm') > 200_000, 'Big.pm is genuinely large (sanity)';

# default (unlimited): everything is indexed -- complete by default
my $all = App::PerlGraph::Store->new(path => ':memory:'); $all->init;
App::PerlGraph::Indexer->new(store => $all, root => "$dir")->index_all;
ok scalar($all->nodes_by_qname('Big::drop')),   'default unlimited: large file still indexed';
ok scalar($all->nodes_by_qname('Small::keep')), 'default unlimited: small file indexed';

# with a cap below Big.pm's size: Big is skipped, Small is kept
my $capped = App::PerlGraph::Store->new(path => ':memory:'); $capped->init;
{
    my @warn; local $SIG{__WARN__} = sub { push @warn, @_ };
    App::PerlGraph::Indexer->new(store => $capped, root => "$dir", max_file_size => 100_000)->index_all;
    ok( (grep { /skipping.*Big\.pm/ } @warn), 'a skipped file is announced (not silent)' );
}
ok  scalar($capped->nodes_by_qname('Small::keep')), 'under-cap file is indexed';
ok !scalar($capped->nodes_by_qname('Big::drop')),   'over-cap file is skipped';

done_testing;
