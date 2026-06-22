package App::PerlGraph::Installer;
use v5.36;
our $VERSION = q{0.029};
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
sub _skill_dir     ($self) { path($self->home)->child('.claude/skills/perl-codegraph') }

# A Claude Code skill, deployed on install, so an agent automatically prefers the
# pcg graph (and uses it wisely) whenever it works on a Perl codebase. The
# description is what makes it auto-trigger on Perl structural tasks.
use constant SKILL => <<'MD';
---
name: perl-codegraph
description: >-
  Use when exploring, understanding, navigating, reviewing, or refactoring a Perl
  codebase (.pm / .pl / .t files) -- query the pcg code knowledge graph via its
  pcg_* MCP tools instead of grep/Read for anything structural. Triggers on
  questions like "who calls X", "what does Y call", "blast radius of changing Z",
  "where is this defined", "how does A reach B", "which tests cover this",
  "find dead code", "module dependencies / cycles".
---

# pcg -- Perl code knowledge graph

On a Perl codebase, prefer the `pcg_*` MCP tools over grep/Read for structure: they
return *resolved* relationships (callers, callees, inheritance, imports, Mojolicious
routes/helpers, XSUBs), not text matches.

## Lifecycle
- If a read tool reports "no index", call **pcg_index** once (no restart needed).
- After you edit Perl files, call **pcg_sync** so queries reflect the change.
- **pcg_status** reports graph health and how much is resolved.

## Pick the right tool
- Orient on an area -> **pcg_explore** `<symbol-or-term>` (symbols + source + immediate
  callers/callees in one call -- the best first stop; beats grep).
- Who calls X / what X calls -> **pcg_callers** / **pcg_callees**.
- Blast radius of changing X -> **pcg_impact**.  How A reaches B -> **pcg_path**.
- A module's public surface -> **pcg_api**.  Deps / cycles -> **pcg_deps** / **pcg_cycles**.
- Where's the risk/complexity (fan-in + blast radius / fan-out / cyclomatic complexity / module coupling) -> **pcg_hotspots** (review & refactor triage).
- What's risky to change given git history (churn x fan-in) -> **pcg_risk**.
- What changes together but has no static link (hidden coupling) -> **pcg_cochange**.
- Review a branch/PR in one call (diff + blast radius + tests + breaking) -> **pcg_review** `<ref>`. Just the structural diff -> **pcg_diff**.
- Which tests exercise X -> **pcg_covers**.  Tests impacted by a diff -> **pcg_affected**.
- Dead-code candidates -> **pcg_unused**.  Untested public API -> **pcg_untested**.

## Closing the unresolved frontier (high value)
Opaque `$obj->method` dispatch that static analysis can't tie to a class (local
`my $x = Class->new` receivers already resolve automatically as `[inferred]`) is what
`pcg_status` reports as "unresolved" -- overwhelmingly opaque method dispatch (the
"bareword calls" part is just genuinely-unknown externals; Test::More/Carp/List::Util/etc.
are already filtered out). To resolve the rest:
1. **pcg_unresolved** lists the opaque `$obj->method` calls that match real candidate
   methods in the graph, each with its candidates. Even better, **pcg_unresolved with
   `by_receiver: true`** groups by receiver and intersects the classes defining *every*
   method called on it -- a unique intersection is a near-certain type pcg hands you, so
   you confirm instead of deriving.
2. Read where the receiver was assigned (or take the by_receiver suggestion), and **pcg_resolve** it.
   Prefer the **`{ caller, receiver, class }`** form: it types a receiver *once* and
   resolves *every* call on it at that site (so one entry handles `$db->query`,
   `$db->fetch`, ...), far cheaper than per-call `{ caller, method, receiver, target }`.
   Edges are recorded as `[llm]` (a clearly-marked inference), never fabricate a method
   the class lacks, and persist across reindex.

For dependency calls, `pcg index --deps` first indexes used CPAN modules' APIs (so many
`$obj->method` calls into them resolve statically). For loadable, *trusted* code,
`pcg index --runtime` resolves dispatch via the real runtime optree/MRO (authoritative
`[optree]`/`[mop]`) instead of inference.

## Trust by provenance
Every relationship is tagged by how it was derived. `[optree]` `[mop]` `[symtab]` `[xs]`
are authoritative; `[static]` `[framework]` are exact static facts; `[inferred]` (local
`my $x = Class->new` type inference) is deterministic but local; `[heuristic]` `[llm]`
are honest guesses (overridable). Never treat a `[heuristic]`/`[llm]` edge as proven.
MD

sub _read_json ($self, $file) {
    my $p = path($file);
    return {} unless $p->exists;
    my $txt = $p->slurp_raw;
    return {} unless length $txt;
    # a clear, actionable error beats a raw JSON exception -- and we must NOT silently
    # treat a malformed config as {} (that would clobber the user's file on write-back).
    my $data = eval { $self->_json->decode($txt) };
    die "pcg: cannot parse $file as JSON (fix or remove it, then retry): $@" if $@;
    return $data;
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

    # deploy the agent skill so Claude Code auto-uses the graph on Perl codebases
    my $skill = $self->_skill_dir->child('SKILL.md');
    $skill->parent->mkpath;
    $skill->spew_utf8(SKILL);
    return $self;
}

sub uninstall ($self) {
    $self->_skill_dir->remove_tree({ safe => 1 }) if $self->_skill_dir->exists;
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

Edits F<~/.claude.json> and F<~/.claude/settings.json> to (de)register pcg as an MCP server
(preserving existing config), and deploys a C<perl-codegraph> Claude Code skill to
F<~/.claude/skills/> so an agent automatically uses the graph on Perl codebases.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
