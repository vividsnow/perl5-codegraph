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

# Helper exports two subs: `live` (called cross-package -> a live export) and `dead_one`
# (exported but called by nobody -> RETRACTABLE).
$d->child('lib/Helper.pm')->spew_utf8(<<'PL');
package Helper;
use Exporter 'import';
our @EXPORT_OK = qw(live dead_one);
sub live { 1 }
sub dead_one { 2 }
1;
PL

# Main: `entry` calls Helper::live (keeps it live) + both clones (keeps them referenced) +
# _used_helper. `_orphan` is private and called by nobody -> REMOVABLE. clone_a/clone_b are
# byte-identical -> a type-1 CLONE group (a pcg_dedupe target) but, being called, NOT removable.
$d->child('lib/Main.pm')->spew_utf8(<<'PL');
package Main;
sub entry {
    Helper::live();
    Main::clone_a([]);
    Main::clone_b([]);
    return _used_helper();
}
sub _used_helper { 42 }
sub _orphan { 99 }
sub clone_a {
    my ($self, $items) = @_;
    my @out;
    for my $it (@$items) {
        next unless $it->{ok};
        push @out, $it->{val} * 2;
    }
    return \@out;
}
sub clone_b {
    my ($self, $items) = @_;
    my @out;
    for my $it (@$items) {
        next unless $it->{ok};
        push @out, $it->{val} * 2;
    }
    return \@out;
}
1;
PL

my $s = App::PerlGraph::Store->new(path => $d->child('.pcg/graph.db')->stringify); $s->init;
App::PerlGraph::Indexer->new(store => $s, root => "$d")->index_all;
my $q = App::PerlGraph::Query->new(store => $s);

my $r = $q->tidy(min_nodes => 15);     # low floor so the small clone bodies qualify
my %rm  = map { ($_->{qualified_name} => 1) } @{ $r->{removable} };
my %ret = map { ($_->{qualified_name} => 1) } @{ $r->{retractable} };

# --- removable: unreferenced, non-exported subs pcg_rm can delete ---
ok $rm{'Main::_orphan'},      'an orphan private sub is removable';
ok !$rm{'Main::clone_a'},     'a CALLED clone is not removable';
ok !$rm{'Main::_used_helper'},'a called private helper is not removable';
ok !$rm{'Helper::dead_one'},  'an EXPORTED dead sub is not in removable (rm refuses exports) -- it is retractable';
ok !$rm{'Helper::live'},      'a live export is not removable';

# --- retractable: exported subs no other in-repo package uses ---
ok $ret{'Helper::dead_one'},  'an exported, uncalled sub is retractable';
ok !$ret{'Helper::live'},     'an export called cross-package is not retractable';

# --- clones: structural duplicate groups pcg_dedupe can collapse ---
is scalar @{ $r->{clones} }, 1, 'exactly one clone group';
my %cl = map { ($_->{qualified_name} => 1) } @{ $r->{clones}[0]{members} };
ok $cl{'Main::clone_a'} && $cl{'Main::clone_b'}, 'the two byte-identical subs form the clone group';

# --- renderer ---
my $txt = App::PerlGraph::Format::tidy($r);
like $txt, qr/Tidy -- cleanup opportunities/, 'format: header';
like $txt, qr/Removable dead code.*`pcg rm/s,  'format: removable bucket names the rm command';
like $txt, qr/`Main::_orphan`/,                'format: lists the orphan';
like $txt, qr/Retractable exports/,            'format: retractable bucket';
like $txt, qr/`Helper::dead_one`/,             'format: lists the dead export';
like $txt, qr/Clone groups.*`pcg dedupe/s,     'format: clones bucket names the dedupe command';
like App::PerlGraph::Format::tidy({ removable => [], retractable => [], clones => [] }),
    qr/_nothing to tidy_/, 'format: clean-state message';
like $txt, qr/pcg tidy --apply/, 'format: survey points at --apply to execute the safe subset';

# --- APPLY: dedupe the clone group + rm the orphan, keep the rest, result compiles ----------
require App::PerlGraph::Refactor;
my $d2 = tempdir; $d2->child('lib')->mkpath; $d2->child('.pcg')->mkpath;
# `entry` is exported (anchors the call graph so it isn't itself removable) and calls both clones
# + kept; `orphan` is private + uncalled (removable). dup_a/dup_b are byte-identical (a clone group).
$d2->child('lib/App.pm')->spew_utf8(<<'PL');
package App;
use Exporter 'import';
our @EXPORT_OK = ('entry');
sub entry { App::dup_a([]) + App::dup_b([]) + kept() }
sub kept { 7 }
sub dup_a {
    my ($self, $items) = @_;
    my @out;
    for my $it (@$items) {
        next unless $it->{ok};
        push @out, $it->{val} * 2;
    }
    return \@out;
}
sub dup_b {
    my ($self, $items) = @_;
    my @out;
    for my $it (@$items) {
        next unless $it->{ok};
        push @out, $it->{val} * 2;
    }
    return \@out;
}
sub orphan { 99 }
1;
PL
my $s2 = App::PerlGraph::Store->new(path => $d2->child('.pcg/graph.db')->stringify); $s2->init;
App::PerlGraph::Indexer->new(store => $s2, root => "$d2")->index_all;
my $ra = App::PerlGraph::Refactor->new(store => $s2, root => "$d2")->tidy(min_nodes => 15, apply => 1);

ok $ra->{applied}, 'apply: result is flagged applied';
is scalar @{ $ra->{deduped} }, 1, 'apply: one clone group deduped';
ok( (grep { $_ eq 'App::dup_b' } map { @{ $_->{replaced} } } @{ $ra->{deduped} }), 'apply: dup_b rewritten to the canonical' );
ok( (grep { $_->{name} eq 'App::orphan' } @{ $ra->{removed} }), 'apply: the orphan sub was removed' );

my $src = $d2->child('lib/App.pm')->slurp_utf8;
like   $src, qr/sub entry/,                          'apply: the exported entry is kept';
like   $src, qr/sub dup_a \{\n\s+my \(\$self/,       'apply: the canonical clone keeps its real body';
like   $src, qr/sub dup_b \{ goto &App::dup_a \}/,   'apply: the duplicate is now a goto stub';
unlike $src, qr/sub orphan/,                         'apply: the orphan is gone';

my $compile = `$^X -I@{[ $d2->child('lib') ]} -c @{[ $d2->child('lib/App.pm') ]} 2>&1`;
like $compile, qr/syntax OK/, 'apply: the rewritten file still compiles';

# nothing-to-do apply
like App::PerlGraph::Format::tidy({ applied => 1, deduped => [], removed => [], skipped => [] }),
    qr/_nothing to apply_/, 'format: applied clean-state message';

done_testing;
