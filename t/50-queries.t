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
    'lib/Foo.pm' => <<'PL',
package Foo;
use Bar;
our @ISA = ('Baz');
our @EXPORT = qw(run);
sub run  { help() }
sub help { 1 }
sub _hidden { 1 }
PL
    'lib/Bar.pm' => "package Bar;\nuse Foo;\nsub go { Foo::run() }\n",   # Foo<->Bar import cycle
    'lib/Baz.pm' => "package Baz;\nsub base_method { 1 }\n",
    't/foo.t'    => "use Foo;\nsub test_run { Foo::run() }\n",
);

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
for my $f (sort keys %files) {
    my $out = App::PerlGraph::Extractor->new(file_path => $f)->extract($parser->parse_string($files{$f}));
    $store->insert_node($_)       for @{ $out->{nodes} };
    $store->insert_edge($_)       for @{ $out->{edges} };
    $store->insert_unresolved($_) for @{ $out->{refs} };
}
App::PerlGraph::Resolver->new(store => $store)->resolve_all;
my $q = App::PerlGraph::Query->new(store => $store);

# --- deps -------------------------------------------------------------------
my ($foo) = grep { $_->{module} eq 'Foo' } $q->deps('Foo');
ok $foo, 'deps returns the requested module';
is $foo->{deps}{Bar}, 'imports', 'Foo imports Bar';
is $foo->{deps}{Baz}, 'extends', 'Foo extends Baz (via @ISA)';

# --- cycles -----------------------------------------------------------------
my @c = $q->cycles;
ok scalar(grep { my %m = map { $_ => 1 } @$_; $m{Foo} && $m{Bar} } @c),
   'Foo <-> Bar import cycle detected';

# --- api --------------------------------------------------------------------
my @api = sort map { $_->{name} } $q->api('Foo');
is \@api, ['help', 'run'], 'api lists public subs (run exported, help public), excludes _hidden';
my ($run) = grep { $_->{name} eq 'run' } $q->api('Foo');
ok $run->{is_exported}, 'api marks the exported symbol';

# --- covers -----------------------------------------------------------------
my @cov = $q->covers('Foo::run');
is \@cov, ['t/foo.t'], 'covers finds the test that reaches Foo::run (transitive reverse closure, .t only)';

done_testing;
