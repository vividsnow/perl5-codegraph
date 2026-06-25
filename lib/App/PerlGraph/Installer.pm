package App::PerlGraph::Installer;
use v5.36;
our $VERSION = q{0.065};
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
- Land in an unfamiliar repo -> **pcg_overview** (scale, frameworks, entry-point scripts,
  the most central symbols, top namespaces, most-subclassed classes -- the lay of the land
  in one call).
- A code-health snapshot for triage / a release gate -- NOT for orienting (use pcg_overview for that):
  resolution %, test & doc coverage, complexity, dead code, clones, cycles + a concerns summary -> **pcg_metrics**.
- Orient on a specific area -> **pcg_explore** `<symbol-or-term>` (symbols + source + immediate
  callers/callees in one call -- the best first stop; beats grep).
- Everything about ONE symbol in one call (definition + source + callers/callees + transitive
  blast radius + covering tests) -> **pcg_explain** `<symbol>` (saves separate node/impact/covers calls).
- A paste-ready WORKING SET before editing a symbol (its source + the source of every project
  callee it depends on + covering tests, budget-capped) -> **pcg_context** `<symbol>` (a non-symbol
  arg is treated as a query). Gather everything to change some code in one call, not a flurry of reads.
- Find code by MEANING, not name ("where do we validate user input") -> **pcg_search** `semantic:true`
  (needs `pcg_index embed:true` + a local embedding provider; if absent it says so -- use keyword search).
- Just one symbol's definition + source (lighter than explain) -> **pcg_node**.
- Who calls X / what X calls -> **pcg_callers** / **pcg_callees**.
- Blast radius of changing X -> **pcg_impact**.  How A reaches B -> **pcg_path**.
- A module's public surface -> **pcg_api**.  Deps / cycles -> **pcg_deps** / **pcg_cycles**.
- Architecture layers (modules stratified by dependency depth; cyclic deps flagged) -> **pcg_layers**.
- CPAN dependency hygiene (declared prereqs vs actually-used modules: missing / unused) -> **pcg_prereqs**.
- Where's the risk/complexity (fan-in + blast radius / fan-out / cyclomatic complexity / module coupling) -> **pcg_hotspots** (review & refactor triage).
- Copy-pasted / structurally duplicated subs (DRY / extract-a-shared-helper targets) -> **pcg_duplication**.
- Named refactoring smells (feature-envy -> move-method, god-class -> split, long-parameter-list -> parameter object),
  the actionable cousins of pcg_hotspots -> **pcg_smells** (heuristic; from resolved call edges + signatures).
- What's risky to change given git history (churn x fan-in) -> **pcg_risk**.
- What changes together but has no static link (hidden coupling) -> **pcg_cochange**.
- Code ownership x importance (each file's primary author + bus-factor risks) -> **pcg_owners**.
- Who should review a change (authors of the changed files, ranked by how much of that code they wrote) -> **pcg_suggest_reviewers** `<ref>`.
- Review a branch/PR in one call (diff + blast radius + tests + breaking + findings) -> **pcg_review** `<ref>`. Just the structural diff -> **pcg_diff**.
- A SCORED PR-health gate for CI (review + a lint of the changed files for call bugs, folded into a 0-100 score
  + PASS/REVIEW/BLOCK verdict, concerns worst-first) -> **pcg_pr** `<ref>` (heuristic gate, not a human-review substitute).
- Recommend a semver bump (major/minor/patch) for a release from the structural diff -> **pcg_semver** `<ref>` (breaking public API->major, new public API->minor, internal->patch).
- Draft a Changes / release-notes entry from the structural diff (added / removed / changed, grouped, with the bump) -> **pcg_changelog** `<ref>` (a ready-to-edit scaffold; turn into prose before release).
- Security attack surface (command/SQL execution sites + which web endpoints reach them) -> **pcg_sinks** (flags sinks whose argument is dynamically built -- interpolated/concatenated -- as the injection-shaped sites; constant/placeholdered ones are safe).
- Source -> sink TAINT PATHS (a user-input source -- endpoint / request accessor -- whose call graph reaches a dynamic
  command/SQL sink, with the path shown) -> **pcg_taint** (reachability to VERIFY, not value-flow; `[local]` same-sub hits are strongest).
- Which tests exercise X -> **pcg_covers**.  Tests impacted by a diff -> **pcg_affected**.
- Broken method calls -- a static BUG FINDER: a `$obj->method` the receiver's KNOWN in-repo class doesn't
  define (a typo or a call into renamed/removed API) -> **pcg_checkcalls** (heuristic; `pcg_index runtime:true` sharpens it).
- Wrong-arity calls -- the sibling BUG FINDER: a call passing too few / too many args to a sub whose
  signature fixes its arity (a `->method` invocant is counted; splat args skipped) -> **pcg_checkargs** (heuristic).
- Dead-code candidates -> **pcg_unused**.  Untested public API -> **pcg_untested**.
- Undocumented public API (no POD) -> **pcg_undocumented**.
- Stale POD -- a `=head2 name(...)` / `=item $obj->name` entry documenting a method that no longer exists
  in the package or its @ISA (doc drift after a rename/removal) -> **pcg_doccheck** (heuristic).
- A POD + test SKELETON (with TODOs) for a sub, from its signature -- the actionable starting point for an
  untested / undocumented sub -> **pcg_scaffold** `<symbol>` (read-only: emits text to adapt, writes nothing).
- Exported functions/methods no OTHER in-repo package calls (retractable public API) -> **pcg_dead_exports**.
- The whole cleanup surface in ONE call -- removable dead code (-> pcg_rm), retractable exports, and clone groups
  (-> pcg_dedupe), each item paired with its fix command -> **pcg_tidy** (composes unused + dead_exports + duplication; a survey, changes nothing).
- Rename a function/method to a new name WITHIN ITS OWN PACKAGE across the codebase (the first of six WRITE
  tools; for a cross-package move use pcg_move; edits only the call sites it can tie to the symbol, reports the
  dynamic ones) -> **pcg_rename** (dry-run unless apply:true; call pcg_sync after).
- Move a function to another existing package (relocate its source + requalify call sites to NewPkg::sub) -> **pcg_move** (dry-run unless apply:true; call pcg_sync after).
- Inline a simple function at its call sites (a do{} block) + remove the definition, the inverse of extract -> **pcg_inline** (dry-run unless apply:true; refuses unsafe bodies; call pcg_sync after).
- De-duplicate a clone group (from pcg_duplication): keep one canonical function, rewrite each EXACT type-1 duplicate
  to `{ goto &Canonical }`, the inverse of copy-paste -> **pcg_dedupe** (dry-run unless apply:true; type-2/methods reported, not touched; call pcg_sync after).
- Add or remove a plain function's PARAMETER and propagate it to every resolved call site (the actionable fix for a
  parameter change pcg_checkargs would flag everywhere; function-only, indeterminate/method sites reported) ->
  **pcg_change_signature** `--add '$p'` / `--remove N` (dry-run unless apply:true; call pcg_sync after).
- Safely DELETE a dead sub + cascade-remove the now-dead private helpers it solely used (the actionable follow-up to
  pcg_unused; refuses if still called or exported) -> **pcg_rm** (dry-run unless apply:true; call pcg_sync after).

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
