use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::Store;
use App::PerlGraph::Resolver;
use App::PerlGraph::Query;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

my %files = (
    'lib/DB.pm'    => "package DB;\nsub insert { 1 }\n",
    'lib/Cache.pm' => "package Cache;\nsub insert { 1 }\n",
    'lib/App.pm'   => "package App;\nsub run { my \$db = shift; \$db->insert(1) }\n",
);
sub extract_into ($store, $file) {
    my $out = App::PerlGraph::Extractor->new(file_path => $file)->extract($parser->parse_string($files{$file}));
    $store->insert_node($_)       for @{ $out->{nodes} };
    $store->insert_edge($_)       for @{ $out->{edges} };
    $store->insert_unresolved($_) for @{ $out->{refs} };
    return $out;
}

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
extract_into($store, $_) for sort keys %files;
App::PerlGraph::Resolver->new(store => $store)->resolve_all;
my $q = App::PerlGraph::Query->new(store => $store);

# --- surface: $db->insert is unresolved but HAS candidates (DB::insert, Cache::insert) ---
my ($grp) = grep { $_->{method} eq 'insert' } $q->unresolved;
ok $grp, 'unresolved surfaces the opaque $db->insert call';
is $grp->{caller},   'App::run', 'with its caller';
is $grp->{receiver}, '$db',      'and the receiver expression';
is [ sort map { $_->{qname} } @{ $grp->{candidates} } ], ['Cache::insert', 'DB::insert'],
   'both real candidates are offered for disambiguation';

# --- the surface honors the name + limit filters ---
ok scalar($q->unresolved(name => 'insert')),       'unresolved(name => insert) returns the matching group';
ok !$q->unresolved(name => 'no_such_method_xyz'),  'unresolved(name => ...) filters out non-matching names';
ok scalar($q->unresolved(limit => 1)) <= 1,        'unresolved(limit => 1) caps the result count';

# --- a hallucinated target is rejected ---
my $bad = $q->resolve([{ caller => 'App::run', method => 'insert', receiver => '$db', target => 'Nope::insert' }]);
is scalar(@{ $bad->{applied} }),  0, 'a non-existent target is not applied';
is scalar(@{ $bad->{rejected} }), 1, '... it is rejected';

# --- a resolution missing required fields is rejected before touching the graph ---
my $miss = $q->resolve([{ caller => 'App::run', method => 'insert' }]);   # no receiver/target
is scalar(@{ $miss->{applied} }), 0,            'a resolution with missing fields is not applied';
like $miss->{rejected}[0]{reason}, qr/missing/, '... and is rejected with a missing-fields reason';

# --- a valid resolution creates an llm edge to the chosen candidate ---
my $ok = $q->resolve([{ caller => 'App::run', method => 'insert', receiver => '$db', target => 'DB::insert' }]);
is $ok->{applied}[0]{edges}, 1, 'one call edge created';
my ($run) = $store->nodes_by_qname('App::run');
my %callee = map { $store->node($_->{target})->{qualified_name} => $_->{provenance} }
             grep { $_->{target} } $store->outgoing_edges($run->{id}, 'calls');
is $callee{'DB::insert'}, 'llm', 'App::run -> DB::insert with llm provenance';
ok !$callee{'Cache::insert'}, 'the unchosen candidate is not linked';

# --- the resolution survives a reindex of App.pm (re-applied from the learned table) ---
$store->dbh->do('delete from edges');                  # wipe resolved edges
extract_into($store, 'lib/App.pm');                    # re-emit App.pm's unresolved $db->insert ref
App::PerlGraph::Resolver->new(store => $store)->resolve_all;
my %callee2 = map { $store->node($_->{target})->{qualified_name} => $_->{provenance} }
              grep { $_->{target} } $store->outgoing_edges($run->{id}, 'calls');
is $callee2{'DB::insert'}, 'llm', 'after reindex, the learned resolution is re-applied';

done_testing;
