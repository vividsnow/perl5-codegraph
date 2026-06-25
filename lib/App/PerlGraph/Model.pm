package App::PerlGraph::Model;
use v5.36;
our $VERSION = q{0.065};
use Exporter 'import';
use Digest::SHA qw(sha1_hex);

our @EXPORT_OK = qw(
    node_id package_of qualify is_builtin is_external is_universal is_public sink_type
    NODE_KINDS EDGE_KINDS PROVENANCE
);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

use constant NODE_KINDS => [qw(file package class function method field constant route)];
use constant EDGE_KINDS => [qw(contains calls references imports extends implements overrides sink)];
use constant PROVENANCE => [qw(static inferred symtab optree mop xs framework heuristic llm)];

my %BUILTIN = map { $_ => 1 } qw(
    print printf say sprintf warn die defined ref bless wantarray
    push pop shift unshift splice map grep sort reverse join split
    keys values each exists delete scalar length substr index rindex
    open close read write chomp chop chr ord lc uc lcfirst ucfirst
    eval do require return last next redo local my our
    abs int sqrt rand srand sleep time
    binmode fileno eof seek tell sysread syswrite sysseek getc select
    opendir readdir closedir rewinddir mkdir rmdir unlink rename
    symlink link readlink stat lstat chmod chown utime glob fcntl flock truncate
    fork wait waitpid exec system kill exit alarm getppid umask chdir chroot times
    pack unpack vec sin cos atan2 exp log hex oct quotemeta pos crypt fc
    socket socketpair bind connect listen accept shutdown send recv
    getsockname getpeername getsockopt setsockopt
    caller localtime gmtime tie untie tied goto prototype lock undef
);

sub is_builtin ($name) { $BUILTIN{$name} ? 1 : 0 }

# Security "sinks" -- calls where a tainted (e.g. request-derived) value is dangerous.
# Command execution is a bareword call (system "...$x..."); SQL execution is a DBI-style
# method call ($dbh->do("...$x...")). Heuristic by name: a placeholdered ->execute is
# safe, so a reached sink is a site to VERIFY, not a confirmed bug.
my %SINK_CMD = map { $_ => 1 } qw(system exec syscall);
my %SINK_SQL = map { $_ => 1 } qw(do execute selectall_arrayref selectall_hashref
                                  selectrow_array selectrow_arrayref selectrow_hashref selectcol_arrayref);
sub sink_type ($name, $is_method) {
    return 'command' if !$is_method && $SINK_CMD{$name};
    return 'sql'     if  $is_method && $SINK_SQL{$name};
    return undef;
}

# UNIVERSAL methods every object answers. An unresolved $obj->can/isa/... is core
# noise, not a project method gap -- the resolver consumes it like a builtin.
my %UNIVERSAL = map { $_ => 1 } qw(can isa DOES VERSION);
sub is_universal ($name) { $UNIVERSAL{$name} ? 1 : 0 }

# A node is "public" API if it's exported or not explicitly private (_-prefixed subs
# get visibility 'private'). The single source of truth for diff/review/api surfaces.
sub is_public ($node) { $node->{is_exported} || (($node->{visibility} // '') ne 'private') }

# Well-known CPAN exports + qualified-call prefixes that are almost never project
# symbols -- so a bareword/qualified call that doesn't resolve to a project node
# is recognized as external (Test::More/Test2, Carp, List/Scalar/Ref::Util, ...) rather
# than left as a phantom "unresolved" that inflates the count. The resolver only
# consults this AFTER project resolution fails, and skips bare names the project
# actually defines, so a project sub never gets mistaken for a CPAN export.
my %EXTERNAL = map { $_ => 1 } qw(
    ok is isnt like unlike cmp_ok is_deeply pass fail diag note plan done_testing
    subtest skip todo todo_skip BAIL_OUT use_ok require_ok can_ok isa_ok new_ok ref_ok
    exception dies_ok lives_ok throws_ok lives_and warning warnings_are
    cmp_deeply cmp_bag bag set superhashof
    croak confess carp cluck
    first sum sum0 max min maxstr minstr reduce reductions any all none notall
    uniq uniqint uniqnum uniqstr pairs pairmap pairgrep pairkeys pairvalues
    shuffle product head tail
    blessed reftype weaken unweaken isweak looks_like_number dualvar readonly openhandle
    encode_json decode_json to_json from_json
    D U T F E DF DNE hash array item field end etc in_set not_in_set match mismatch
    validator object meta check_isa number string bool exact_ref within seq subset mock
    is_plain_arrayref is_plain_hashref is_arrayref is_hashref is_coderef is_ref is_blessed_ref
    is_plain_coderef is_regexpref is_scalarref is_globref is_plain_scalarref is_refref
    strftime floor ceil fmod pow tv_interval gettimeofday usleep nanosleep encode_utf8 decode_utf8
);
# qualified calls whose top-level package is one of these are external too
my @EXTERNAL_PREFIX = qw(AE AnyEvent EV Coro POSIX Carp Scalar::Util List::Util Ref::Util
    Time::HiRes JSON JSON::XS Cpanel::JSON::XS Data::Dumper Encode IO::Socket Net::SSLeay Test2);
my $EXTERNAL_PREFIX_RX = do { my $a = join '|', map { quotemeta } @EXTERNAL_PREFIX; qr/\A(?:$a)::/ };
sub is_external ($name) { ($EXTERNAL{$name} || $name =~ $EXTERNAL_PREFIX_RX) ? 1 : 0 }

sub package_of ($qname) {
    return 'main' unless $qname =~ /::/;
    (my $p = $qname) =~ s/::[^:]+\z//;
    return $p;
}

sub qualify ($pkg, $name) { return "$pkg\::$name" }

sub node_id ($f) {
    # Stable across edits: line numbers are NOT part of the id, so re-indexing a
    # file (which shifts lines) keeps ids constant and inbound edges valid.
    return sha1_hex(join "\0",
        $f->{kind} // '', $f->{qualified_name} // $f->{name} // '',
        $f->{file_path} // '');
}
1;

__END__

=head1 NAME

App::PerlGraph::Model - node identity and name helpers

=head1 DESCRIPTION

Pure helpers shared across the graph: C<node_id>, C<qualify>, C<package_of>,
C<is_builtin>, C<is_external>, C<is_universal>, C<is_public>, C<sink_type>, and the
C<NODE_KINDS>/C<EDGE_KINDS>/C<PROVENANCE> vocabularies.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
