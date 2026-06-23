# App::PerlGraph (`pcg`)

Perl-native code knowledge graph for AI coding agents. Indexes a Perl codebase
into a SQLite graph — packages, classes, subs, methods, fields, constants, calls, imports, inheritance — and answers
structural questions ("who calls this?", "blast radius of changing X?"). It's the
Perl answer to [`codegraph`](https://github.com/colbymchenry/codegraph), which
supports 20+ languages but not Perl.

**Status:** engine + CLI + MCP server + Claude Code install + opt-in runtime
enrichers (`Devel::Symdump` / `B::` / Moo·Moose MOP) + framework-route
(Dancer2/Mojo/Catalyst) and XS/C-bridge resolvers.

## How it works

```
tree-sitter-perl (via Text::Treesitter) → normalized tree → extractor
  → SQLite graph (nodes / edges / files + FTS5)
  → resolver (::-scoping, Exporter, static @ISA / parent / base / Moo·Moose extends / Mojo::Base / with / native class + Object::Pad role :isa·:does)
  → query / format / CLI
```

Every edge records a `provenance` (`static`/`heuristic` here; `inferred`/`llm`/`symtab`/`optree`/`mop`/
`xs`/`framework` as later layers add them) so partial coverage stays honest.

## Install (dev)

```bash
cpanm --installdeps .
./tools/build-grammar.sh          # clones the release branch + compiles tree-sitter-perl.so
perl Makefile.PL && make
```

Requires a C compiler and a reasonably current system `libtree-sitter`
(**>= 0.25** — the tree-sitter-perl grammar uses language version 15). Note that
distro packages are often too old: Ubuntu's `libtree-sitter-dev` is 0.20.8 and
will fail to load the grammar. On a recent macOS, `brew install tree-sitter`
works; elsewhere, build a release from source:

```bash
git clone --depth 1 --branch v0.26.8 https://github.com/tree-sitter/tree-sitter
make -C tree-sitter && sudo make -C tree-sitter install && sudo ldconfig
```

The grammar is built into `~/.cache/pcg/tree-sitter-perl` (override with
`PCG_TS_PARSER_DIR`).

## Use

```bash
pcg index .                       # build .pcg/graph.db (parallel parse; --jobs N to set workers)
pcg index --deps                  # also index used CPAN modules' public API (@INC, no code run) so calls into deps resolve
                                  #   --max-file-size 1M skips huge generated-data files (e.g. Module::CoreList)
pcg index --embed                 # also compute semantic-search embeddings (optional LOCAL provider; see below)
pcg sync                          # incremental update (re-resolves changed files + dependents)
pcg watch                         # keep it fresh: re-index on every file change (inotify/poll)
                                  #   --json emits a {added,changed,deleted,affected_tests} event per
                                  #   change, for an agent to monitor the stream and react
pcg overview                      # codebase map: scale, frameworks, entry points, central symbols,
                                  #   namespaces, most-subclassed (the lay of the land -- a good first stop)
pcg metrics                       # code-health snapshot: scale, coverage, complexity, clones, cycles + concerns
pcg explore Some::Module          # matching symbols with source + POD docs + relationships (one call)
pcg node    Some::Module::thing   # a symbol's source + callers/callees
pcg explain Some::Module::thing   # full dossier: source + callers/callees + blast radius + covering tests
pcg context Some::Module::thing   # paste-ready working set: focus source + every project callee's source + tests
                                  #   (--budget N caps it; a "quoted phrase" is resolved as a query)
pcg callers Some::Module::thing
pcg callees Some::Module::thing
pcg impact  Some::Module::thing   # blast radius (transitive callers)
pcg path    Foo::a Bar::z         # shortest call path: how Foo::a reaches Bar::z
pcg affected lib/Foo.pm           # files/tests impacted by a change (CI: pcg affected --since main --tests)
pcg unused                        # dead-code candidates: subs nothing references (--all keeps exported/lifecycle subs)
pcg untested                      # public API symbols no test statically reaches
pcg doccheck                      # stale POD: documents a method (name(...) / $obj->name) that no longer exists
pcg scaffold Some::Module::thing  # generate a POD + test skeleton (with TODOs) for a sub, from its signature
pcg dead-exports                  # exported functions/methods no other in-repo pkg calls (retractable API)
pcg deps    Some::Module          # module dependency graph: what it imports / inherits (omit for the whole project)
pcg cycles                        # circular module dependencies
pcg layers                        # architecture stratification: modules by dependency depth + cyclic violations
pcg checkcalls                    # broken method calls: a method the receiver's known class does NOT define
pcg checkargs                     # wrong-arity calls: too few / too many args to a sub whose signature fixes its arity
pcg duplication                   # structural code clones (type-1/2): extract-a-shared-helper targets
pcg hotspots                      # fan-in (+ blast radius) / fan-out / complexity / most-coupled-modules triage
pcg risk                          # git churn x fan-in: frequently-changed + widely-depended-upon code
pcg risk --since main             #   ... weighted by churn on the current branch (commits since main)
pcg cochange                      # files that change together (logical coupling, incl. hidden)
pcg owners                        # code ownership x importance: each file's author + bus-factor risks
pcg suggest-reviewers main        # who should review a change: authors of the changed files, ranked
pcg sinks                         # command/SQL sinks (flags dynamically-built args as injection risk) + which endpoints reach them
pcg diff main                     # structural diff vs a git ref: added/removed/changed symbols (+ breaking)
pcg semver v1.4.0                 # recommend a major/minor/patch bump from the diff (CPAN release helper)
pcg changelog v1.4.0              # draft a Changes-style entry from the diff (added/removed/changed + bump)
pcg review main                   # PR review: diff + blast radius + tests + breaking + findings
                                  #   (untested public changes / wide blast radius), in one report
pcg api     Some::Module          # a module's public/exported surface
pcg covers  Some::Module::thing   # which tests exercise a symbol (reverse of affected --tests)
pcg unresolved [--name M] [--limit N] [--by-receiver]   # opaque $obj->method calls with candidates;
                                  #   --by-receiver groups by receiver and suggests its class (the candidate-class intersection)
pcg rename Foo::bar baz [--apply]   # graph-driven rename within a package; reports the dynamic
                                  #   $obj->method sites it can't verify. Dry-run unless --apply
pcg move Foo::bar Other::Pkg [--apply]   # move a sub to another package: relocate source + requalify calls
pcg inline Pkg::helper [--apply]         # inline a simple function at its call sites (do{} block) + remove def
pcg dedupe Pkg::canonical [--apply]      # de-dup a clone group: rewrite each EXACT duplicate to { goto &Pkg::canonical }
pcg rm Pkg::dead [--apply]               # safely delete a dead sub + cascade now-dead private helpers (refuses if used/exported)
pcg export --format mermaid --around Some::Module::run   # render the (sub)graph for docs/review (dot|mermaid|json|html -- html is a self-contained interactive viz)
pcg search  thing
pcg search --semantic "where do we validate user input"   # rank by meaning (needs `index --embed`)
pcg status                        # setup health (parser/grammar/libtree-sitter) + graph counts
pcg --version
```

Example:

```
$ pcg callees Foo::run
## Callees of Foo::run

- `Foo::Bar::help` (function) -- lib/Foo/Bar.pm:2
- `Foo::shout` (function) -- lib/Foo.pm:4
```

## Use with AI agents (MCP)

`pcg` ships an MCP server so agents (Claude Code, etc.) query the graph directly
instead of grepping:

```bash
pcg index .          # build the graph first
pcg install          # register the MCP server with Claude Code, then restart it
```

`pcg install` adds a stdio entry to `~/.claude.json`, allow-lists the tools in
`~/.claude/settings.json`, and deploys a `perl-codegraph` skill to
`~/.claude/skills/` so an agent automatically prefers the graph (and uses it
wisely) on any Perl codebase. All edits preserve existing config; `pcg uninstall`
reverses them:

```json
"mcpServers": { "pcg": { "type": "stdio", "command": "pcg", "args": ["serve", "--mcp"] } }
```

Tools exposed (47): the read tools `pcg_overview`, `pcg_metrics`, `pcg_explore`, `pcg_explain`, `pcg_context`, `pcg_node`, `pcg_search`,
`pcg_callers`, `pcg_callees`, `pcg_impact`, `pcg_path`, `pcg_unused`,
`pcg_affected`, `pcg_deps`, `pcg_cycles`, `pcg_layers`, `pcg_checkcalls`, `pcg_checkargs`, `pcg_duplication`, `pcg_prereqs`, `pcg_hotspots`, `pcg_risk`, `pcg_owners`, `pcg_suggest_reviewers`, `pcg_cochange`, `pcg_semver`, `pcg_changelog`, `pcg_diff`, `pcg_review`, `pcg_api`, `pcg_covers`, `pcg_untested`, `pcg_undocumented`, `pcg_doccheck`, `pcg_scaffold`, `pcg_dead_exports`, `pcg_sinks`,
`pcg_unresolved`, `pcg_resolve`, the five write tools `pcg_rename` (rename), `pcg_move` (cross-package move), `pcg_inline` (inline a function), `pcg_dedupe` (merge a clone group) and `pcg_rm` (safe delete),
plus lifecycle tools `pcg_index` (with
`runtime`, `deps` and `embed` options), `pcg_sync` and `pcg_status`. The
agent can therefore build and refresh the graph
itself: on first use it calls `pcg_index`, and after editing code it calls
`pcg_sync` — no separate `pcg index` run and no server restart. Run the server
by hand with `pcg serve --mcp [--watch] [path]` (`--watch` also lazily re-indexes
before tool calls) (newline-delimited JSON-RPC 2.0 over stdio, protocol
`2024-11-05`).

## Editor integration (LSP)

`pcg lsp [path]` runs a small Language Server over the graph (stdio, LSP base
protocol). It answers **go-to-definition**, **find-references**, **hover**,
**document symbols** and **workspace symbol** search from the *resolved* call
graph — so go-to-def follows the
`$obj->method` dispatch the resolver (and `--runtime`) tied down, which a
tags/parser-based Perl LSP can't. It is read-only and stateless: the graph is the
source of truth, so keep it fresh with `pcg watch` (or `pcg sync`) alongside the
editor. Point your editor's LSP client at `pcg lsp` for the project root. (New;
validated at the protocol level — editor-client testing is ongoing.)

