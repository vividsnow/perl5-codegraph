use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Query;
use App::PerlGraph::Format;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

my $dir = tempdir; $dir->child('.pcg')->mkpath;
$dir->child('app.pl')->spew_utf8(<<'PL');
use Mojolicious::Lite;
get '/run'  => sub { my $c = shift; do_thing($c->param('x')) };
get '/safe' => sub { return 'ok' };
sub do_thing { my $x = shift; system("echo $x") }
sub query_db { my ($db, $id) = @_; $db->do("SELECT * FROM t WHERE id=$id") }
app->start;
PL
my $store = App::PerlGraph::Store->new(path => $dir->child('.pcg/graph.db')->stringify); $store->init;
App::PerlGraph::Indexer->new(store => $store, root => "$dir")->index_all;
my $r = App::PerlGraph::Query->new(store => $store)->sinks;

# both sink sites found and typed
is scalar @{ $r->{sites} }, 2, 'both sink sites found (command + sql)';
my %site = map { $_->{sub} => $_->{sinks}[0]{type} } @{ $r->{sites} };
is $site{'main::do_thing'}, 'command', 'system() typed as a command sink';
is $site{'main::query_db'}, 'sql',     '$db->do() typed as a sql sink';

# injection shape: both fixture sinks interpolate a variable into the string -> dynamic
my %dyn = map { $_->{sub} => $_->{sinks}[0]{dynamic} } @{ $r->{sites} };
ok $dyn{'main::do_thing'}, 'system("echo $x") -> flagged dynamic (interpolated argument)';
ok $dyn{'main::query_db'}, '$db->do("...$id") -> flagged dynamic (interpolated SQL)';

# attack surface: GET /run reaches the system() sink through do_thing; GET /safe does not
my ($run) = grep { $_->{route}{name} =~ m{GET /run} } @{ $r->{reachable} };
ok $run,                            'GET /run is on the attack surface';
is $run->{sinks}[0]{name}, 'system',         '... reaches system()';
is $run->{sinks}[0]{sub},  'main::do_thing', '... in do_thing';
ok !(grep { $_->{route}{name} =~ m{GET /safe} } @{ $r->{reachable} }),
   'GET /safe (reaches no sink) is not on the attack surface';

my $txt = App::PerlGraph::Format::sinks($r);
like $txt, qr/Reachable from an endpoint/,        'format: attack-surface section';
like $txt, qr/GET \/run.*system.*injection risk/, 'format: the reachable dynamic sink is flagged as injection risk';
like $txt, qr/All sink sites \(2, 2 with/,        'format: all-sites count + dynamic count';

# a parameterized / list-form sink is NOT flagged dynamic (the precision the taint upgrade adds)
my $sd = tempdir; $sd->child('lib')->mkpath; $sd->child('.pcg')->mkpath;
$sd->child('lib/Safe.pm')->spew_utf8(<<'PL');
package Safe;
sub query { my ($db, $id) = @_; $db->do("SELECT * FROM t WHERE id = ?", $id) }
sub run   { system("ls", "-l") }
1;
PL
my $ss = App::PerlGraph::Store->new(path => $sd->child('.pcg/graph.db')->stringify); $ss->init;
App::PerlGraph::Indexer->new(store => $ss, root => "$sd")->index_all;
my $sr = App::PerlGraph::Query->new(store => $ss)->sinks;
ok !(grep { grep { $_->{dynamic} } @{ $_->{sinks} } } @{ $sr->{sites} }),
   'a placeholdered DBI call and a list-form system() are NOT flagged dynamic';

# a non-web project with a sink but no routes: the site is listed, nothing reachable
my $d2 = tempdir; $d2->child('lib')->mkpath; $d2->child('.pcg')->mkpath;
$d2->child('lib/T.pm')->spew_utf8("package T;\nsub go { system('ls') }\n1;\n");
my $s2 = App::PerlGraph::Store->new(path => $d2->child('.pcg/graph.db')->stringify); $s2->init;
App::PerlGraph::Indexer->new(store => $s2, root => "$d2")->index_all;
my $r2 = App::PerlGraph::Query->new(store => $s2)->sinks;
is scalar @{ $r2->{sites} },     1, 'non-web: the sink site is still listed';
is scalar @{ $r2->{reachable} }, 0, 'non-web: nothing reachable (no routes)';

done_testing;
