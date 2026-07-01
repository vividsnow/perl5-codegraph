package App::PerlGraph::Embed;
use v5.36;
our $VERSION = q{0.075};
use Cpanel::JSON::XS ();
use Path::Tiny ();

# Optional, LOCAL embedding provider for semantic search -- NO cloud dependency.
# Two interchangeable backends, picked by environment:
#
#   1. PCG_EMBED_CMD -- an arbitrary local command (a llama.cpp / sentence-transformers
#      wrapper, etc.). Each input text is written as one line to a temp file fed on the
#      command's stdin; the command must print one JSON array of floats per line on stdout,
#      in the same order. (This is also what the test suite drives, with a deterministic
#      fake -- so the whole pipeline runs with no network and no model.)
#   2. An Ollama-compatible HTTP endpoint (the default when no command is set):
#      PCG_EMBED_URL (default http://localhost:11434), PCG_EMBED_MODEL (default
#      nomic-embed-text). One POST /api/embeddings per text.
#
# available() is conservative -- false unless a provider really looks usable -- so the rest
# of pcg degrades to keyword search instead of erroring when nothing local is installed.

sub _cmd   { length($ENV{PCG_EMBED_CMD}   // '') ? $ENV{PCG_EMBED_CMD}   : undef }
sub _url   {        $ENV{PCG_EMBED_URL}   // 'http://localhost:11434' }
sub _model {        $ENV{PCG_EMBED_MODEL} // 'nomic-embed-text' }

# Cache only a POSITIVE result -- a provider, once seen, stays available -- so a long-lived
# MCP server doesn't re-probe the HTTP endpoint on every call. A negative is NOT cached: a
# provider started after the server (e.g. Ollama launched later) is then still detected.
my $AVAIL;
sub available ($class) {
    return 1 if $AVAIL;
    return $AVAIL = 1 if defined $class->_cmd;                       # a configured command is always usable
    return ($AVAIL = 1) if eval { require HTTP::Tiny; 1 }            # HTTP endpoint: probe, cache only on success
        && HTTP::Tiny->new(timeout => 2)->get($class->_url . '/api/tags')->{success};
    return 0;
}

# \@texts -> \@unit_vectors (L2-normalized, so similarity is a plain dot product), or
# undef if the provider is unreachable / misbehaves (caller falls back to keyword search).
sub embed ($class, $texts) {
    return [] unless @$texts;
    my $raw = defined $class->_cmd ? $class->_embed_cmd($texts) : $class->_embed_http($texts);
    return undef unless $raw && @$raw == @$texts;
    return [ map { _normalize($_) } @$raw ];
}

sub _embed_cmd ($class, $texts) {
    my $cmd = $class->_cmd;
    my $tmp = Path::Tiny->tempfile;   # keep the Path::Tiny tempfile object itself -> File::Temp guard auto-unlinks at scope end
    $tmp->spew_utf8(join "\n", map { (my $t = $_) =~ s/\s+/ /g; $t } @$texts);
    my $out = `$cmd < "$tmp" 2>/dev/null`;      # user's own env command; texts are in the temp file, not the argv
    return undef unless defined $out && length $out;
    my $J = Cpanel::JSON::XS->new;
    my @vecs = map { my $v = eval { $J->decode($_) }; (ref $v eq 'ARRAY') ? $v : () } split /\n/, $out;
    return \@vecs;
}

sub _embed_http ($class, $texts) {
    return undef unless eval { require HTTP::Tiny; 1 };
    my $http = HTTP::Tiny->new(timeout => 30);
    my $J = Cpanel::JSON::XS->new;
    my @vecs;
    for my $t (@$texts) {
        my $r = $http->post($class->_url . '/api/embeddings', {
            headers => { 'Content-Type' => 'application/json' },
            content => $J->encode({ model => $class->_model, prompt => $t }),
        });
        return undef unless $r->{success};
        my $body = eval { $J->decode($r->{content}) } or return undef;
        my $v = $body->{embedding} or return undef;
        push @vecs, $v;
    }
    return \@vecs;
}

# L2-normalize a vector so cosine similarity reduces to a dot product. A zero vector
# (degenerate) is returned unchanged rather than dividing by zero.
sub _normalize ($vec) {
    my $sum = 0; $sum += $_ * $_ for @$vec;
    return $vec unless $sum > 0;
    my $norm = sqrt $sum;
    return [ map { $_ / $norm } @$vec ];
}

# Dot product of two equal-length vectors (both unit -> cosine similarity).
sub dot ($a, $b) {
    my $n = @$a < @$b ? @$a : @$b;
    my $s = 0; $s += $a->[$_] * $b->[$_] for 0 .. $n - 1;
    return $s;
}

1;

__END__

=head1 NAME

App::PerlGraph::Embed - optional local embedding provider for semantic search

=head1 DESCRIPTION

A thin, dependency-light abstraction over a B<local> text-embedding backend, used by
C<pcg index --embed> and C<pcg search --semantic>. Supports an arbitrary local command
(C<PCG_EMBED_CMD>) or an Ollama-compatible HTTP endpoint, and reports C<available> so the
rest of C<pcg> degrades to keyword search when no local embedder is installed. There is no
cloud dependency.

Internal to L<App::PerlGraph>; see L<App::PerlGraph> and the C<pcg> command.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
