use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Review;
use App::PerlGraph::Format;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";
skip_all "git unavailable" unless eval { my $v = `git --version 2>/dev/null`; $? == 0 && $v =~ /git/ };

my $dir = tempdir;
my @gc = ('git', '-C', "$dir");
$dir->child('lib')->mkpath; $dir->child('t')->mkpath;
# v1 (committed): A::foo($x), A::bar (called by B::run); a test exercises A::foo
$dir->child('lib/A.pm')->spew_utf8("package A;\nsub foo (\$x) { 1 }\nsub bar { 2 }\n1;\n");
$dir->child('lib/B.pm')->spew_utf8("package B;\nsub run { A::bar() }\n1;\n");
$dir->child('t/a.t')->spew_utf8("A::foo(1);\n");
system @gc, 'init', '-q'; system @gc, 'config', 'user.email', 't@t'; system @gc, 'config', 'user.name', 't';
system @gc, 'add', '-A'; system @gc, 'commit', '-qm', 'v1';
# working tree: re-signature foo, remove bar (breaking), add baz
$dir->child('lib/A.pm')->spew_utf8("package A;\nsub foo (\$x, \$y) { 1 }\nsub baz { 3 }\n1;\n");

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
App::PerlGraph::Indexer->new(store => $store, root => "$dir")->index_all;

my $rv = App::PerlGraph::Review->new(root => "$dir", ref => 'HEAD', parser => $parser, store => $store)->review;

ok +(grep { $_->{qualified_name} eq 'A::bar' && $_->{_breaking} } @{ $rv->{diff}{removed} }),
   'review: removing public A::bar is a breaking change';
ok +(grep { $_->{new}{qualified_name} eq 'A::foo' } @{ $rv->{diff}{changed} }),
   'review: A::foo signature change is reported';
ok +(grep { $_->{qualified_name} eq 'A::baz' } @{ $rv->{diff}{added} }), 'review: A::baz added';
ok +(grep { m{t/a\.t$} } @{ $rv->{tests} }), 'review: lists the affected test to run';

# the report composes it all
my $txt = App::PerlGraph::Format::review($rv);
like $txt, qr/Review:\s*HEAD/,        'format: review header names the ref';
like $txt, qr/breaking/i,             'format: flags the breaking change';
like $txt, qr/`A::bar`/,              'format: names the removed symbol';
like $txt, qr/Tests to run/,          'format: lists tests to run';
like $txt, qr{t/a\.t},                'format: the affected test appears';

# the re-signatured symbol still exists in the graph, so it carries a live caller count
my ($foo) = grep { ($_->{new}{qualified_name} // '') eq 'A::foo' } @{ $rv->{diff}{changed} };
ok $foo && $foo->{new}{_callers}, 'review: annotates a re-signatured symbol with its current caller count';

done_testing;
