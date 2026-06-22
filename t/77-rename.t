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

my $dir = tempdir;
$dir->child('lib')->mkpath; $dir->child('.pcg')->mkpath;
$dir->child('lib/Foo.pm')->spew_utf8(
    "package Foo;\nsub bar { 1 }\nsub c { Foo::bar(); bar(); my \$self = bless {}, 'Foo'; \$self->bar }\n1;\n");
$dir->child('lib/Other.pm')->spew_utf8(
    "package Other;\nsub use_it { Foo::bar() }\nsub mine { my \$x = shift; \$x->bar }\nsub bar { 99 }\n1;\n");
my $store = App::PerlGraph::Store->new(path => $dir->child('.pcg/graph.db')->stringify); $store->init;
App::PerlGraph::Indexer->new(store => $store, root => "$dir")->index_all;
my $rf = sub { App::PerlGraph::Refactor->new(store => $store, root => "$dir") };

# --- dry-run plan ---
my $plan = $rf->()->rename('Foo::bar', 'baz');
is $plan->{old}, 'Foo::bar',                     'resolves the qualified symbol';
is $plan->{new}, 'Foo::baz',                     'new qualified name (same package)';
is $plan->{applied}, 0,                          'dry-run does not write';
ok scalar(@{ $plan->{edits} }) >= 5,             'plans def + qualified + bareword + resolved-method edits';
is scalar(@{ $plan->{frontier} }), 1,            'reports exactly the one unverifiable $x->bar site';
like $dir->child('lib/Foo.pm')->slurp_utf8, qr/sub bar/, 'dry-run leaves the file unchanged';

like App::PerlGraph::Format::rename($plan), qr/Rename `Foo::bar` -> `Foo::baz`/, 'format: header';
like App::PerlGraph::Format::rename($plan), qr/Manual review/,                   'format: frontier section';

# --- apply ---
my $done = $rf->()->rename('Foo::bar', 'baz', apply => 1);
ok $done->{applied} >= 5, 'apply wrote the edits';
my $foo = $dir->child('lib/Foo.pm')->slurp_utf8;
like   $foo, qr/sub baz \{/,        'definition renamed';
like   $foo, qr/Foo::baz\(\)/,      'qualified call renamed';
like   $foo, qr/[^:]baz\(\)/,       'bareword call renamed';
like   $foo, qr/\$self->baz/,       'resolved $self->method renamed (heuristic tied it to Foo::bar)';
unlike $foo, qr/\bbar\b/,           'no stray old name left in Foo';
my $other = $dir->child('lib/Other.pm')->slurp_utf8;
like   $other, qr/Foo::baz\(\)/,    'qualified call in another file renamed';
like   $other, qr/\$x->bar/,        'unverifiable $x->bar left for manual review (NOT touched)';
like   $other, qr/sub bar \{ 99/,   "another class's same-named sub left alone";
ok eval { $parser->parse_string($dir->child('lib/Foo.pm')->slurp_raw); 1 }, 'the renamed file still parses';

# --- error paths ---
like App::PerlGraph::Format::rename($rf->()->rename('No::Such',  'x')),      qr/no function/i,   'unknown symbol errors';
like App::PerlGraph::Format::rename($rf->()->rename('Other::bar','use_it')), qr/already exists/, 'name collision errors';
like App::PerlGraph::Format::rename($rf->()->rename('Foo::bar', 'bad-name')),  qr/not a valid identifier/, 'a non-identifier new name is rejected';
like App::PerlGraph::Format::rename($rf->()->rename('Foo::bar', 'Other::baz')), qr/bare new name/,          'a qualified (cross-package) new name is rejected, not silently stripped';

# --- regression: two same-named method calls on ONE line, only one resolved ---
# `$self->run($x->run)`: $self->run resolves to the def; $x->run is an unverifiable
# frontier. The edit must touch ONLY $self->run -- a greedy name match would jump to
# the rightmost ->run ($x->run) and corrupt the frontier call instead.
{
    my $d = tempdir; $d->child('lib')->mkpath; $d->child('.pcg')->mkpath;
    $d->child('lib/N.pm')->spew_utf8(
        "package N;\nsub run { 1 }\nsub go { my \$self = bless {}, 'N'; my \$x = shift; \$self->run(\$x->run) }\n1;\n");
    my $st = App::PerlGraph::Store->new(path => $d->child('.pcg/graph.db')->stringify); $st->init;
    App::PerlGraph::Indexer->new(store => $st, root => "$d")->index_all;
    App::PerlGraph::Refactor->new(store => $st, root => "$d")->rename('N::run', 'launch', apply => 1);
    my $src = $d->child('lib/N.pm')->slurp_utf8;
    like   $src, qr/sub launch \{/,    'definition renamed';
    like   $src, qr/\$self->launch\(/, 'the resolved $self->method on a shared line IS renamed';
    like   $src, qr/\$x->run\)/,       'the sibling unverifiable $x->method on the same line is NOT renamed';
    ok eval { $parser->parse_string($d->child('lib/N.pm')->slurp_raw); 1 }, 'the renamed file still parses';
}

done_testing;
