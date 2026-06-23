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

# A non-trivial body (>= 12 CST nodes so it gets a clone fingerprint).
my $body  = "{\n    my (\$x, \$y) = \@_;\n    my \$total = 0;\n    for my \$i (1 .. \$x) { \$total += \$i * \$y }\n    return \$total;\n}";
my $body2 = "{\n    my (\$a, \$b) = \@_;\n    my \$sum = 0;\n    for my \$j (1 .. \$a) { \$sum += \$j * \$b }\n    return \$sum;\n}";   # type-2: renamed vars

sub setup {
    my $d = tempdir; $d->child('lib')->mkpath; $d->child('.pcg')->mkpath;
    $d->child('lib/A.pm')->spew_utf8("package A;\nuse v5.36;\nsub compute $body\n1;\n");
    $d->child('lib/B.pm')->spew_utf8("package B;\nuse v5.36;\nuse A;\nsub compute $body\n1;\n");  # EXACT dup, loads A
    $d->child('lib/C.pm')->spew_utf8("package C;\nuse v5.36;\nsub compute $body2\n1;\n");  # type-2 clone
    $d->child('lib/D.pm')->spew_utf8("package D;\nuse v5.36;\nsub compute $body\n1;\n");   # EXACT dup but does NOT load A
    my $st = App::PerlGraph::Store->new(path => $d->child('.pcg/graph.db')->stringify); $st->init;
    App::PerlGraph::Indexer->new(store => $st, root => "$d")->index_all;
    return ($d, App::PerlGraph::Refactor->new(store => $st, root => "$d"));
}

# --- apply: the exact duplicate is rewritten to delegate; the type-2 clone is left alone ---
my ($d, $rf) = setup();
my $plan = $rf->dedupe('A::compute', apply => 1);
is $plan->{canonical}, 'A::compute',                    'the target is kept as the canonical copy';
is scalar @{ $plan->{replaced} }, 1,                    'exactly one EXACT duplicate is rewritten';
is $plan->{replaced}[0]{name}, 'B::compute',            'the exact duplicate (B) is the one rewritten';
is $plan->{applied}, 1,                                 'one edit was applied';
ok( (grep { $_->{name} eq 'C::compute' && $_->{why} =~ /type-2/ } @{ $plan->{skipped} }),
    'the type-2 clone (C) is reported as skipped, not rewritten' );
ok( (grep { $_->{name} eq 'D::compute' && $_->{why} =~ /does not .use A/ } @{ $plan->{skipped} }),
    'an EXACT clone whose file does not load the canonical is skipped (the goto would die)' );

like   $d->child('lib/B.pm')->slurp_utf8, qr/sub compute \{ goto &A::compute \}/, 'B now delegates to the canonical';
unlike $d->child('lib/B.pm')->slurp_utf8, qr/\$total/,                            "B's duplicated body is gone";
like   $d->child('lib/C.pm')->slurp_utf8, qr/\$sum/,                              'the type-2 clone C is untouched';
like   $d->child('lib/A.pm')->slurp_utf8, qr/\$total/,                            'the canonical A is untouched';
ok eval { $parser->parse_string($d->child('lib/B.pm')->slurp_raw); 1 },          'the rewritten file still parses';

# --- dry-run writes nothing ---
my ($d2, $rf2) = setup();
my $dry = $rf2->dedupe('A::compute');
is $dry->{applied}, 0,                                  'dry-run applies nothing';
is scalar @{ $dry->{replaced} }, 1,                     'dry-run still reports the planned rewrite';
like $d2->child('lib/B.pm')->slurp_utf8, qr/\$total/,   'dry-run leaves B unchanged on disk';

# --- a target not in a clone group errors clearly ---
my ($d3, $rf3) = setup();
$d3->child('lib/Solo.pm')->spew_utf8("package Solo;\nsub only { 1 }\n1;\n");
App::PerlGraph::Indexer->new(store => $rf3->store, root => "$d3")->index_all;
like $rf3->dedupe('Solo::only')->{error}, qr/not part of a structural clone group/, 'a non-clone target errors';

# --- a clone group carrying an :attribute is refused (the goto stub can't preserve it) ---
my $pd = tempdir; $pd->child('lib')->mkpath; $pd->child('.pcg')->mkpath;
$pd->child('lib/P.pm')->spew_utf8("package P;\nuse v5.36;\nsub one :lvalue $body\nsub two :lvalue $body\n1;\n");
my $pst = App::PerlGraph::Store->new(path => $pd->child('.pcg/graph.db')->stringify); $pst->init;
App::PerlGraph::Indexer->new(store => $pst, root => "$pd")->index_all;
like App::PerlGraph::Refactor->new(store => $pst, root => "$pd")->dedupe('P::one')->{error},
    qr/prototype or :attribute/, 'a clone group carrying an :attribute is refused (delegation would drop it)';

# --- rendering ---
like App::PerlGraph::Format::dedupe($plan), qr/Deduplicate clone group/, 'renders a header';

done_testing;
