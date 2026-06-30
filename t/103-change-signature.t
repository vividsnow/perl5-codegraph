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

my $dir = tempdir; $dir->child('lib')->mkpath; $dir->child('.pcg')->mkpath;
$dir->child('lib/M.pm')->spew_utf8(<<'PL');
package M;
use v5.36;
sub area ($w, $h) { $w * $h }
sub run { my $a = M::area(3, 4); my $b = M::area(5, 6); return $a + $b }
sub recur ($w, $h) { M::area($w, $h) }
sub splat { my @d = (1, 2); M::area(@d) }
sub mcall ($self) { $self->area(7, 8) }
sub greet ($self, $name) { "$name" }
sub fac ($n, $unused) { $n <= 1 ? 1 : $n * M::fac($n - 1, 0) }   # $unused is removable; $n is not
sub call_fac { M::fac(5, 0) }
sub braced ($a, $tag) { "item-${tag}-$a" }   # $tag is used ONLY in braced ${...} interpolation
sub deps ($base, $derived = $base + 1) { $derived * 2 }   # $derived's DEFAULT references $base
sub opt ($a, $b = 5) { $a + $b }              # $b is optional
sub slurpy ($first, @rest) { $first + @rest } # @rest must stay last
1;
PL

my $s = App::PerlGraph::Store->new(path => $dir->child('.pcg/graph.db')->stringify); $s->init;
App::PerlGraph::Indexer->new(store => $s, root => "$dir")->index_all;
my $rf = App::PerlGraph::Refactor->new(store => $s, root => "$dir");

# --- ADD a trailing parameter (dry run) -----------------------------------------------
my $add = $rf->change_signature('M::area', add => '$z = 0', value => '0');
is $add->{new_signature}, '($w, $h, $z = 0)', 'add: new signature appends the parameter';
my @sites = grep { !$_->{def} } @{ $add->{edits} };
is scalar(@sites), 3, 'add: three determinate call sites are edited (two in run, one in recur)';
is scalar(@{ $add->{edits} }), 4, 'add: plus the definition = four edits';
is $add->{applied}, 0, 'add: dry run writes nothing';
ok +(grep { $_->{replacement} eq '3, 4, 0' } @sites), 'add: a call site gets the value inserted at the new position';
# splat (M::area(@d)) and the $obj->method call are reported, never edited
is scalar(@{ $add->{frontier} }), 2, 'add: the splat call and the method call go to the frontier';
ok +(grep { $_->{why} =~ /indeterminate/ } @{ $add->{frontier} }), 'add: the @d splat is flagged indeterminate';
ok +(grep { $_->{why} =~ /method call/ } @{ $add->{frontier} }), 'add: the $self->area call is flagged a method call';

# --- the renderer ---------------------------------------------------------------------
my $txt = App::PerlGraph::Format::change_signature($add);
like $txt, qr/Change signature `M::area`/,            'format: header names the target';
like $txt, qr/`\(\$w, \$h\)` -> `\(\$w, \$h, \$z = 0\)`/, 'format: shows the signature transformation';
like $txt, qr/Manual review/,                          'format: lists the frontier';

# --- ADD at a NON-appending position (--at 1, inserts at the front) --------------------
my $ins = $rf->change_signature('M::area', add => '$z', at => 1);    # value defaults to undef
is $ins->{new_signature}, '($z, $w, $h)', 'add --at 1: the parameter is spliced in at the front';
ok +(grep { $_->{replacement} eq 'undef, 3, 4' } grep { !$_->{def} } @{ $ins->{edits} }),
    'add --at 1: the default value is inserted at the front of a call site';

# --- REMOVE an UNUSED parameter (apply) -- the body must still COMPILE afterward -------
my $rm = $rf->change_signature('M::fac', remove => 2, apply => 1);
is $rm->{new_signature}, '($n)', 'remove: new signature drops the unused parameter';
ok $rm->{applied} >= 3, 'remove: applied the definition + the call sites (incl. the recursive self-call)';
my $after = $dir->child('lib/M.pm')->slurp_utf8;
like $after, qr/sub fac \(\$n\)/,        'remove: the definition signature is rewritten';
like $after, qr/M::fac\(\$n - 1\)/,      'remove: the recursive self-call drops its argument';
like $after, qr/M::fac\(5\)/,            'remove: the external call drops its argument';
# the regression guard for the bug this refuses to introduce: the edited file must still parse
my $cfile = $dir->child('lib/M.pm')->stringify;
like scalar(`$^X -c "$cfile" 2>&1`), qr/syntax OK/, 'remove: the edited file still compiles (no dangling removed variable)';

