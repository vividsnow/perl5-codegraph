use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Refactor;
use App::PerlGraph::Format;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

sub setup {
    my $d = tempdir; $d->child('lib')->mkpath; $d->child('.pcg')->mkpath;
    $d->child('lib/Foo.pm')->spew_utf8("package Foo;\nsub bar { my \$x = shift; \$x * 2 }\nsub run { bar(3) }\n1;\n");
    $d->child('lib/Baz.pm')->spew_utf8("package Baz;\nsub hello { 1 }\n1;\n");
    $d->child('lib/Other.pm')->spew_utf8("package Other;\nsub use_it { Foo::bar(5) }\n1;\n");
    my $st = App::PerlGraph::Store->new(path => $d->child('.pcg/graph.db')->stringify); $st->init;
    App::PerlGraph::Indexer->new(store => $st, root => "$d")->index_all;
    return ($d, App::PerlGraph::Refactor->new(store => $st, root => "$d"));
}

# --- dry-run plan ---
my ($d0, $rf0) = setup();
my $plan = $rf0->move('Foo::bar', 'Baz');
is $plan->{new}, 'Baz::bar',  'plan: new qualified name';
is $plan->{applied}, 0,       'dry-run does not write';
like $d0->child('lib/Foo.pm')->slurp_utf8, qr/sub bar/, 'dry-run leaves the origin file unchanged';
like App::PerlGraph::Format::move($plan), qr/Move `Foo::bar` -> `Baz::bar`/, 'format: header';

# --- apply: relocate + requalify ---
my ($d, $rf) = setup();
my $done = $rf->move('Foo::bar', 'Baz', apply => 1);
ok $done->{applied} >= 3, 'apply relocated the def and requalified the call sites';
my $foo   = $d->child('lib/Foo.pm')->slurp_utf8;
my $baz   = $d->child('lib/Baz.pm')->slurp_utf8;
my $other = $d->child('lib/Other.pm')->slurp_utf8;
unlike $foo,   qr/sub bar\b/,     'the sub is removed from its origin file';
like   $baz,   qr/sub bar \{/,    'the sub is relocated into the target package file';
like   $foo,   qr/Baz::bar\(3\)/, 'the bareword self-call in the origin package is requalified';
like   $other, qr/Baz::bar\(5\)/, 'the qualified call in another file is requalified';
ok eval { $parser->parse_string($d->child('lib/Foo.pm')->slurp_raw); $parser->parse_string($baz); 1 },
   'both edited files still parse';

# --- error paths ---
my (undef, $rfe) = setup();
like App::PerlGraph::Format::move($rfe->move('No::Such',  'Baz')),  qr/no function/i,             'unknown symbol errors';
like App::PerlGraph::Format::move($rfe->move('Foo::bar', 'Nope')),  qr/not defined in this project/, 'unknown target package errors';
like App::PerlGraph::Format::move($rfe->move('Foo::bar', 'Foo')),   qr/already in/,               'move-to-same-package errors';

# --- collision: target already defines the same short name ---
my $dc = tempdir; $dc->child('lib')->mkpath; $dc->child('.pcg')->mkpath;
$dc->child('lib/Src.pm')->spew_utf8("package Src;\nsub dup { 1 }\n1;\n");
$dc->child('lib/Dst.pm')->spew_utf8("package Dst;\nsub dup { 2 }\n1;\n");
my $sc = App::PerlGraph::Store->new(path => $dc->child('.pcg/graph.db')->stringify); $sc->init;
App::PerlGraph::Indexer->new(store => $sc, root => "$dc")->index_all;
my $rc = App::PerlGraph::Refactor->new(store => $sc, root => "$dc");
like App::PerlGraph::Format::move($rc->move('Src::dup', 'Dst')), qr/already exists/, 'a name collision in the target package errors';

done_testing;
