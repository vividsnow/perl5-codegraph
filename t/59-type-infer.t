use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::Store;
use App::PerlGraph::Resolver;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

sub graph ($src) {
    my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
    my $out = App::PerlGraph::Extractor->new(file_path => 'A.pm')->extract($parser->parse_string($src));
    $store->insert_node($_)       for @{ $out->{nodes} };
    $store->insert_edge($_)       for @{ $out->{edges} };
    $store->insert_unresolved($_) for @{ $out->{refs} };
    App::PerlGraph::Resolver->new(store => $store)->resolve_all;
    return $store;
}
sub callees ($store, $caller) {
    my ($n) = $store->nodes_by_qname($caller);
    map { [ $store->node($_->{target})->{qualified_name}, $_->{provenance} ] }
        grep { $_->{target} } $store->outgoing_edges($n->{id}, 'calls');
}

# Store and Cache BOTH define save() -> the opaque `$x->save` is globally
# ambiguous, so only local type inference can pick the right one.
my $store = graph(<<'PL');
package App;
sub run {
    my $db = Store->new;
    $db->save();
    my $c = Cache->new(1);
    $c->save();
}
sub other {
    my $db = shift;       # not a constructor -> no inferred type
    $db->save();
}
package Store; sub new { bless {} } sub save { 1 }
package Cache; sub new { bless {} } sub save { 1 }
PL

my %run = map { $_->[0] => $_->[1] } callees($store, 'App::run');
ok  $run{'Store::save'}, '`my $db = Store->new; $db->save` resolves to Store::save';
ok  $run{'Cache::save'}, '`my $c = Cache->new; $c->save`  resolves to Cache::save';
is  $run{'Store::save'}, 'inferred', '... with `inferred` provenance';

my @other = callees($store, 'App::other');
is scalar(@other), 0, 'a receiver with no constructor assignment ($db = shift) stays unresolved (no guess)';

# inference is per-sub: a same-named var in another sub does not leak its type
my $s2 = graph(<<'PL');
package App;
sub a { my $x = Store->new; $x->save() }
sub b { $x->save() }                      # $x here is NOT the one from a()
package Store; sub new { bless {} } sub save { 1 }
PL
ok   +{ map { $_->[0] => 1 } callees($s2, 'App::a') }->{'Store::save'}, 'inferred type used in its own sub';
is   scalar(callees($s2, 'App::b')), 0,                                 'inferred type does not leak across subs';

# a wrong-typed method is NOT fabricated: $db->nonexistent stays unresolved
# (the `Store->new` constructor call itself does resolve to Store::new -- expected)
my $s3 = graph("package App;\nsub r { my \$d = Store->new; \$d->nope() }\npackage Store;\nsub new { bless {} }\nsub save { 1 }\n");
my @r = callees($s3, 'App::r');
ok !(grep { $_->[0] =~ /nope/ } @r),        'an inferred type never fabricates an edge to a method it lacks';
ok +(grep { $_->[0] eq 'Store::new' } @r), 'the Store->new constructor call itself resolves (sanity)';

done_testing;
