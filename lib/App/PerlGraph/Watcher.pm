package App::PerlGraph::Watcher;
use v5.36;
our $VERSION = q{0.064};
use Moo;
use App::PerlGraph::Indexer ();   # shared $PERL_RX / @IGNORE_DIRS / ->dirs

# Blocks until a relevant (Perl-file) change appears under the indexer's root,
# then returns -- so `pcg watch` can sync on demand instead of busy-polling.
#
# Two backends, chosen once at construction:
#   inotify  (Linux + Linux::Inotify2) -- event-driven, sub-second, no polling
#   poll     (everywhere else, or --poll) -- the portable mtime-signature loop
#
# Either way the source of truth is Indexer::sync (hash-diff), so a missed or
# spurious wake-up only costs a cheap no-op sync; the watcher just decides WHEN.

has indexer  => (is => 'ro', required => 1);
has interval => (is => 'ro', default => 2);   # poll period (seconds); poll backend only
has poll     => (is => 'ro', default => 0);   # force the poll backend

has backend  => (is => 'rwp');                 # 'inotify' | 'poll'
has _in      => (is => 'rw');                   # Linux::Inotify2 handle (inotify backend)
has _watched => (is => 'ro', default => sub { {} });   # dir => watch (inotify backend)
has _sig     => (is => 'rw', default => '');    # last mtime signature (poll backend)

sub root ($self) { $self->indexer->root }

# number of directories under inotify watch (0 for the poll backend)
sub nwatched ($self) { scalar keys %{ $self->_watched } }

sub BUILD ($self, $) {
    if (!$self->poll && $^O eq 'linux' && $self->_setup_inotify) {
        $self->_set_backend('inotify');
    }
    else {
        $self->_set_backend('poll');
        $self->_sig($self->_signature);          # baseline; later changes are diffed against it
    }
}

# ---- backend: inotify -------------------------------------------------------

sub _mask {
    Linux::Inotify2::IN_CLOSE_WRITE() | Linux::Inotify2::IN_MOVED_TO()
        | Linux::Inotify2::IN_MOVED_FROM() | Linux::Inotify2::IN_CREATE()
        | Linux::Inotify2::IN_DELETE() | Linux::Inotify2::IN_MOVE_SELF()
        | Linux::Inotify2::IN_DELETE_SELF();
}

# Build the inotify handle and watch every directory under root. Returns false
# (so we fall back to polling) if the module is absent or the kernel watch
# limit is exhausted on a large tree (ENOSPC).
sub _setup_inotify ($self) {
    return 0 unless eval { require Linux::Inotify2; 1 };
    my $in = Linux::Inotify2->new or return 0;
    $in->blocking(0);
    $self->_in($in);
    return 1 if $self->_watch_tree($self->root);   # all/most dirs watched -> use inotify
    $self->_in(undef);                              # ENOSPC at setup -> fall back to polling
    return 0;
}

# Add a watch to $dir and each surviving descendant. Returns 0 if the kernel
# watch limit (ENOSPC) is hit, 1 otherwise. Never tears down a live handle: at
# setup the caller falls back to poll; at runtime we keep the watches we have.
sub _watch_tree ($self, $dir) {
    my $in = $self->_in or return 0;
    for my $d ($self->indexer->dirs($dir)) {
        next if $self->_watched->{$d};
        if (my $w = $in->watch($d, _mask())) {
            $self->_watched->{$d} = $w;
        }
        else {
            require Errno;
            if ($! == Errno::ENOSPC()) {
                warn "pcg watch: inotify watch limit reached (fs.inotify.max_user_watches); ",
                     "increase it or use --poll\n" unless $self->{_warned_enospc}++;
                return 0;
            }
            # transient per-dir failure (vanished mid-walk / perms): skip, keep going
        }
    }
    return 1;
}

sub _relevant_file ($self, $path) { $path =~ $App::PerlGraph::Indexer::PERL_RX }

