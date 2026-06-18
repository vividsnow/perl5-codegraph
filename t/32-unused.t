use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Query;
use App::PerlGraph::Format;
use App::PerlGraph::CLI;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built";

my $dir = tempdir;
$dir->child('lib')->mkpath;
$dir->child('lib/Foo.pm')->spew_utf8(<<'PERL');
package Foo;
use Exporter 'import';
our @EXPORT = ('shipped');

sub run     { helper() }          # calls helper -> helper is used
sub helper  { 1 }                 # has a caller -> not dead
sub dead    { 1 }                 # nobody calls -> dead
sub _orphan { 1 }                 # private, nobody calls -> dead
sub shipped { 1 }                 # exported -> public API
sub new     { bless {}, shift }   # lifecycle -> framework-invoked
sub dispatched { 2 }              # only reached via $obj->dispatched
sub callback     { 3 }            # used only as \&callback in the table below
sub _build_thing { 4 }            # Moo lazy builder -> framework-invoked

sub via_method {
    my $obj = make();             # unknown receiver
    $obj->dispatched;             # unresolved method_call named 'dispatched'
}

my %dispatch = ( go => \&callback );   # \&callback -> callback is referenced
1;
PERL

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
App::PerlGraph::Indexer->new(store => $store, root => "$dir")->index_all;
my $q = App::PerlGraph::Query->new(store => $store);

my %flagged = map { ($_->{qualified_name} // $_->{name}) => 1 } $q->unused;

ok  $flagged{'Foo::dead'},        'a never-called sub is flagged unreferenced';
ok  $flagged{'Foo::_orphan'},     'a never-called private sub is flagged';
ok !$flagged{'Foo::helper'},      'a sub with a static caller is not flagged';
ok !$flagged{'Foo::shipped'},     'an exported sub is not flagged by default (public API)';
ok !$flagged{'Foo::new'},         'a lifecycle method (new) is not flagged';
ok !$flagged{'Foo::dispatched'},  'a sub reached only via $obj->method is not flagged (dynamic dispatch)';
ok !$flagged{'Foo::callback'},    'a sub used only via a \&name code ref is not flagged';
ok !$flagged{'Foo::_build_thing'},'a Moo lazy builder (_build_*) is not flagged';
ok  $flagged{'Foo::via_method'},  'a sub that only dispatches dynamically is itself still flagged (only targets are spared, not callers)';

# --all includes exported + lifecycle subs, but still suppresses dynamic-dispatch names
my %all = map { ($_->{qualified_name} // $_->{name}) => 1 } $q->unused(all => 1);
ok  $all{'Foo::shipped'},      '--all includes exported subs';
ok  $all{'Foo::new'},          '--all includes lifecycle subs';
ok  $all{'Foo::dead'},         '--all still includes genuinely-dead subs';
ok  $all{'Foo::_build_thing'}, '--all includes _build_ builders';
ok !$all{'Foo::dispatched'},   '--all still suppresses dynamically-dispatched names';
ok !$all{'Foo::callback'},     '--all: a \&name-referenced sub is still genuinely used';

# Format: header, list entry, summary, honesty caveat
my $out = App::PerlGraph::Format::unused([ $q->unused ]);
like $out, qr/## Unreferenced symbols/,    'format: header';
like $out, qr/`Foo::dead`/,                'format: lists a dead sub';
like $out, qr/sub\(s\) unreferenced/,      'format: summary line';
like $out, qr/dynamic.*dispatch.*runtime/s,'format: caveat mentions dynamic dispatch + runtime';

# empty result renders cleanly
like App::PerlGraph::Format::unused([]), qr/_none_/, 'format: empty result says none';

# CLI wiring: index then `pcg unused <path>` prints the report and exits 0
{ open my $fh, '>', \my $idx; local *STDOUT = $fh; App::PerlGraph::CLI->run('index', "$dir") }
my $rc;
{ open my $fh, '>', \my $cout; local *STDOUT = $fh;
  $rc = App::PerlGraph::CLI->run('unused', "$dir");
  like $cout, qr/## Unreferenced symbols/, 'cli: prints the report header';
  like $cout, qr/Foo::dead/,               'cli: report includes the dead sub'; }
is $rc, 0, 'pcg unused exits 0';

my $rc2;
{ open my $fh, '>', \my $cout2; local *STDOUT = $fh;
  $rc2 = App::PerlGraph::CLI->run('unused', '--all', "$dir");
  like $cout2, qr/Foo::new/, 'cli --all: includes a lifecycle sub (new)'; }
is $rc2, 0, 'pcg unused --all exits 0';

done_testing;
