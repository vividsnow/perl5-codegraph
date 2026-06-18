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
  → resolver (::-scoping, Exporter, static @ISA / parent / base / Moo·Moose extends / Mojo::Base / with / native class :isa·:does)
  → query / format / CLI
```

Every edge records a `provenance` (`static` here; `symtab`/`optree`/`mop`/`xs`/
`framework` as later layers add them) so partial coverage stays honest.

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
                                  #   --max-file-size 1M skips huge generated-data files (e.g. Module::CoreList)
pcg sync                          # incremental update (re-resolves changed files + dependents)
pcg watch                         # keep it fresh: re-index on every file change (poll)
pcg explore Some::Module          # matching symbols with source + POD docs + relationships (one call)
pcg node    Some::Module::thing   # a symbol's source + callers/callees
pcg callers Some::Module::thing
pcg callees Some::Module::thing
pcg impact  Some::Module::thing   # blast radius (transitive callers)
pcg path    Foo::a Bar::z         # shortest call path: how Foo::a reaches Bar::z
pcg affected lib/Foo.pm           # files/tests impacted by a change (CI: git diff --name-only | pcg affected --stdin --tests)
pcg unused                        # dead-code candidates: subs nothing references (--all keeps exported/lifecycle subs)
pcg export --format mermaid --around Some::Module::run   # render the (sub)graph for docs/review (dot|mermaid|json)
pcg search  thing
pcg status
```

Example:

```
$ pcg callees Foo::run
## Callees of Foo::run

- `Foo::Bar::help` (function) — lib/Foo/Bar.pm:2
- `Foo::shout` (function) — lib/Foo.pm:4
```

## Use with AI agents (MCP)

`pcg` ships an MCP server so agents (Claude Code, etc.) query the graph directly
instead of grepping:

```bash
pcg index .          # build the graph first
pcg install          # register the MCP server with Claude Code, then restart it
```

`pcg install` adds a stdio entry to `~/.claude.json` and allow-lists the tools in
`~/.claude/settings.json` (both edits preserve any existing config; `pcg
uninstall` reverses them):

```json
"mcpServers": { "pcg": { "type": "stdio", "command": "pcg", "args": ["serve", "--mcp"] } }
```

Tools exposed: `pcg_explore`, `pcg_node`, `pcg_search`, `pcg_callers`,
`pcg_callees`, `pcg_impact`, `pcg_path`, `pcg_unused`, `pcg_affected`. Run the server by hand with `pcg serve --mcp [--watch] [path]`
(`--watch` lazily re-indexes before tool calls so the agent's view stays fresh)
(newline-delimited JSON-RPC 2.0 over stdio, protocol `2024-11-05`).

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

## Frameworks & XS

Two static resolvers connect indirection that plain parsing misses (provenance
`framework` / `xs`):

- **Web routes** → `route` nodes linked to handlers: Dancer2/Dancer and
  Mojolicious::Lite verb routes (`get '/x' => sub {…}`, with the handler body
  attributed to it), and Catalyst attribute actions (`sub foo :Path :Args(0)`).
- **XS/C bridge** → `.xs` files are scanned for XSUBs, emitting `language=xs`
  function nodes so Perl calls into C (`Foo::add(...)`) resolve to the XSUB.

## Scope & limitations (MVP)

- **Static resolution covers idiomatic OO without running code** — bareword
  calls, `Class->method`, `\&name` references, and `$self`/`$class` method calls
  (resolved against the enclosing package, the transitive MRO — inheritance via
  `@ISA`/`parent`/`base`/Moo·Moose `extends`/`Mojo::Base`/native `class :isa`, plus
  composed `with`/`:does` roles) all
  become edges — the `$self`/`$class`/role ones as `heuristic` provenance.
  Moo/Moose modifiers (`before`/`after`/`around`)
  link as `overrides`.
- **`pcg index --runtime` resolves the rest** — true dynamic dispatch (`B::`
  optree), the real runtime `@ISA`, generated subs (`Devel::Symdump`), and
  Moose/Moo roles & attributes (MOP) — and upgrades `heuristic` edges to
  authoritative `optree`/`mop`. Still partial without it: `AUTOLOAD`,
  string-dispatched methods (`$obj->$name`), and `$obj->method` on opaque receivers.
- **Incremental `sync`** re-resolves changed files *and their dependents* (the
  files that call/reference them), so renames and removals don't leave stale
  cross-file edges — no full `pcg index` needed for correctness.

## Tests

```bash
./tools/build-grammar.sh && prove -lr t/
```
