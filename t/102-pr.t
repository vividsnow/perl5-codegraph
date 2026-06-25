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
# v1 (committed): A::foo($x,$y) and public A::bar (called by B); a test exercises A::foo.
$dir->child('lib/A.pm')->spew_utf8("package A;\nsub foo (\$x, \$y) { 1 }\nsub bar { 2 }\n1;\n");
$dir->child('lib/B.pm')->spew_utf8("package B;\nsub run { A::bar(); A::foo(1, 2) }\n1;\n");
$dir->child('t/a.t')->spew_utf8("A::foo(1, 2);\n");
system @gc, 'init', '-q'; system @gc, 'config', 'user.email', 't@t'; system @gc, 'config', 'user.name', 't';
system @gc, 'add', '-A'; system @gc, 'commit', '-qm', 'v1';
# working tree: REMOVE public bar (breaking), ADD public baz (untested), and ADD a private
# _oops whose body calls A::foo with the WRONG arity (1 arg to a 2-arg signature) -- a call
# bug inside a CHANGED file, which the pr gate should lint and count.
$dir->child('lib/A.pm')->spew_utf8("package A;\nsub foo (\$x, \$y) { 1 }\nsub baz { 3 }\nsub _oops { A::foo(99) }\n1;\n");

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
App::PerlGraph::Indexer->new(store => $store, root => "$dir")->index_all;

my $r = App::PerlGraph::Review->new(root => "$dir", ref => 'HEAD', parser => $parser, store => $store)->pr;

# --- concern counts ---
is $r->{counts}{breaking}, 1, 'pr: removing public A::bar is one breaking change';
is $r->{counts}{untested}, 1, 'pr: A::baz is one untested public change';
is $r->{counts}{arity},    1, 'pr: the wrong-arity A::foo(99) in the changed file is counted';
is $r->{counts}{broken},   0, 'pr: no broken method calls';
ok +(grep { ($_->{qualified_name} // '') eq 'A::bar' } @{ $r->{breaking} }), 'pr: names the breaking symbol';
ok +(grep { ($_->{file} // '') =~ m{lib/A\.pm} } @{ $r->{arity} }), 'pr: the arity finding is scoped to the changed file';

# --- score + verdict: 100 - 15(breaking) - 10(arity) - 6(untested) = 69 -> REVIEW ---
is $r->{score}, 69, 'pr: weighted score is 100 minus the concern weights';
is $r->{verdict}, 'REVIEW', 'pr: a 69 score is the REVIEW verdict (60-84)';
is $r->{counts}{wide}, 0, 'pr: no wide-blast-radius concern in this fixture (nothing has >=5 callers)';

# --- renderer ---
my $txt = App::PerlGraph::Format::pr($r);
like $txt, qr{PR health: REVIEW \(69/100\) vs `HEAD`}, 'format: header carries verdict + score + ref';
like $txt, qr/Breaking changes.*`A::bar`/s,           'format: breaking section';
like $txt, qr/Wrong-arity calls in changed files/,    'format: arity section';
like $txt, qr/Untested public changes.*`A::baz`/s,    'format: untested section';
like $txt, qr/Run \d+ affected test\(s\):.*t\/a\.t/s, 'format: lists the affected tests to run';
like $txt, qr/>=85 PASS, 60-84 REVIEW, <60 BLOCK/,    'format: scoring legend';

# --- the broken-call concern section (scoped to changed files like arity; rendered synthetically,
#     a BLOCK verdict so the broken weight 12 is reflected) ---
my $blocked = App::PerlGraph::Format::pr({ ref => 'main', score => 50, verdict => 'BLOCK', nfiles => 1,
    counts => { breaking => 0, broken => 1, arity => 0, untested => 0, wide => 1 },
    breaking => [], arity => [], untested => [], tests => [],
    broken => [{ caller => 'App::go', method => 'gone', class => 'App::Thing', file => 'lib/App.pm', line => 9 }],
    wide   => [{ qualified_name => 'App::hub', kind => 'function', _callers => 7 }] });
like $blocked, qr{PR health: BLOCK \(50/100\)},               'format: a low score renders the BLOCK verdict';
like $blocked, qr/Broken calls in changed files.*`App::go`.*->gone.*`App::Thing`/s,
    'format: the broken-call section names the caller, the missing method, and the receiver class';
like $blocked, qr/Wide blast radius.*`App::hub`.*7 caller/s,
    'format: the wide-blast-radius section names the symbol and its caller count';

# --- clean state (no structural changes) renders a PASS gate with no concern sections ---
my $clean = App::PerlGraph::Format::pr({ ref => 'main', score => 100, verdict => 'PASS', nfiles => 0,
    counts => { breaking => 0, broken => 0, arity => 0, untested => 0, wide => 0 },
    breaking => [], broken => [], arity => [], untested => [], wide => [], tests => [] });
like $clean, qr{PR health: PASS \(100/100\)}, 'format: clean PR is PASS 100';
like $clean, qr/no structural changes/,       'format: clean PR says nothing to gate';

done_testing;
