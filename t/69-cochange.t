use v5.36;
use Test2::V0;
use App::PerlGraph::Store;
use App::PerlGraph::Query;
use App::PerlGraph::Format;

# A.pm and B.pm change together 4x (and A.pm alone once); C.pm and D.pm together 3x.
# A.pm IS statically linked to B.pm (a_fn calls b_fn); C.pm/D.pm are NOT linked.
my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
$s->insert_node({ id => 'a', kind => 'function', name => 'a_fn', qualified_name => 'A::a_fn', file_path => 'lib/A.pm', start_line => 1 });
$s->insert_node({ id => 'b', kind => 'function', name => 'b_fn', qualified_name => 'B::b_fn', file_path => 'lib/B.pm', start_line => 1 });
$s->insert_node({ id => 'c', kind => 'function', name => 'c_fn', qualified_name => 'C::c_fn', file_path => 'lib/C.pm', start_line => 1 });
$s->insert_node({ id => 'd', kind => 'function', name => 'd_fn', qualified_name => 'D::d_fn', file_path => 'lib/D.pm', start_line => 1 });
$s->insert_edge({ source => 'a', target => 'b', kind => 'calls', provenance => 'static' });   # A -> B static link

my $tx = [
    [qw(lib/A.pm lib/B.pm)], [qw(lib/A.pm lib/B.pm)], [qw(lib/A.pm lib/B.pm)], [qw(lib/A.pm lib/B.pm)],
    [qw(lib/A.pm)],
    [qw(lib/C.pm lib/D.pm)], [qw(lib/C.pm lib/D.pm)], [qw(lib/C.pm lib/D.pm)],
    [qw(README.md lib/A.pm)],   # non-code file is ignored
];

my $q = App::PerlGraph::Query->new(store => $s);
my @cc = $q->cochange($tx, min_support => 3, limit => 5);

# C<->D has Jaccard 3/3 = 1.0 (> A<->B's 4/5), so it ranks first
is $cc[0]{a}, 'lib/C.pm';   is $cc[0]{b}, 'lib/D.pm';
is $cc[0]{support}, 3,                 'C<->D co-changed in 3 commits';
ok !$cc[0]{linked},                    'C<->D has no static link (hidden coupling)';
is $cc[1]{a}, 'lib/A.pm';   is $cc[1]{b}, 'lib/B.pm';
ok  $cc[1]{linked},                    'A<->B is statically linked';
ok !(grep { $_->{a} =~ /README/ || $_->{b} =~ /README/ } @cc), 'non-code files are excluded';

# min_support filters out rare pairs
is scalar($q->cochange($tx, min_support => 10)), 0, 'min_support filters everything when too high';

# max_files skips a sweeping commit (e.g. a version bump touching everything) that would
# spuriously inflate coupling. The sweep below touches C, D + 6 more = 8 code files.
my $tx2 = [ @$tx, [ 'lib/C.pm', 'lib/D.pm', map { "lib/Z$_.pm" } 1 .. 6 ] ];
my ($cd_cap)   = grep { $_->{a} eq 'lib/C.pm' && $_->{b} eq 'lib/D.pm' } $q->cochange($tx2, min_support => 3, max_files => 4);
my ($cd_nocap) = grep { $_->{a} eq 'lib/C.pm' && $_->{b} eq 'lib/D.pm' } $q->cochange($tx2, min_support => 3, max_files => 99);
is $cd_cap->{support},   3, 'max_files skips the 8-file sweep (C<->D support stays 3)';
is $cd_nocap->{support}, 4, '... but without the cap the sweep counts (support 4)';

# format flags the hidden coupling
my $txt = App::PerlGraph::Format::cochange(\@cc);
like $txt, qr/Co-change/i,                          'format: header';
like $txt, qr/lib\/C\.pm.*lib\/D\.pm.*no static link/, 'format: marks the unlinked (hidden) pair';
like App::PerlGraph::Format::cochange([]), qr/_none_/, 'format: empty';

done_testing;
