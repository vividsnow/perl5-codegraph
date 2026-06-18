use v5.36;
use Test2::V0;
use Time::HiRes qw(time);
use Path::Tiny qw(tempdir);
use App::PerlGraph::Runtime;
use App::PerlGraph::Store;

# --runtime executes the target code. Verify its fork + alarm timeout actually
# contains hostile / hanging code (a BEGIN that never returns) instead of
# wedging the indexer -- the safety promise the README makes.
my $dir = tempdir;
$dir->child('lib')->mkpath;

sub introspect_within ($body, $pkg) {
    $dir->child("lib/$pkg.pm")->spew("package $pkg;\n$body\nsub f { 1 }\n1;\n");
    my $t0 = time;
    my $res = eval {
        App::PerlGraph::Runtime->new(lib_dirs => [ $dir->child('lib')->stringify ], timeout => 2)
            ->introspect([ $dir->child("lib/$pkg.pm")->stringify ], [$pkg]);
    };
    return (time - $t0, $res);
}

# sanity: a benign module introspects -- otherwise the env lacks runtime deps
my ($t_ok, $ok) = introspect_within('# benign', 'Benign');
skip_all "runtime introspection unavailable" unless $ok;

my ($t_loop) = introspect_within('BEGIN { my $x = 0; $x++ while 1 }', 'EvilLoop');
ok $t_loop < 6, sprintf('a BEGIN tight Perl loop is killed by the timeout (%.1fs, not a hang)', $t_loop);

my ($t_sleep) = introspect_within('BEGIN { sleep 1000 }', 'EvilSleep');
ok $t_sleep < 6, sprintf('a BEGIN C-level sleep is killed by the timeout (%.1fs, not a hang)', $t_sleep);

# reaching here at all means hostile code was contained, not fatal to the parent
ok 1, 'hostile runtime code is contained (fail-soft), the indexer is not wedged';

# concurrency: a second connection sees a writer's committed data (WAL + NORMAL).
# A query process and an indexing process share the .pcg/graph.db this way.
{
    my $db = $dir->child('concur.db')->stringify;
    my $w  = App::PerlGraph::Store->new(path => $db); $w->init;
    my $r  = App::PerlGraph::Store->new(path => $db);                 # independent connection
    $w->insert_node({ id => 'x', kind => 'function', name => 'foo',
        qualified_name => 'P::foo', file_path => 'p.pm', start_line => 1 });
    ok scalar($r->nodes_by_qname('P::foo')),
        'a second connection sees a committed write (concurrent reader during indexing)';
}

done_testing;