# Drain the tail of an event burst (editor atomic-save = create+write+rename;
# `git checkout` = many) within a short quiet window, so one burst -> one sync.
# Also picks up watches for any directories created during the burst.
sub _coalesce ($self) {
    my $in = $self->_in; my $fd = $in->fileno;
    while (1) {
        my $rin = ''; vec($rin, $fd, 1) = 1;
        select(my $r = $rin, undef, undef, 0.15) or last;   # 150ms of quiet ends the burst
        my @ev = $in->read or last;
        for my $e (@ev) {
            if ($e->IN_IGNORED) { delete $self->_watched->{ $e->fullname }; next }
            $self->_watch_tree($e->fullname) if $e->IN_ISDIR && ($e->IN_CREATE || $e->IN_MOVED_TO);
        }
    }
}

sub _wait_inotify ($self, $timeout) {
    my $in = $self->_in; my $fd = $in->fileno;
    my $deadline = defined $timeout ? time + $timeout : undef;
    while (1) {
        my $wait = defined $deadline ? $deadline - time : undef;
        return 0 if defined $wait && $wait <= 0;
        my $rin = ''; vec($rin, $fd, 1) = 1;
        my $n = select(my $r = $rin, undef, undef, $wait);   # undef = block until an event
        return 0 if defined $deadline && !$n;                # timed out with nothing
        next unless $n;
        my $relevant = 0;
        for my $e ($in->read) {
            if ($e->IN_Q_OVERFLOW) { $relevant = 1; next }   # kernel dropped events -> resync
            # the kernel auto-removed this watch (dir deleted/moved) -> drop the
            # stale entry so the dir is re-watched if it comes back at the same path.
            if ($e->IN_IGNORED) { delete $self->_watched->{ $e->fullname }; next }
            if ($e->IN_ISDIR) {
                # a new directory: watch it (files may already be inside) and resync
                $self->_watch_tree($e->fullname), $relevant = 1
                    if $e->IN_CREATE || $e->IN_MOVED_TO;
                next;
            }
            $relevant = 1 if $self->_relevant_file($e->fullname);
        }
        next unless $relevant;
        $self->_coalesce;
        return 1;
    }
}

# ---- backend: poll ----------------------------------------------------------

# A cheap change fingerprint: every Perl file's path + mtime. Avoids re-hashing
# contents when nothing has moved (sync does the precise hash-diff once woken).
sub _signature ($self) {
    my $idx = $self->indexer;
    # _perl_files yields canonical (root-relative) keys -> stat the on-disk path.
    join "\0", map { "$_:" . ((stat $idx->_disk_path($_))[9] // 0) } sort $idx->_perl_files;
}

sub _wait_poll ($self, $timeout) {
    my $deadline = defined $timeout ? time + $timeout : undef;
    while (1) {
        my $now = $self->_signature;
        if ($now ne $self->_sig) { $self->_sig($now); return 1 }
        return 0 if defined $deadline && time >= $deadline;
        my $nap = $self->interval;
        $nap = $deadline - time if defined $deadline && $deadline - time < $nap;
        select undef, undef, undef, $nap > 0 ? $nap : 0.05;   # fractional sleep
    }
}

# ---- public -----------------------------------------------------------------

# Block until a relevant change (returns 1), or until $opt{timeout} seconds pass
# with none (returns 0). Without a timeout, blocks indefinitely.
sub wait_for_change ($self, %opt) {
    $self->backend eq 'inotify'
        ? $self->_wait_inotify($opt{timeout})
        : $self->_wait_poll($opt{timeout});
}

1;

__END__

=head1 NAME

App::PerlGraph::Watcher - watch a tree for changes (inotify or polling)

=head1 DESCRIPTION

Blocks until a relevant Perl-file change -- event-driven via L<Linux::Inotify2> on Linux, portable mtime-polling otherwise.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
