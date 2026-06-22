use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Query;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

# a fake CPAN tree: Acme::Dep (with a constructor + a method) extends Acme::Base
my $inc = tempdir;
$inc->child('Acme')->mkpath;
$inc->child('Acme/Base.pm')->spew_utf8("package Acme::Base;\nsub base_method { 1 }\n1;\n");
$inc->child('Acme/Dep.pm')->spew_utf8(
    "package Acme::Dep;\nuse parent -norequire, 'Acme::Base';\nsub new { bless {} }\nsub helper { 2 }\nsub _private { 3 }\n1;\n");

# a project that uses it three ways
my $proj = tempdir;
$proj->child('lib')->mkpath;
$proj->child('lib/App.pm')->spew_utf8(<<'PL');
package App;
use Acme::Dep;
sub run     { my $d = Acme::Dep->new; $d->helper() }        # constructor + inferred type
sub run2    { Acme::Dep::helper() }                         # qualified bareword call
sub inherit { my $d = Acme::Dep->new; $d->base_method() }   # method from the indexed parent (MRO)
1;
PL

local @INC = ("$inc", @INC);
my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
App::PerlGraph::Indexer->new(store => $store, root => "$proj", deps => 1)->index_all;

# the dep's public API is indexed and marked cpan; privates are skipped
my ($h) = $store->nodes_by_qname('Acme::Dep::helper');
ok $h,                       'a used CPAN module is indexed (--deps)';
ok $h->{metadata}{cpan},     '... CPAN nodes are marked';
ok !($store->nodes_by_qname('Acme::Dep::_private')), 'private CPAN subs are not indexed';
ok +($store->nodes_by_qname('Acme::Base::base_method')), 'the dep\'s parent is indexed too (transitive)';

sub callees ($caller) {
    my ($n) = $store->nodes_by_qname($caller);
    map { $store->node($_->{target})->{qualified_name} }
        grep { $_->{target} } $store->outgoing_edges($n->{id}, 'calls');
}
my $q = App::PerlGraph::Query->new(store => $store);

ok +(grep { $_ eq 'Acme::Dep::helper' } callees('App::run')),     'my $d = Dep->new; $d->helper resolves into the dep';
ok +(grep { $_ eq 'Acme::Dep::helper' } callees('App::run2')),    'Acme::Dep::helper() bareword resolves into the dep';
ok +(grep { $_ eq 'Acme::Base::base_method' } callees('App::inherit')),
   'an inherited dep method resolves up the MRO into the parent';

# CPAN nodes do not pollute the "your code" queries
ok !(grep { ($_->{qualified_name} // '') =~ /Acme::/ } $q->unused),   'CPAN deps are not reported as dead code';
ok !(grep { ($_->{qualified_name} // '') =~ /Acme::/ } $q->untested), 'CPAN deps are not reported as untested public API';

# without --deps, none of that happens (the dep is just external/unresolved)
my $s2 = App::PerlGraph::Store->new(path => ':memory:'); $s2->init;
App::PerlGraph::Indexer->new(store => $s2, root => "$proj")->index_all;
ok !($s2->nodes_by_qname('Acme::Dep::helper')), 'no dep nodes without --deps';

done_testing;
