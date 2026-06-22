use v5.36;
use Test2::V0;
use Path::Tiny qw(path);
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Watcher;

my $HAVE_INOTIFY = $^O eq 'linux' && eval { require Linux::Inotify2; 1 };

# a watcher over a fresh temp dir seeded with $files = { 'rel.pm' => 'content', ... }
sub setup ($files) {
    my $dir = Path::Tiny->tempdir;
    for my $rel (keys %$files) {
        my $p = path($dir, $rel); $p->parent->mkpath; $p->spew($files->{$rel});
    }
    my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
    my $idx = App::PerlGraph::Indexer->new(store => $store, root => "$dir");
    return ($dir, $idx);
}

# --- backend selection -------------------------------------------------------
{
    my ($dir, $idx) = setup({ 'A.pm' => "package A; sub x {1} 1;\n" });
    is App::PerlGraph::Watcher->new(indexer => $idx, poll => 1)->backend, 'poll',
        '--poll forces the poll backend';
}
SKIP: {
    skip "not linux / no Linux::Inotify2", 3 unless $HAVE_INOTIFY;
    my ($dir, $idx) = setup({ 'A.pm' => "package A; 1;\n", 'lib/sub/B.pm' => "package B; 1;\n" });
    my $w = App::PerlGraph::Watcher->new(indexer => $idx);
    is $w->backend, 'inotify', 'auto-selects inotify on linux when the module is present';
    ok $w->nwatched >= 2, 'inotify watches the tree (root + subdirs) -- count is reported for the announce';
    is App::PerlGraph::Watcher->new(indexer => $idx, poll => 1)->nwatched, 0, 'poll backend watches no dirs';
}

# --- poll backend: detect change, ignore non-perl, time out cleanly ----------
{
    my ($dir, $idx) = setup({ 'A.pm' => "package A; 1;\n" });
    my $w = App::PerlGraph::Watcher->new(indexer => $idx, poll => 1, interval => 1);
    is $w->wait_for_change(timeout => 1), 0, 'no change -> times out (false)';

    utime(time + 5, time + 5, "" . path($dir, 'A.pm'));            # deterministic mtime bump
    is $w->wait_for_change(timeout => 3), 1, 'modified perl file -> change detected (true)';

    path($dir, 'notes.txt')->spew("hi");
    is $w->wait_for_change(timeout => 1), 0, 'a non-perl file change does not trigger';

    path($dir, 'New.pm')->spew("package New; 1;\n");
    is $w->wait_for_change(timeout => 3), 1, 'a newly added perl file triggers';
}

# --- inotify backend: live detection via a forked writer ---------------------
SKIP: {
    skip "not linux / no Linux::Inotify2", 5 unless $HAVE_INOTIFY;

    my ($dir, $idx) = setup({ 'A.pm' => "package A; 1;\n" });
    my $w = App::PerlGraph::Watcher->new(indexer => $idx);

    my $writer = sub ($code) {
        my $pid = fork // die "fork: $!";
        if (!$pid) { select undef, undef, undef, 0.4; $code->(); exit 0 }
        return $pid;
    };

    my $pid = $writer->(sub { path($dir, 'B.pm')->spew("package B; 1;\n") });
    is $w->wait_for_change(timeout => 5), 1, 'inotify detects a newly created perl file';
    waitpid $pid, 0;

    $pid = $writer->(sub { my $p = path($dir, 'deep', 'C.pm'); $p->parent->mkpath; $p->spew("package C; 1;\n") });
    is $w->wait_for_change(timeout => 5), 1, 'inotify detects a file in a newly created subdirectory';
    waitpid $pid, 0;

    # a non-perl change should not wake the inotify backend either
    $pid = $writer->(sub { path($dir, 'ignore.log')->spew("noise") });
    is $w->wait_for_change(timeout => 2), 0, 'inotify ignores a non-perl file change';
    waitpid $pid, 0;

    # delete + recreate a watched subdir: it must be re-watched (the IN_IGNORED
    # cleanup drops the stale watch entry so the new dir at the same path is caught)
    $pid = $writer->(sub { path($dir, 'deep')->remove_tree });
    is $w->wait_for_change(timeout => 5), 1, 'inotify detects the watched subdir being deleted';
    waitpid $pid, 0;
    $pid = $writer->(sub { my $p = path($dir, 'deep', 'D.pm'); $p->parent->mkpath; $p->spew("package D; 1;\n") });
    is $w->wait_for_change(timeout => 5), 1, 'a recreated subdir is re-watched (a file inside it is detected)';
    waitpid $pid, 0;
}

done_testing;
