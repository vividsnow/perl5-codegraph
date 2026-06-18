package App::PerlGraph::Installer;
use v5.36;
our $VERSION = q{0.002};
use Moo;
use Cpanel::JSON::XS ();
use Path::Tiny qw(path);
use App::PerlGraph::MCP ();

# Registers (or removes) the pcg MCP server with Claude Code by editing
# ~/.claude.json (mcpServers) and ~/.claude/settings.json (permissions.allow).
# Idempotent; preserves all unrelated keys/servers/permissions.

has home    => (is => 'ro', default => sub { $ENV{HOME} });
has command => (is => 'ro', default => 'pcg');
has server  => (is => 'ro', default => 'pcg');
has _json   => (is => 'lazy');
sub _build__json ($self) { Cpanel::JSON::XS->new->utf8->pretty->canonical }

sub _claude_json   ($self) { path($self->home)->child('.claude.json')->stringify }
sub _settings_json ($self) { path($self->home)->child('.claude/settings.json')->stringify }

sub _read_json ($self, $file) {
    my $p = path($file);
    return {} unless $p->exists;
    my $txt = $p->slurp_raw;
    return length $txt ? $self->_json->decode($txt) : {};
}

sub _write_json ($self, $file, $data) {
    my $p = path($file);
    $p->parent->mkpath;
    # If the config is a symlink (common in dotfiles setups), write through to the
    # real file instead of replacing the link with a regular file (spew is atomic
    # rename, which would otherwise sever the symlink).
    $p = path($p->realpath) if -l $p && -e $p;
    $p->spew_raw($self->_json->encode($data));
}

sub _perm ($self, $tool) { return 'mcp__' . $self->server . '__' . $tool }

sub install ($self) {
    my $cfg = $self->_read_json($self->_claude_json);
    $cfg->{mcpServers} //= {};
    $cfg->{mcpServers}{ $self->server } = {
        type => 'stdio', command => $self->command, args => ['serve', '--mcp'],
    };
    $self->_write_json($self->_claude_json, $cfg);

    my $set = $self->_read_json($self->_settings_json);
    $set->{permissions} //= {};
    $set->{permissions}{allow} //= [];
    my %have = map { $_ => 1 } @{ $set->{permissions}{allow} };
    for my $t (App::PerlGraph::MCP->tool_names) {
        my $perm = $self->_perm($t);
        push @{ $set->{permissions}{allow} }, $perm unless $have{$perm}++;
    }
    $self->_write_json($self->_settings_json, $set);
    return $self;
}

sub uninstall ($self) {
    if (path($self->_claude_json)->exists) {        # don't materialize config we never wrote
        my $cfg = $self->_read_json($self->_claude_json);
        delete $cfg->{mcpServers}{ $self->server } if $cfg->{mcpServers};
        $self->_write_json($self->_claude_json, $cfg);
    }
    if (path($self->_settings_json)->exists) {
        my $set = $self->_read_json($self->_settings_json);
        if ($set->{permissions} && $set->{permissions}{allow}) {
            my $prefix = 'mcp__' . $self->server . '__';
            $set->{permissions}{allow} =
                [ grep { index($_, $prefix) != 0 } @{ $set->{permissions}{allow} } ];
            $self->_write_json($self->_settings_json, $set);
        }
    }
    return $self;
}

1;

__END__

=head1 NAME

App::PerlGraph::Installer - register the pcg MCP server with Claude Code

=head1 DESCRIPTION

Edits F<~/.claude.json> and F<settings.json> to (de)register pcg as an MCP server, preserving existing config.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
