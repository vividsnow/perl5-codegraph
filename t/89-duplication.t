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
# alpha and beta are TYPE-2 clones: identical body shape, only the names and the
# literal (2 vs 10) differ. gamma has a different structure -> must not group.
$d->child('lib/C.pm')->spew_utf8(<<'PL');
package C;
sub alpha {
    my ($self, $items) = @_;
    my @out;
    for my $it (@$items) {
        next unless $it->{ok};
        push @out, $it->{val} * 2;
    }
    return \@out;
}
sub beta {
    my ($obj, $rows) = @_;
    my @res;
    for my $r (@$rows) {
        next unless $r->{valid};
        push @res, $r->{n} * 10;
    }
    return \@res;
}
sub gamma {
    my ($self, $x) = @_;
    my $y = $x + 1;
    return { sum => $y, label => "g", parts => [ $y, $y * $y, $y - 1 ] };
}
1;
PL
my $s = App::PerlGraph::Store->new(path => $d->child('.pcg/graph.db')->stringify); $s->init;
App::PerlGraph::Indexer->new(store => $s, root => "$d")->index_all;
my $q = App::PerlGraph::Query->new(store => $s);

my $g = $q->duplication(min_nodes => 15);
is scalar @$g, 1,       'exactly one clone group (the type-2 pair)';
is $g->[0]{count}, 2,   'the group has two copies';
ok $g->[0]{nodes} >= 15, 'the group records its body size in AST nodes';
my %names; $names{ $_->{qualified_name} } = 1 for @{ $g->[0]{members} };
ok $names{'C::alpha'} && $names{'C::beta'}, 'alpha and beta group despite renamed vars + a changed literal';
ok !$names{'C::gamma'},                     'a structurally-different sub does not group';

is scalar @{ $q->duplication(min_nodes => 100000) }, 0, 'a high min_nodes raises the floor so nothing qualifies';

my $txt = App::PerlGraph::Format::duplication($g);
like $txt, qr/Duplicate code/, 'format: header';
like $txt, qr/2 copies/,       'format: the copy count';
like $txt, qr/`C::alpha`/,     'format: lists a member';
like App::PerlGraph::Format::duplication([]), qr/_none found_/, 'format: clean-state message';

done_testing;
