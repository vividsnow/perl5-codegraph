use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Refactor;
use App::PerlGraph::Format;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

# extract works from the file + parser (not the graph), so a bare in-memory store is enough.
my $d = tempdir; $d->child('lib')->mkpath;
my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
sub refac    { App::PerlGraph::Refactor->new(store => $store, root => "$d") }
sub write_pm { $d->child('lib/M.pm')->spew_utf8($_[0]) }
sub body     { $d->child('lib/M.pm')->slurp_utf8 }
sub compiles { `$^X -I@{[ $d->child('lib') ]} -c @{[ $d->child('lib/M.pm') ]} 2>&1` =~ /syntax OK/ }

# --- clean scalar extraction: inputs read from outside, outputs used afterwards ----------
write_pm(<<'PL');
package M;
use v5.36;
sub calc {
    my ($a, $b) = @_;
    my $sum = $a + $b;
    my $prod = $a * $b;
    return $sum + $prod;
}
1;
PL
my $r = refac->extract('lib/M.pm', '5-6', 'compute', apply => 1);
ok !$r->{error}, 'clean scalar extraction succeeds' or diag $r->{error};
is [ sort @{ $r->{inputs} } ],  [ '$a', '$b' ],      'inputs = the outer vars the range reads';
is [ sort @{ $r->{outputs} } ], [ '$prod', '$sum' ], 'outputs = the range-locals used afterwards';
ok compiles(), 'the rewritten file still compiles';
like body(), qr/sub compute \{/,                                  'the new sub was created';
like body(), qr/my \(\$prod, \$sum\) = compute\(\$a, \$b\)/,      'the call site binds the returns';
like body(), qr/sub calc \{.*sub compute \{/s, 'the new sub is placed after the enclosing one';

# --- void block: a range with no outputs becomes a plain call -----------------------------
write_pm(<<'PL');
package M;
use v5.36;
sub go {
    my ($x) = @_;
    warn "a $x";
    warn "b $x";
    return 1;
}
1;
PL
my $v = refac->extract('lib/M.pm', '5-6', 'logit', apply => 1);
is $v->{inputs},  [ '$x' ], 'void block: the input is inferred';
is $v->{outputs}, [],       'void block: no outputs';
ok compiles(),              'void-block result compiles';
like body(), qr/^\s*logit\(\$x\);/m, 'void call site has no binding';

# --- array input + output --------------------------------------------------------------
write_pm(<<'PL');
package M;
use v5.36;
sub go {
    my @items = @_;
    my @doubled = map { $_ * 2 } @items;
    return scalar @doubled;
}
1;
PL
my $ar = refac->extract('lib/M.pm', '5-5', 'twice', apply => 1);
is $ar->{inputs},  [ '@items' ],   'array input recognized (@items read via the body)';
is $ar->{outputs}, [ '@doubled' ], 'array output recognized';
ok compiles(),                     'array I/O result compiles';

# a variable used ONLY via braced interpolation ${...} must still be detected (input + output)
write_pm(<<'PL');
package M;
use v5.36;
sub go {
    my ($base) = @_;
    my $label = "${base}_id";
    return "key:${label}:end";
}
1;
PL
my $br = refac->extract('lib/M.pm', '5-5', 'mklabel', apply => 1);
ok !$br->{error},          'braced-var extraction succeeds' or diag $br->{error};
is $br->{inputs},  [ '$base' ],  'a $base used only as ${base} in the range is an INPUT';
is $br->{outputs}, [ '$label' ], 'a $label used only as ${label} after the range is an OUTPUT';
ok compiles(),             'the braced-var result compiles (would not, if ${label} were missed)';

# --- refusals: anything not provably behaviour-preserving --------------------------------
write_pm("package M;\nsub go {\n  my (\$x) = \@_;\n  my \$y = \$x + 1;\n  return \$y if \$y;\n}\n1;\n");
like refac->extract('lib/M.pm', '4-5', 'b')->{error}, qr/`return`/,        'refuses non-local control flow';
write_pm("package M;\nsub go {\n  my \$t = 0;\n  \$t += 5;\n  print \$t;\n}\n1;\n");
like refac->extract('lib/M.pm', '4-4', 'b')->{error}, qr/modifies \$t/,    'refuses mutating an outer variable';
write_pm("package M;\nsub go {\n  my (\$x) = \@_;\n  print \"\$x\";\n  print \@_;\n}\n1;\n");
like refac->extract('lib/M.pm', '5-5', 'b')->{error}, qr/\@_/,             'refuses a direct @_ read';
write_pm("package M;\nsub go {\n  my \$x = 1\n    + 2\n    + 3;\n  return \$x;\n}\n1;\n");
like refac->extract('lib/M.pm', '4-4', 'b')->{error}, qr/split a statement/,'refuses a range that splits a statement';
write_pm("package M;\nsub go {\n  my \$x = 1;\n  print \$x }\n1;\n");   # last stmt shares the `}` line
like refac->extract('lib/M.pm', '4-4', 'b')->{error}, qr/closing brace/, 'refuses when the range\'s last line also holds the sub\'s closing brace (would eat it)';
write_pm("package M;\nuse v5.36;\nsub go {\n  state \$n = 0;\n  \$n++;\n  return \$n;\n}\n1;\n");
like refac->extract('lib/M.pm', '4-4', 'b')->{error}, qr/state/, 'refuses a range declaring a `state` variable (persistence would not survive extraction)';
write_pm("package M;\nsub go {\n  my \@a = (1);\n  my \@b = (2);\n  return scalar(\@a) + scalar(\@b);\n}\n1;\n");
like refac->extract('lib/M.pm', '3-4', 'b')->{error}, qr/more than one array.hash output/, 'refuses two array outputs (the call site `my (@a,@b)=` would let @a swallow everything)';
write_pm("package M;\nsub go { my \$x = 1; return \$x }\n1;\n");
like refac->extract('lib/M.pm', '99-100', 'b')->{error}, qr/not inside a single sub/, 'refuses a range outside any sub';
like refac->extract('lib/M.pm', 'oops', 'b')->{error},   qr/START-END/,     'refuses a malformed range';
like refac->extract('lib/M.pm', '2-2', '9bad')->{error}, qr/bare sub name/, 'refuses an invalid sub name';

# --- dry-run writes nothing --------------------------------------------------------------
write_pm("package M;\nuse v5.36;\nsub go {\n    my (\$a) = \@_;\n    my \$z = \$a * 2;\n    return \$z;\n}\n1;\n");
my $before = body();
my $dry = refac->extract('lib/M.pm', '5-5', 'dbl');
ok !$dry->{applied},          'dry-run is not applied';
is body(), $before,           'dry-run leaves the file byte-for-byte untouched';
like App::PerlGraph::Format::extract($dry), qr/dry run/,    'format: dry-run renderer';
like App::PerlGraph::Format::extract($dry), qr/sub dbl \{/, 'format: shows the generated sub';

done_testing;