## Semantic search (`--embed`, optional)

`pcg search --semantic "<intent>"` ranks symbols by *meaning* rather than keyword —
useful when you know what code should *do* but not what it's *called*
("where do we validate user input", "retry logic"). It is opt-in and runs entirely
**locally** — no cloud dependency. Enable it in two steps:

1. Provide a local embedding backend, either:
   - `PCG_EMBED_CMD` — any command that reads one text per line on stdin and prints one
     JSON array of floats per line (a llama.cpp / sentence-transformers wrapper, etc.), or
   - an [Ollama](https://ollama.com)-compatible endpoint (the default): `PCG_EMBED_URL`
     (default `http://localhost:11434`), `PCG_EMBED_MODEL` (default `nomic-embed-text`).
2. `pcg index --embed` to embed every symbol (`pcg_index embed:true` from an agent).

Without a provider, `--embed` is skipped with a note and `--semantic` falls back to
guidance — keyword `pcg search` always works. Embeddings live in the graph DB
(`embeddings` table) and are pruned for deleted symbols on the next `--embed`.

## Runtime enrichment (`--runtime`)

Static analysis can't see Perl's dynamism — `$self->method` dispatch, runtime
`@ISA`, Moose/Moo roles & attributes, or generated subs. `pcg index --runtime`
adds an opt-in pass that **loads the code** in a forked, timeout-guarded child
and introspects it, merging results into the graph with a non-`static`
provenance:

| Enricher | Adds | provenance |
|---|---|---|
| symbol table (`Devel::Symdump`) | nodes for runtime-generated subs | `symtab` |
| `@ISA` / `mro` | accurate `extends` edges | `symtab` |
| optree (`B::`) | `calls` edges — function calls resolved exactly; `$self->m` resolved along the real MRO | `optree` |
| MOP (Moo/Moose) | roles → `implements`, attributes → `field` | `mop` |

> **Safety:** `--runtime` executes the target code (`BEGIN`/`use` run). It runs in
> a forked child with an alarm timeout and is fail-soft (any error keeps the
> static graph) — but only use it on **code you trust**.

Provenance shows in query output (`-- lib/Animal.pm:5 [optree]`) and in
`pcg status`, so you always know how a relationship was derived.

## Resolving opaque dispatch (agent-mediated)

Most "unresolved" relationships are opaque `$obj->method` calls static analysis
can't tie to a class. When you can't (or won't) run the code, the consuming agent
can resolve them — it's already an LLM with full context:

- **`pcg_unresolved`** lists the opaque method calls that *do* match real
  candidate methods in the graph (variable receivers only — a literal
  `Class->method` that didn't resolve is external), each with its candidates and
  how often it's called. With **`by_receiver`** (CLI `--by-receiver`) it instead
  groups by `(caller, receiver)` and intersects the classes defining *every* method
  called on that receiver — a unique intersection is a near-certain type, so pcg does
  the candidate-narrowing and the agent just confirms it.
- The agent infers each receiver's class (reading the code as needed) and calls
  **`pcg_resolve`**. Prefer the **`{ caller, receiver, class }`** form: it types a
  receiver *once* and resolves *every* method call on it at that site against the
  class's MRO — so one entry handles `$db->query`, `$db->fetch`, … (far cheaper than
  the per-call `{ caller, method, receiver, target }` form, which is still accepted).
  pcg validates the class/target is real (hallucinations are rejected), never
  fabricates a method the class lacks, writes the edges with **`llm` provenance** (the
  lowest rank — a later static/runtime resolution always overrides it), and records
  them in a `resolutions` table so they survive reindex.

So the graph stays honest: LLM-inferred edges are marked `[llm]` and never
masquerade as proven. `pcg unresolved` shows the same surface for humans.

## Frameworks & XS

Static resolvers connect indirection that plain parsing misses (provenance
`framework` / `xs`):

- **Web routes** → `route` nodes linked to handlers: Dancer2/Dancer and
  Mojolicious::Lite verb routes (`get '/x' => sub {…}`, with the handler body
  attributed to it), and Catalyst attribute actions (`sub foo :Path :Args(0)`).
- **Mojolicious** → `Mojo::Base` `has` attributes become accessor methods (so
  `$self->attr` resolves, including up the MRO), and `helper name => sub` /
  `$app->helper(...)` registrations become methods that a `$c->name` call
  resolves to.
- **XS/C bridge** → `.xs` files are scanned for XSUBs, emitting `language=xs`
  function nodes so Perl calls into C (`Foo::add(...)`) resolve to the XSUB.

## Scope & limitations (MVP)

- **Static resolution covers idiomatic OO without running code** — bareword
  calls (including symbols imported via `use Mod qw(name)`), `Class->method`,
  `\&name` references, and `$self`/`$class` method calls
  (resolved against the enclosing package, the transitive MRO — inheritance via
  `@ISA`/`parent`/`base`/Moo·Moose `extends`/`Mojo::Base`/native `class :isa`, plus
  composed `with`/`:does` roles) all
  become edges — the `$self`/`$class`/role ones as `heuristic` provenance.
  Attribute accessors resolve too: Moo/Moose `has` and native `field :reader`
  emit accessor methods, so `$self->attr` links statically. Moo/Moose modifiers
  (`before`/`after`/`around`) link as `overrides`.
- **Type inference** — when a receiver's class is known statically, its method
  call resolves against that class's MRO deterministically (provenance
  `inferred`), closing a chunk of opaque `$obj->method` dispatch with no runtime
  and no LLM. Sources: a local constructor (`my $db = Store->new; …; $db->save`),
  a chain through a typed accessor (`has db => (isa => 'Store')` or native
  `field $db :reader :isa(Store)`, so `$self->db->save` resolves), and a
  `Class->new` builder's return type (`sub make_db { Store->new }`, so
  `make_db()->save` and `$self->make_db->save` resolve). Never a method the class
  lacks — recall without false edges.
- **`pcg index --runtime` resolves the rest** — true dynamic dispatch (`B::`
  optree), the real runtime `@ISA`, generated subs (`Devel::Symdump`), and
  Moose/Moo roles & attributes (MOP) — and upgrades `heuristic`/`inferred` edges to
  authoritative `optree`/`mop`. Still partial without it: `AUTOLOAD`,
  string-dispatched methods (`$obj->$name`), and `$obj->method` on receivers
  whose class isn't locally inferable (injected, returned, or from another sub).
- **Incremental `sync`** re-resolves changed files *and their dependents* (the
  files that call/reference them), so renames and removals don't leave stale
  cross-file edges — no full `pcg index` needed for correctness. After a `pcg`
  *upgrade*, the first `index`/`sync` also re-extracts any file extracted by an
  older version (even if unchanged), so extraction improvements take effect at once.

## Tests

```bash
./tools/build-grammar.sh && prove -lr t/
```