# --- safety: a method (first param $self) is refused ----------------------------------
my $meth = $rf->change_signature('M::greet', remove => 2);
like $meth->{error}, qr/method/, 'refuses a method (its $obj->method call sites can not be position-mapped)';

# --- safety: refuse to remove a parameter the body STILL USES (it would not compile) ---
like $rf->change_signature('M::area', remove => 1)->{error}, qr/still using \$w/,
    'refuses to remove a parameter the body still references (area uses $w in $w * $h)';
like $rf->change_signature('M::braced', remove => 2)->{error}, qr/still using \$tag/,
    'refuses to remove a parameter used only in braced ${...} interpolation (not just a bare $tag)';
like $rf->change_signature('M::deps', remove => 1)->{error}, qr/another parameter's default/,
    'refuses to remove a parameter another parameter\'s default still references ($derived = $base + 1)';
like $rf->change_signature('M::opt', add => '$c')->{error}, qr/required parameter can't follow/,
    'refuses to add a required parameter after an optional one (the signature would not compile)';
like $rf->change_signature('M::slurpy', add => '$x')->{error}, qr/slurpy.*must be last/,
    'refuses to add a parameter after a slurpy \@rest (the slurpy must stay last)';

# --- the applied-plan renderer (the $rm result was written to disk) -------------------
like App::PerlGraph::Format::change_signature($rm), qr/Applied \*\*\d+\*\* edit/, 'format: the applied branch reports the edit count';

# --- errors ---------------------------------------------------------------------------
like $rf->change_signature('M::recur', remove => 9)->{error}, qr/1-based position/, 'rejects an out-of-range remove position';
like $rf->change_signature('M::nope', remove => 1)->{error},  qr/no plain function/, 'rejects an unknown function';
like $rf->change_signature('M::recur')->{error}, qr/--add.*--remove/, 'requires an operation';
like $rf->change_signature('M::recur', add => 1, remove => 1)->{error}, qr/only one of/, 'rejects more than one operation';

# --- reorder: permute the signature + every resolved call site's argument list -----------
my $ro = $rf->change_signature('M::area', reorder => '2,1', apply => 1);
ok !$ro->{error}, 'reorder succeeds' or diag $ro->{error};
is $ro->{op}, 'reorder',          'op is reorder';
is $ro->{position}, '2,1',        'the permutation is reported';
is $ro->{new_signature}, '($h, $w)', 'the signature parameters are swapped';
my $rosrc = $dir->child('lib/M.pm')->slurp_utf8;
like $rosrc, qr/sub area \(\$h, \$w\)/, 'the signature is reordered on disk';
like $rosrc, qr/M::area\(4, 3\)/,       'a literal call M::area(3, 4) -> (4, 3)';
like $rosrc, qr/M::area\(6, 5\)/,       'a literal call M::area(5, 6) -> (6, 5)';
like $rosrc, qr/M::area\(\$h, \$w\)/,   'the recursive call M::area($w, $h) -> ($h, $w)';
ok( (grep { ($_->{why} // '') =~ /method call/ }   @{ $ro->{frontier} }), 'the $self->area method call is reported, not reordered' );
ok( (grep { ($_->{why} // '') =~ /indeterminate/ } @{ $ro->{frontier} }), 'the splat call M::area(@d) is reported, not reordered' );
like $rf->change_signature('M::opt', reorder => '2,2')->{error},   qr/permutation of 1\.\.2/, 'rejects a non-permutation (a repeated position)';
like $rf->change_signature('M::opt', reorder => '1,2')->{error},   qr/current order/,         'rejects a no-op reorder';
like $rf->change_signature('M::opt', reorder => '2,1,3')->{error}, qr/permutation of 1\.\.2/, 'rejects a reorder of the wrong length';
like App::PerlGraph::Format::change_signature($ro), qr/reorder parameters \(2,1\)/, 'format: the reorder verb names the permutation';
like $rf->change_signature('M::run', remove => 1)->{error}, qr/no explicit signature/, 'refuses a sub with no explicit signature (cannot map positions)';
like $rf->change_signature('M::recur', add => '123bad')->{error}, qr/takes a parameter/, 'rejects a malformed --add spec';
like $rf->change_signature('M::recur', add => '$z', at => 99)->{error}, qr/1-based position/, 'rejects an out-of-range --at position';
like App::PerlGraph::Format::change_signature({ error => 'boom' }), qr/\*\*error\*\*: boom/, 'format: renders an error result';

done_testing;
