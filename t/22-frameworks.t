use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

# --- Dancer2 verb route ---
my $tree = $parser->parse_string(<<'PL');
package MyApp;
use Dancer2;
get '/users' => sub { return list_users() };
sub list_users { 1 }
PL
my $out = App::PerlGraph::Extractor->new(file_path => 'app.pl')->extract($tree);

my @routes = grep { $_->{kind} eq 'route' } @{ $out->{nodes} };
is scalar(@routes), 1,                'one route node';
is $routes[0]{name}, 'GET /users',    'route name = VERB path';
is $routes[0]{metadata}{verb}, 'GET', 'route verb in metadata';

my ($handler) = grep { $_->{name} eq '__ANON__' } @{ $out->{nodes} };
ok $handler, 'anon handler node created';
ok( (grep { $_->{kind} eq 'references' && $_->{provenance} eq 'framework'
            && $_->{source} eq $routes[0]{id} && $_->{target} eq $handler->{id} } @{ $out->{edges} }),
    'route -> handler reference edge (framework)' );

my ($call) = grep { $_->{reference_name} eq 'list_users' } @{ $out->{refs} };
ok $call, 'handler body call captured';
is $call->{from_node_id}, $handler->{id}, 'handler call attributed to the handler, not the package';

# the verb call is NOT recorded as a plain "get" call
ok !(grep { $_->{reference_name} eq 'get' } @{ $out->{refs} }), 'route verb is not a plain call ref';

# --- Catalyst attribute route ---
my $ctree = $parser->parse_string(<<'PL');
package MyApp::Controller::Root;
use Moose;
sub index :Path :Args(0) { my ($self, $c) = @_; helper() }
sub helper { 1 }
PL
my $cout = App::PerlGraph::Extractor->new(file_path => 'Root.pm')->extract($ctree);
my @croutes = grep { $_->{kind} eq 'route' } @{ $cout->{nodes} };
is scalar(@croutes), 1, 'one Catalyst route';
my ($idx) = grep { $_->{qualified_name} eq 'MyApp::Controller::Root::index' } @{ $cout->{nodes} };
ok $idx, 'action sub node present';
ok( (grep { $_->{kind} eq 'references' && $_->{provenance} eq 'framework'
            && $_->{source} eq $croutes[0]{id} && $_->{target} eq $idx->{id} } @{ $cout->{edges} }),
    'Catalyst route -> action sub edge' );

# route path is the literal BEFORE the handler, even with a method array
my $t2 = $parser->parse_string(<<'PL');
package App2;
use Dancer2;
any ['get','post'] => '/multi' => sub { "x" };
PL
my ($r2) = grep { $_->{kind} eq 'route' } @{ App::PerlGraph::Extractor->new(file_path => 'a2.pl')->extract($t2)->{nodes} };
is $r2->{metadata}{path}, '/multi', 'route path is /multi (not the method array or body string)';

# Catalyst :Path('/explicit') value is used for the path
my $t3 = $parser->parse_string("package C3;\nsub show :Path('/items') { 1 }\n");
my ($r3) = grep { $_->{kind} eq 'route' } @{ App::PerlGraph::Extractor->new(file_path => 'c3.pl')->extract($t3)->{nodes} };
is $r3->{metadata}{path}, '/items', 'Catalyst :Path value used for the route path';

# Mojolicious::Lite render-shortcut route: a handler-less `get PATH => {...}` (or
# `=> 'template'`) is still a route. A bareword get($url) (LWP::Simple, which also
# exports get/head) in the same file must NOT be mistaken for one -- the literal
# `/`-path requirement on the handler-less form is the discriminator.
my $t4 = $parser->parse_string(<<'PL');
use Mojolicious::Lite;
use LWP::Simple;
get '/plaintext' => { text => 'Hello, World!' };
get '/page'      => 'template_name';
get '/json'      => sub { shift->render(json => {}) };
my $body = get('http://example.com/data');
my $h    = head('https://example.com');
PL
my $o4 = App::PerlGraph::Extractor->new(file_path => 'lite.pl')->extract($t4);
my %rpath = map { $_->{metadata}{path} => 1 } grep { $_->{kind} eq 'route' } @{ $o4->{nodes} };
ok  $rpath{'/plaintext'}, 'handler-less render-shortcut route (=> {...}) is extracted';
ok  $rpath{'/page'},      'handler-less template route (=> \'name\') is extracted';
ok  $rpath{'/json'},      'ordinary sub-handler route still extracted alongside';
is  scalar(keys %rpath), 3, 'exactly three routes -- bareword get($url)/head($url) are NOT routes';
ok !(grep { ($_->{metadata}{path} // '') =~ m{^https?://} } grep { $_->{kind} eq 'route' } @{ $o4->{nodes} }),
    'no route node was created from an LWP get/head URL argument';
# the handler-less routes have no __ANON__ handler; the sub route does
my @anon = grep { $_->{name} eq '__ANON__' } @{ $o4->{nodes} };
is scalar(@anon), 1, 'only the sub-handler route emits an __ANON__ handler node';
done_testing;
