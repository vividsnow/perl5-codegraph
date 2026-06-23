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

sub setup ($code) {
    my $d = tempdir; $d->child('lib')->mkpath; $d->child('.pcg')->mkpath;
    $d->child('lib/P.pm')->spew_utf8($code);
    my $st = App::PerlGraph::Store->new(path => $d->child('.pcg/graph.db')->stringify); $st->init;
    App::PerlGraph::Indexer->new(store => $st, root => "$d")->index_all;
    return ($d, App::PerlGraph::Refactor->new(store => $st, root => "$d"));   # keep $d alive in the caller
}

# --- unpack idiom: inline both call sites as do-blocks, then remove the definition ---
my ($d, $rf) = setup(<<'PL');
package P;
sub _area { my ($w, $h) = @_; $w * $h }
sub run {
    my $self = shift;
    my $a = _area(3, 4);
    my $b = _area($self->{w} + 1, $self->{h});
    return $a + $b;
}
1;
PL
my $plan = $rf->inline('P::_area', apply => 1);
is $plan->{applied}, 3, 'inline applied 2 call-site edits + the definition removal';
ok $plan->{removed},      'the definition was removed (every caller inlined)';
my $after = $d->child('lib/P.pm')->slurp_utf8;
unlike $after, qr/sub\s+_area/,                                   'the definition is gone';
like   $after, qr/do \{ my \(\$w, \$h\) = \(3, 4\); \$w \* \$h \}/, 'a literal-arg call inlines with args bound once';
like   $after, qr/do \{ my \(\$w, \$h\) = \(\$self->\{w\} \+ 1, \$self->\{h\}\)/, 'an expression arg is bound once (precedence preserved)';
ok eval { $parser->parse_string($d->child('lib/P.pm')->slurp_raw); 1 }, 'the edited file still parses';

# --- dry-run does not write ---
my ($d2, $rf2) = setup("package P;\nsub _twice { my (\$x) = \@_; \$x * 2 }\nsub run { _twice(5) }\n1;\n");
is $rf2->inline('P::_twice')->{applied}, 0, 'dry-run does not write';
like $d2->child('lib/P.pm')->slurp_utf8, qr/sub\s+_twice/, 'dry-run leaves the file unchanged';

# --- a simple signature inlines too ---
my ($d3, $rf3) = setup("package P;\nsub addz (\$a, \$b) { \$a + \$b }\nsub run { my \$z = addz(5, 6); }\n1;\n");
$rf3->inline('P::addz', apply => 1);
like $d3->child('lib/P.pm')->slurp_utf8, qr/do \{ my \(\$a,\s*\$b\) = \(5, 6\); \$a \+ \$b \}/, 'a signature sub inlines (params bound to args)';

# --- refusals + error paths ---
my ($dr, $rr) = setup("package P;\nsub withret { my (\$x) = \@_; return \$x + 1 }\nsub run { withret(2) }\n1;\n");
like App::PerlGraph::Format::inline($rr->inline('P::withret')), qr/uses `return`/,    'a body with return is refused';
like App::PerlGraph::Format::inline($rr->inline('P::nope')),    qr/no plain function/, 'an unknown function errors';

# --- a method-call site can't be inlined -> frontier, definition kept ---
my ($dm, $rm) = setup("package P;\nsub helper { my (\$x) = \@_; \$x * 2 }\nsub run { my \$o = shift; \$o->helper(3) }\n1;\n");
my $mp = $rm->inline('P::helper', apply => 1);
is scalar @{ $mp->{frontier} }, 1, 'a $obj->method call goes to the frontier';
ok !$mp->{removed},           'the definition is kept when a caller cannot be inlined';
like $dm->child('lib/P.pm')->slurp_utf8, qr/sub\s+helper/, 'the definition is preserved on disk';

# a RECURSIVE function: the self-call goes to the frontier and the def is kept (no corruption)
my ($drec, $rrec) = setup("package P;\nsub fact { my (\$n) = \@_; \$n < 2 ? 1 : \$n * fact(\$n - 1) }\nsub run { fact(5) }\n1;\n");
my $rp = $rrec->inline('P::fact', apply => 1);
ok !$rp->{removed},                                              'a recursive function is not removed';
ok( (grep { ($_->{why} // '') =~ /self-call/ } @{ $rp->{frontier} }), 'the self-call is reported on the frontier' );
like $drec->child('lib/P.pm')->slurp_utf8, qr/sub\s+fact/,       'the definition is preserved';
ok eval { $parser->parse_string($drec->child('lib/P.pm')->slurp_raw); 1 }, 'the file still parses (no corruption)';

# an EXPORTED function: inline the in-repo call sites but KEEP the definition (external consumers)
my ($de, $re) = setup("package P;\nuse Exporter 'import';\nour \@EXPORT_OK = qw(helper);\nsub helper { my (\$x) = \@_; \$x + 1 }\nsub run { helper(3) }\n1;\n");
my $ep = $re->inline('P::helper', apply => 1);
ok !$ep->{removed},                                       'an exported function keeps its definition';
like $de->child('lib/P.pm')->slurp_utf8, qr/sub\s+helper/, 'the definition is preserved on disk';
like $de->child('lib/P.pm')->slurp_utf8, qr/do \{ my \(\$x\)/, 'but the in-repo call site is still inlined';

# an argument that LOOKS like a regex capture ($1) must be inlined LITERALLY, not interpolated
my ($dg, $rg) = setup("package P;\nsub wrap { my (\$x) = \@_; \"[\$x]\" }\nsub run { my \$y = wrap(\$1); }\n1;\n");
$rg->inline('P::wrap', apply => 1);
like $dg->child('lib/P.pm')->slurp_utf8, qr/= \(\$1\);/, 'a $1 argument inlines literally (substr, not s///)';

# a multi-package file with TWO same-named subs: inline must target the requested package's
# sub (anchored to its line), not whichever the CST walk reaches first
my ($dmp, $rmp) = setup("package A;\nsub helper { my (\$x) = \@_; \$x + 100 }\nsub run_a { helper(1) }\n"
                      . "package B;\nsub helper { my (\$y) = \@_; \$y * 999 }\nsub run_b { helper(2) }\n1;\n");
$rmp->inline('A::helper', apply => 1);
my $mpsrc = $dmp->child('lib/P.pm')->slurp_utf8;
like   $mpsrc, qr/sub run_a \{ do \{ my \(\$x\) = \(1\); \$x \+ 100 \}/, "A's call site inlined A::helper's body (+100)";
unlike $mpsrc, qr/package A;\nsub helper/,                              'A::helper (the target) is removed';
like   $mpsrc, qr/package B;\nsub helper \{ my \(\$y\) = \@_; \$y \* 999 \}/, 'B::helper (same name, other package) is untouched';
ok eval { $parser->parse_string($dmp->child('lib/P.pm')->slurp_raw); 1 }, 'the multi-package file still parses';

done_testing;
