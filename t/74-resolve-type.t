use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::Store;
use App::PerlGraph::Resolver;
use App::PerlGraph::Query;
use App::PerlGraph::Format;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

# $db's type is not statically knowable (assigned from an opaque call), so its
# three method calls stay unresolved with receiver '$db'.
my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
my $out = App::PerlGraph::Extractor->new(file_path => 'A.pm')->extract($parser->parse_string(<<'PL'));
package App;
sub run { my $db = build(); $db->query(); $db->fetch(); $db->missing() }
package Store;
sub new   { bless {} }
sub query { 1 }
sub fetch { 1 }
PL
$store->insert_node($_)       for @{ $out->{nodes} };
$store->insert_edge($_)       for @{ $out->{edges} };
$store->insert_unresolved($_) for @{ $out->{refs} };
App::PerlGraph::Resolver->new(store => $store)->resolve_all;

my $q = App::PerlGraph::Query->new(store => $store);
sub calls ($caller) {
    my ($n) = $store->nodes_by_qname($caller);
    map { $store->node($_->{target})->{qualified_name} }
        grep { $_->{target} } $store->outgoing_edges($n->{id}, 'calls');
}

# resolve $db's TYPE once -> every call on $db that Store actually has resolves
my $res = $q->resolve([ { caller => 'App::run', receiver => '$db', class => 'Store' } ]);
is $res->{applied}[0]{edges}, 2, 'a single receiver-type resolution resolved both real method calls';

my %c = map { $_ => 1 } calls('App::run');
ok  $c{'Store::query'}, '$db->query resolved against the named class';
ok  $c{'Store::fetch'}, '$db->fetch resolved against the named class';
ok !$c{'Store::missing'}, 'a method the class lacks is NOT fabricated (no Store::missing)';

# it persists like an explicit resolution: re-running resolve_all keeps the edges
App::PerlGraph::Resolver->new(store => $store)->resolve_all;
%c = map { $_ => 1 } calls('App::run');
ok $c{'Store::query'} && $c{'Store::fetch'}, 'the learned receiver type survives reindex';

# the explicit (caller, method, receiver, target) form still works
my $s2 = App::PerlGraph::Store->new(path => ':memory:'); $s2->init;
my $o2 = App::PerlGraph::Extractor->new(file_path => 'B.pm')->extract($parser->parse_string(
    "package App;\nsub go { my \$x = build(); \$x->ping() }\npackage Svc;\nsub ping { 1 }\n"));
$s2->insert_node($_) for @{ $o2->{nodes} }; $s2->insert_edge($_) for @{ $o2->{edges} }; $s2->insert_unresolved($_) for @{ $o2->{refs} };
App::PerlGraph::Resolver->new(store => $s2)->resolve_all;
my $r2 = App::PerlGraph::Query->new(store => $s2)->resolve([ { caller => 'App::go', method => 'ping', receiver => '$x', target => 'Svc::ping' } ]);
is $r2->{applied}[0]{edges}, 1, 'the explicit-target form still resolves';

# Format::resolved renders BOTH applied forms, with NO uninitialized-value warnings
# (regression: the receiver-type form has no method/target keys).
my @warn;
my $rtxt = do { local $SIG{__WARN__} = sub { push @warn, "@_" }; App::PerlGraph::Format::resolved($res) };
ok !@warn, 'receiver-type form renders without uninitialized-value warnings' or diag "@warn";
like $rtxt, qr/\$db` is `Store`/,     'receiver-type form shows "receiver is Class"';
like $rtxt, qr/2 call\(s\) resolved/, '... with the resolved-call count';
like App::PerlGraph::Format::resolved($r2), qr/\$x->ping` -> `Svc::ping`/, 'explicit form still renders method -> target';

# receiver-type error/edge paths, on a fresh graph to avoid cross-test state
my $s3 = App::PerlGraph::Store->new(path => ':memory:'); $s3->init;
my $o3 = App::PerlGraph::Extractor->new(file_path => 'C.pm')->extract($parser->parse_string(
    "package App;\nsub h { my \$z = mk(); \$z->go() }\npackage Real;\nsub go { 1 }\n"));
$s3->insert_node($_) for @{ $o3->{nodes} }; $s3->insert_edge($_) for @{ $o3->{edges} }; $s3->insert_unresolved($_) for @{ $o3->{refs} };
App::PerlGraph::Resolver->new(store => $s3)->resolve_all;
my $q3 = App::PerlGraph::Query->new(store => $s3);

my $bogus = $q3->resolve([ { caller => 'App::h', receiver => '$z', class => 'Nope' } ]);   # class lacks go()
is $bogus->{applied}[0]{edges}, 0,        'an unknown/wrong class resolves nothing (no fabricated edge)';
is scalar @{ $bogus->{rejected} }, 0,     '... and is not rejected (a valid request, just empty)';
my $good = $q3->resolve([ { caller => 'App::h', receiver => '$z', class => 'Real' } ]);
is $good->{applied}[0]{edges}, 1,         'the correct class then resolves the call';
ok @{ $q3->resolve([ { caller => 'App::h', receiver => '$z' } ])->{rejected} },
   'a resolution missing both class and target is rejected, not silently applied';

# resolve_targets: group opaque calls by receiver, intersect the classes defining ALL
# the methods -- a unique intersection is a confident type suggestion for the LLM.
my $sh = App::PerlGraph::Store->new(path => ':memory:'); $sh->init;
my $oh = App::PerlGraph::Extractor->new(file_path => 'H.pm')->extract($parser->parse_string(<<'PL'));
package App;
sub run { my $db = mk(); $db->query(); $db->fetch(); my $x = mk(); $x->ping(); my $amb = mk(); $amb->query() }
package Store;
sub query { 1 }
sub fetch { 1 }
package Other;
sub query { 1 }
sub ping  { 1 }
PL
$sh->insert_node($_) for @{ $oh->{nodes} }; $sh->insert_edge($_) for @{ $oh->{edges} }; $sh->insert_unresolved($_) for @{ $oh->{refs} };
App::PerlGraph::Resolver->new(store => $sh)->resolve_all;
my @hints = App::PerlGraph::Query->new(store => $sh)->resolve_targets;
my ($db_h) = grep { $_->{receiver} eq '$db' } @hints;
is $db_h->{classes}, ['Store'], '$db (query+fetch) intersects uniquely to Store (only class with BOTH)';
is $db_h->{calls},   2,         '... with the call count';
my ($x_h) = grep { $_->{receiver} eq '$x' } @hints;
is $x_h->{classes}, ['Other'],  '$x (ping) -> Other';
my ($amb_h) = grep { $_->{receiver} eq '$amb' } @hints;
is $amb_h->{classes}, ['Other', 'Store'], '$amb (query only -- in both classes) narrows to two candidates, not one';
my $htxt = App::PerlGraph::Format::resolve_targets(\@hints);
like $htxt, qr/type as `Store`/,        'format suggests the unique class';
like $htxt, qr/one of: `Other`, `Store`/, 'format lists the candidates for a non-unique receiver';
# unique-class receivers are ranked before the ambiguous one
ok +(grep { $_->{receiver} eq '$db' } @hints[0,1]), 'unique-class suggestions are ranked first';

# `name` narrows by_receiver to the receivers that call that method (only $db calls fetch)
my @fetchers = App::PerlGraph::Query->new(store => $sh)->resolve_targets(name => 'fetch');
is [ map { $_->{receiver} } @fetchers ], ['$db'], 'resolve_targets(name => fetch) keeps only receivers that call fetch()';

done_testing;
