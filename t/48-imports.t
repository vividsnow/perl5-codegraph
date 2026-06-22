use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::Store;
use App::PerlGraph::Resolver;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

# A imports `helper` from B and calls it. C ALSO defines `helper`, so the global
# fallback is ambiguous -- only the import tells us A::go calls B::helper.
my $src = <<'PL';
package A;
use B qw(helper);
sub go { helper() }
package B;
sub helper { 1 }
sub other { 1 }
package C;
sub helper { 2 }
PL

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
my $out = App::PerlGraph::Extractor->new(file_path => 'A.pm')->extract($parser->parse_string($src));
$store->insert_node($_)       for @{ $out->{nodes} };
$store->insert_edge($_)       for @{ $out->{edges} };
$store->insert_unresolved($_) for @{ $out->{refs} };
App::PerlGraph::Resolver->new(store => $store)->resolve_all;

my %id = map { $_->{qualified_name} => $_->{id} } @{ $out->{nodes} };
my @callees = map { $store->node($_->{target})->{qualified_name} }
              grep { $_->{target} } $store->outgoing_edges($id{'A::go'}, 'calls');

ok scalar(grep { $_ eq 'B::helper' } @callees), 'imported helper() resolves to B::helper (the import), despite C::helper';
ok !(grep { $_ eq 'C::helper' } @callees),       'does not mis-resolve to the other same-named sub';

# the imports edge records WHICH symbols were imported
my ($imp) = grep { $_->{kind} eq 'imports' && (($_->{metadata}||{})->{module}//'') eq 'B' } @{ $out->{edges} };
ok $imp, 'imports edge for `use B`';
is $imp->{metadata}{symbols}, ['helper'], 'imports edge records the imported symbol list';

# a non-imported, non-local, globally-ambiguous bareword stays unresolved (no guess)
my $src2 = "package P;\nsub run { helper() }\npackage Q;\nsub helper { 1 }\npackage R;\nsub helper { 2 }\n";
my $s2 = App::PerlGraph::Store->new(path => ':memory:'); $s2->init;
my $o2 = App::PerlGraph::Extractor->new(file_path => 'P.pm')->extract($parser->parse_string($src2));
$s2->insert_node($_) for @{$o2->{nodes}}; $s2->insert_edge($_) for @{$o2->{edges}}; $s2->insert_unresolved($_) for @{$o2->{refs}};
App::PerlGraph::Resolver->new(store => $s2)->resolve_all;
my %i2 = map { $_->{qualified_name} => $_->{id} } @{ $o2->{nodes} };
my @c2 = grep { $_->{target} } $s2->outgoing_edges($i2{'P::run'}, 'calls');
is scalar(@c2), 0, 'without an import, an ambiguous bareword is left unresolved (no false edge)';

done_testing;
