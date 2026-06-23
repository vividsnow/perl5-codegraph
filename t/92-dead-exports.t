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

my $d = tempdir; $d->child('lib')->mkpath; $d->child('.pcg')->mkpath;
$d->child('lib/Foo.pm')->spew_utf8(<<'PL');
package Foo;
use Exporter 'import';
our @EXPORT_OK = qw(used_fn dead_fn self_fn);
sub used_fn { 1 }
sub dead_fn { 2 }
sub self_fn { 3 }
sub _internal { self_fn() }   # same-package use -- does NOT make self_fn a live export
1;
PL
$d->child('lib/Bar.pm')->spew_utf8("package Bar;\nuse Foo qw(used_fn);\nsub go { used_fn() }\n1;\n");
my $s = App::PerlGraph::Store->new(path => $d->child('.pcg/graph.db')->stringify); $s->init;
App::PerlGraph::Indexer->new(store => $s, root => "$d")->index_all;
my $dead = App::PerlGraph::Query->new(store => $s)->dead_exports;

my %dead; $dead{ $_->{qualified_name} } = 1 for @$dead;
ok  $dead{'Foo::dead_fn'},  'an export no other package calls is flagged dead';
ok  $dead{'Foo::self_fn'},  'an export used only within its own package is flagged (same-package use does not count)';
ok !$dead{'Foo::used_fn'},  'an export called from another package is NOT flagged';

my $txt = App::PerlGraph::Format::dead_exports($dead);
like $txt, qr/Dead exports/,    'format: header';
like $txt, qr/`Foo::dead_fn`/,  'format: lists a dead export';
like $txt, qr/external.*consumers/, 'format: the honest caveat';
like App::PerlGraph::Format::dead_exports([]), qr/_none_/, 'format: clean-state message';

done_testing;
