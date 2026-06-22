use v5.36;
use Test2::V0;
use Path::Tiny qw(path tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::CLI;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

sub cap     { my $c = shift; my $b = ''; { local *STDOUT; open STDOUT, '>', \$b or die $!; $c->() } $b }
sub cap_err { my $c = shift; my $b = ''; { local *STDERR; open STDERR, '>', \$b or die $!; $c->() } $b }

my $proj = Path::Tiny->tempdir;
$proj->child('lib')->mkpath; $proj->child('t')->mkpath;
$proj->child('lib/Foo.pm')->spew("package Foo;\nuse Bar;\nsub run { help() }\nsub help { 1 }\nsub use_obj { my \$o = shift; \$o->help }\n");
$proj->child('lib/Bar.pm')->spew("package Bar;\nsub go { 1 }\n");
$proj->child('t/01.t')->spew("use Foo;\nFoo::run();\n");
cap(sub { App::PerlGraph::CLI->run('index', "$proj") });

# the query commands added in 0.003+ dispatch through CLI->run() and render
like cap(sub { App::PerlGraph::CLI->run('deps',   'Foo',      "$proj") }), qr/imports.*Bar/s,                 'pcg deps renders module deps';
like cap(sub { App::PerlGraph::CLI->run('cycles',             "$proj") }), qr/Circular module dependencies/,  'pcg cycles renders';
like cap(sub { App::PerlGraph::CLI->run('api',    'Foo',      "$proj") }), qr/API of Foo/,                    'pcg api renders';
like cap(sub { App::PerlGraph::CLI->run('covers', 'Foo::run', "$proj") }), qr/Tests covering Foo::run/,       'pcg covers renders';
like cap(sub { App::PerlGraph::CLI->run('unresolved',         "$proj") }), qr/Unresolved method calls/,       'pcg unresolved renders';
like cap(sub { App::PerlGraph::CLI->run('unresolved', '--name',  'help', "$proj") }), qr/\$o->help/, 'pcg unresolved --name filters';
like cap(sub { App::PerlGraph::CLI->run('unresolved', '--limit', '1',    "$proj") }), qr/\$o->help/, 'pcg unresolved --limit threads through';
like cap(sub { App::PerlGraph::CLI->run('unresolved', '--by-receiver',   "$proj") }), qr/Resolve hints|opaque receivers/, 'pcg unresolved --by-receiver uses the receiver-hints renderer';

# --runtime threads through the CLI into the indexer (and is announced); a trivial,
# self-contained fixture keeps the optree-loading enrichment safe.
{
    my $rt = tempdir; $rt->child('lib')->mkpath;
    $rt->child('lib/T.pm')->spew_utf8("package T;\nsub run { helper() }\nsub helper { 1 }\n1;\n");
    like cap(sub { App::PerlGraph::CLI->run('index', '--runtime', "$rt") }),
        qr/runtime enrichment/, 'pcg index --runtime threads the flag through and announces enrichment';
}

# api actually lists the module's surface; covers finds the test
like cap(sub { App::PerlGraph::CLI->run('api', 'Foo', "$proj") }), qr/Foo::run/,   'api lists a public sub';
like cap(sub { App::PerlGraph::CLI->run('covers', 'Foo::run', "$proj") }), qr/01\.t/, 'covers names the covering test';

# watch rejects an unknown flag instead of treating it as the root (consistency
# with every other command's flag guard)
my $rc;
my $err = cap_err(sub { $rc = App::PerlGraph::CLI->run('watch', '--bogus', "$proj") });
is $rc, 2,            'pcg watch --bogus -> usage exit code, not silently the root';
like $err, qr/usage:/, '... and prints usage to STDERR';

done_testing;
