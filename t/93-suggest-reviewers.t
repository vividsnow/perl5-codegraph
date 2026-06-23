use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Query;
use App::PerlGraph::Format;
use App::PerlGraph::CLI;

# suggest_reviewers is pure (authorship x the changed-file set) -- test it with synthetic
# git data, no repository needed. The store is required by the constructor but unused here.
my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
my $q = App::PerlGraph::Query->new(store => $s);

my $authors = {
    'lib/A.pm' => { alice => 10 },
    'lib/B.pm' => { alice => 2, bob => 8 },
    'lib/C.pm' => { bob => 5 },
    'lib/Z.pm' => { carol => 99 },          # NOT in the change -> carol must not be suggested
};
my $changed = ['lib/A.pm', 'lib/B.pm', 'lib/C.pm'];
my $rev = $q->suggest_reviewers($authors, $changed);

# bob = B(8) + C(5) = 13 ; alice = A(10) + B(2) = 12
is $rev->[0]{author},  'bob',   'top reviewer is the most-prolific author of the changed files';
is $rev->[0]{commits}, 13,      'bob: commit total across the changed files';
is $rev->[1]{author},  'alice', 'second reviewer';
is $rev->[1]{commits}, 12,      'alice: commit total';
ok !(grep { $_->{author} eq 'carol' } @$rev), 'an author of an UNCHANGED file is not suggested';
is $rev->[1]{files}, ['lib/A.pm', 'lib/B.pm'], 'each reviewer lists the changed files they touched';

my $txt = App::PerlGraph::Format::suggest_reviewers($rev, 'main', scalar @$changed);
like $txt, qr/Suggested reviewers.*`main`/s, 'format: header with the ref';
like $txt, qr/\*\*bob\*\* -- 13 commit/,      'format: top reviewer line';
like $txt, qr/3 changed code file/,           'format: changed-file count';
like App::PerlGraph::Format::suggest_reviewers([], 'main', 0), qr/no changed code files/, 'format: empty state';

# CLI error path: an indexed but NON-git directory -> a clear message + failure exit.
# Capture STDERR via a REAL file (not an in-memory scalar): App::PerlGraph::Git::_run
# dups fd 2 to silence git, which an in-memory STDERR handle can't survive.
{
    my $d = tempdir; $d->child('lib')->mkpath; $d->child('.pcg')->mkpath;
    $d->child('lib/M.pm')->spew_utf8("package M;\nsub x { 1 }\n1;\n");
    my $st = App::PerlGraph::Store->new(path => $d->child('.pcg/graph.db')->stringify); $st->init;
    App::PerlGraph::Indexer->new(store => $st, root => "$d")->index_all;
    my $errf = Path::Tiny->tempfile;
    my $rc;
    {
        open my $save, '>&', \*STDERR or die "dup STDERR: $!";
        open STDERR, '>', "$errf" or die "redirect STDERR: $!";
        $rc = App::PerlGraph::CLI->run('suggest-reviewers', 'main', "$d");
        open STDERR, '>&', $save;
    }
    is $rc, 1, 'suggest-reviewers on a non-git directory returns failure';
    like $errf->slurp_utf8, qr/Not a git repository/, '... with a clear not-a-git message';
}

done_testing;
