package App::PerlGraph::MCP;
use v5.36;
our $VERSION = q{0.072};
use Moo;
use Cpanel::JSON::XS ();
use App::PerlGraph ();
use App::PerlGraph::Format;
use App::PerlGraph::Query ();
use App::PerlGraph::Indexer ();

# A minimal MCP server: newline-delimited JSON-RPC 2.0 over stdio, wrapping the
# Query engine plus index/sync lifecycle tools. `dispatch` is a pure
# request->response function (so it is unit-testable); `run` is the stdio loop.

has indexer     => (is => 'ro');                          # App::PerlGraph::Indexer over the shared store
has query       => (is => 'lazy');                        # read view over indexer's store (built on demand)
has base        => (is => 'ro', default => '.');         # project root, for reading source
has server_name => (is => 'ro', default => 'pcg');
has watch       => (is => 'ro', default => 0);           # lazily re-sync before tool calls
sub _build_query ($self) {
    $self->indexer ? App::PerlGraph::Query->new(store => $self->indexer->store) : undef;
}
has in          => (is => 'ro', default => sub { \*STDIN });
has out         => (is => 'ro', default => sub { \*STDOUT });
has _json       => (is => 'lazy');
sub _build__json ($self) { Cpanel::JSON::XS->new->utf8->canonical }

use constant PROTOCOL_VERSION => '2024-11-05';
use constant INSTRUCTIONS => <<'MD';
`pcg` is a Perl code knowledge graph: it parses the codebase into a graph of packages, subs, calls, imports and inheritance, and answers STRUCTURAL questions with *resolved* relationships (callers, callees, @ISA, imports, Mojolicious/Dancer/Catalyst routes, XSUBs) -- not text matches. Prefer it over grep/Read for anything structural. Every relationship is tagged by provenance: `[optree]` `[mop]` `[symtab]` `[xs]` are authoritative; `[static]` `[framework]` are exact static facts; `[inferred]` is deterministic but local; `[heuristic]` `[llm]` are honest guesses -- never treat the last two as proven.

ORIENT in an unfamiliar repo: pcg_overview (the map -- scale, frameworks, entry points, most-central symbols; the best FIRST call); pcg_metrics (a one-call code-health snapshot -- resolution %, test/doc coverage, complexity, dead code, clones, cycles + concerns; for triage / a release gate, NOT an orientation map -- use pcg_overview to get oriented); pcg_explore <term> (matching symbols + source + relationships in one call; beats grep); pcg_search <name> (locate a symbol; semantic:true ranks by meaning when embeddings exist).
UNDERSTAND a symbol: pcg_explain (one-call dossier -- source + callers/callees + transitive blast radius + covering tests); pcg_context (a paste-ready EDITING set -- the symbol + the full source of every project callee it depends on + tests, budget-capped; a non-symbol arg becomes a search). Finer-grained: pcg_node (def + source); pcg_callers / pcg_callees; pcg_impact (transitive callers = blast radius); pcg_path A B (shortest call chain).
ARCHITECTURE: pcg_deps (import/inheritance graph); pcg_cycles (circular deps); pcg_layers (modules stratified by dependency depth; cycles = violations); pcg_hotspots (fan-in / fan-out / complexity / coupling leaders); pcg_smells (NAMED refactoring smells: feature-envy / god-class / long-parameter-list, each with its refactoring); pcg_duplication (structural code clones -- DRY / extract-a-helper targets).
HISTORY (needs a git work tree): pcg_risk (churn x fan-in = what's risky to change); pcg_cochange (files that change together = hidden coupling); pcg_owners (per-file author x importance = bus-factor risk); pcg_suggest_reviewers <ref> (who should review a change -- authors of the changed files ranked by how much of that code they wrote).
QUALITY & RELEASE: pcg_checkcalls (broken method calls -- a static BUG FINDER: a `$obj->method` the receiver's KNOWN in-repo class does not define, i.e. a typo or a call into removed API; heuristic, `index runtime:true` sharpens it); pcg_checkargs (wrong-arity calls -- the sibling bug finder: a call passing too few/many args to a sub whose signature fixes its arity); pcg_unused (dead code); pcg_untested (public API no test reaches); pcg_undocumented (public API without POD); pcg_doccheck (stale POD -- documents a method that no longer exists); pcg_scaffold (a POD + test skeleton for a sub from its signature -- the fix for untested/undocumented); pcg_dead_exports (exported functions no other in-repo package calls -- retractable API); pcg_tidy (one cleanup dashboard -- composes unused + dead_exports + duplication into removable/retractable/clone buckets, each paired with the rm/dedupe command that fixes it; apply:true ORCHESTRATES the safe subset -- dedupe + rm, re-syncing between, dead exports excluded); pcg_sinks (command/SQL injection surface -- `[dynamic]` sites are built from a variable, the ones to verify); pcg_taint (source->sink paths -- a user-input source (endpoint / request accessor / $ENV / @ARGV / STDIN) whose call graph reaches a dynamic sink, with the path shown; a `[value-flow]` hit CONFIRMS the tainted value reaches the sink ARGUMENT in-sub (highest confidence), `[local]`/cross-sub are reachability to verify); pcg_prereqs (declared CPAN deps vs actually-used); pcg_api (a module's public surface); pcg_covers (tests exercising a symbol); pcg_affected (files/tests impacted by a change). Branch/PR review (needs git): pcg_review (diff + blast radius + tests + findings, one call); pcg_pr (review folded into a scored 0-100 PASS/REVIEW/BLOCK gate for CI + a lint of the changed files for call bugs); pcg_diff (just the structural diff); pcg_semver (recommend a major/minor/patch bump); pcg_changelog (draft a Changes entry from the diff).
REFACTOR -- the seven WRITE tools: pcg_rename (rename a sub/method within its package); pcg_move (move a sub to another existing package -- relocate its source + requalify calls to NewPkg::sub); pcg_inline (inline a simple function at its call sites as a do{} block + remove the definition, the inverse of extracting a helper); pcg_extract (the INVERSE of inline: lift a statement range into a new sub, inferring params from outer vars it reads and a return list from locals used after -- conservative, refuses non-local control flow / mutated-outer / @_ / state); pcg_dedupe (de-duplicate a clone group: keep one canonical function, rewrite each EXACT type-1 duplicate to `{ goto &Canonical }`, the inverse of copy-paste); pcg_change_signature (add/remove/reorder a plain function's parameter(s) + propagate to every resolved call site -- the actionable fix for a parameter change pcg_checkargs would flag); pcg_rm (safely delete a DEAD sub + cascade-remove the now-dead private helpers it solely used; refuses if still called or exported -- the actionable follow-up to pcg_unused). All edit ONLY resolver-confirmed sites and report what they can't verify, never editing it silently. Dry-run unless apply:true; call pcg_sync after. (pcg_tidy apply:true orchestrates dedupe + rm for a whole-codebase cleanup.)
LIFECYCLE: if a read tool says "no index", call pcg_index once to build the graph (no restart needed). After you edit Perl files, call pcg_sync so queries reflect them. pcg_status reports graph health + how much is resolved.
UNRESOLVED FRONTIER (high value): most "unresolved" calls are opaque `$obj->method` dispatch static analysis can't tie to a class. pcg_unresolved lists those that DO match real candidate methods; with by_receiver:true it groups by receiver and intersects the classes defining EVERY method called on it -- a unique intersection is a near-certain type. Confirm it (read the code if needed) and pass to pcg_resolve -- prefer the { caller, receiver, class } form, which types a receiver once and resolves all its calls. Those edges are `[llm]` and persist across reindex. (pcg_index deps:true resolves many dependency calls statically first.)
MD

my @TOOLS = (
    { name => 'pcg_overview', handler => 'overview', description => 'A codebase orientation map for first contact with an unfamiliar project, in one call: scale (files/packages/subs/edges + unresolved + provenance mix), web-route count, entry-point scripts (.pl/.psgi), the top namespaces by sub count, the most central symbols (highest fan-in -- change with care), and the most-subclassed classes. The best FIRST call when landing in a repo.',
      inputSchema => { type => 'object', properties => { limit => { type => 'integer', description => 'Top N per list (default 12)' } } } },
    { name => 'pcg_metrics', handler => 'metrics', description => 'A one-call code-health snapshot for triage or a release gate: scale (files/packages/subs/public-API/nodes/edges), static resolution %, test coverage and POD coverage of the public API, count of high-complexity subs, dead code, structural clone groups, and dependency cycles -- plus a flagged "concerns" summary. Composes the individual analyses (unused / untested / undocumented / duplication / cycles) into headline numbers; spans all indexed files (tests included).',
      inputSchema => { type => 'object', properties => {} } },
    { name => 'pcg_search', handler => 'search', description => 'Search Perl symbols by name (keyword). Set semantic=true to rank by MEANING instead -- requires embeddings (pcg_index embed:true) and a local embedding provider; if either is missing it says so and you should use keyword search.',
      inputSchema => { type => 'object', properties => { query => { type => 'string', description => 'Symbol name or term' },
          semantic => { type => 'boolean', description => 'Rank by embedding similarity (meaning), not keyword; default false' } }, required => ['query'] } },
    { name => 'pcg_node', handler => 'node', description => "A symbol's definition(s): verbatim source + immediate callers/callees.",
      inputSchema => { type => 'object', properties => { symbol => { type => 'string', description => 'Bare name or Foo::bar' } }, required => ['symbol'] } },
    { name => 'pcg_explain', handler => 'explain', description => "Everything about a symbol in ONE call: its definition + verbatim source, immediate callers and callees, transitive blast radius (how many callers depend on it), and which tests cover it. Use instead of separate pcg_node + pcg_impact + pcg_covers round-trips.",
      inputSchema => { type => 'object', properties => { symbol => { type => 'string', description => 'Bare name or Foo::bar' } }, required => ['symbol'] } },
    { name => 'pcg_context', handler => 'context', description => "A paste-ready WORKING SET for editing a symbol, in one call: the focus symbol(s) WITH verbatim source, their immediate callers/callees and covering tests, AND the full source of each PROJECT callee (the definitions you must read to change the focus) -- capped at a character budget. If `symbol` matches no symbol it is treated as a natural-language query resolved via semantic (or keyword) search to the focus. Use this to gather everything needed to modify some code without a flurry of follow-up reads.",
      inputSchema => { type => 'object', properties => {
          symbol => { type => 'string', description => 'A symbol (Foo::bar) OR a natural-language query for the focus' },
          budget => { type => 'integer', description => 'Max output characters (default 16000)' },
      }, required => ['symbol'] } },
    { name => 'pcg_explore', handler => 'explore', description => 'Explore an area: matching symbols with their source and immediate relationships, in one call. Prefer this over grep/Read.',
      inputSchema => { type => 'object', properties => { query => { type => 'string', description => 'Symbol name or term to explore' } }, required => ['query'] } },
    { name => 'pcg_callers', handler => 'callers', description => 'All call sites of a function/method.',
      inputSchema => { type => 'object', properties => { symbol => { type => 'string', description => 'Symbol name' } }, required => ['symbol'] } },
    { name => 'pcg_callees', handler => 'callees', description => 'What a function/method calls.',
      inputSchema => { type => 'object', properties => { symbol => { type => 'string', description => 'Symbol name' } }, required => ['symbol'] } },
    { name => 'pcg_impact', handler => 'impact', description => 'Blast radius: transitive callers of a symbol.',
      inputSchema => { type => 'object', properties => { symbol => { type => 'string', description => 'Symbol name' } }, required => ['symbol'] } },
    { name => 'pcg_path', handler => 'path', description => 'Shortest call path from one symbol to another -- how A reaches B (or that it cannot).',
      inputSchema => { type => 'object', properties => { from => { type => 'string', description => 'Start symbol' }, to => { type => 'string', description => 'Target symbol' } }, required => ['from', 'to'] } },
    { name => 'pcg_unused', handler => 'unused', description => 'Dead-code candidates: defined subs nothing in the indexed code references. The output notes its own blind spots (dynamic/string dispatch, cross-distribution callers). Set all=true to also include exported and lifecycle subs. To DELETE a confirmed dead sub (cascading into the private helpers it solely used), use pcg_rm.',
      inputSchema => { type => 'object', properties => { all => { type => 'boolean', description => 'Include exported + lifecycle subs (default false)' } } } },
    { name => 'pcg_affected', handler => 'affected', description => 'Files (or tests, with tests_only) impacted by changing the given files -- the reverse-dependency closure. Pass `files`, and/or `since REF` to take the changed files from `git diff --name-only REF` (CI triage in one call: which tests to run for the diff vs main).',
      inputSchema => { type => 'object', properties => {
          files      => { type => 'array', items => { type => 'string' }, description => 'Changed file paths' },
          tests_only => { type => 'boolean', description => 'Restrict to .t test files (default false)' },
          since      => { type => 'string', description => 'Also include files changed since this git ref (e.g. main)' },
      } } },
    { name => 'pcg_deps', handler => 'deps', description => 'Module dependency graph: which modules each package imports or inherits from. Omit `module` for the whole project, or pass one to focus.',
      inputSchema => { type => 'object', properties => { module => { type => 'string', description => 'Focus on one module (optional)' } } } },
    { name => 'pcg_prereqs', handler => 'prereqs', description => "CPAN dependency hygiene: reconcile the DECLARED prerequisites (from META.json / MYMETA.json / cpanfile / Makefile.PL) against the modules actually use'd / require'd in the indexed code. Flags MISSING deps (used but not declared -- add them) and possibly-UNUSED deps (declared but never used). Core modules and the project's own packages are excluded.",
      inputSchema => { type => 'object', properties => {} } },
    { name => 'pcg_cycles', handler => 'cycles', description => 'Circular module dependencies -- cycles in the import/inheritance graph.',
      inputSchema => { type => 'object', properties => {} } },
    { name => 'pcg_layers', handler => 'layers', description => "Architecture stratification: groups the project's modules into LAYERS by their dependency depth (layer 0 imports/inherits nothing internal; each higher layer builds only on lower ones). Reveals the architectural shape at a glance and flags cyclic dependencies as layering violations. A clean architecture is a DAG.",
      inputSchema => { type => 'object', properties => {} } },
    { name => 'pcg_checkcalls', handler => 'checkcalls', description => "Broken method calls -- a static BUG FINDER: `\$obj->method` sites where the receiver's class is KNOWN (a `\$self`/`\$class` invocant, an inferred `my \$x = Class->new`, or a bareword `Class->method`) and that class plus its FULL in-repo MRO defines no such method -- i.e. typos and calls into renamed/removed API, which Perl doesn't catch until runtime. Conservative: only flags when the class and every ancestor are in-repo and there is no AUTOLOAD (`has`/`field` accessors and Moo `is=>rwp` writers ARE understood), so false positives are rare. Still heuristic -- it can't see runtime-injected methods or `handles` delegation, so `pcg_index runtime:true` sharpens it; verify a finding before deleting the call.",
      inputSchema => { type => 'object', properties => {} } },
    { name => 'pcg_checkargs', handler => 'checkargs', description => "Wrong-arity calls -- a static BUG FINDER (sibling to pcg_checkcalls): calls that pass the wrong NUMBER of arguments to an in-repo sub whose SIGNATURE fixes its arity (`sub f (\$a, \$b)` -> exactly 2; `\$b = 5` default -> 1-2; a slurpy `\@rest`/`\%opt` -> variadic, not checked) -- too few or too many args, which Perl only catches at runtime. Re-parses each calling file to count the positional args at the call site; a `->method` call's implicit invocant is counted toward \@_, and a splat arg (\@list / a list-returning call) makes a site indeterminate and skipped. Only subs with an explicit signature and a determinate call site are checked, so findings are precise but not exhaustive (a `my (\$x) = \@_` sub has no signature to check). Heuristic -- verify before editing.",
      inputSchema => { type => 'object', properties => {} } },
    { name => 'pcg_doccheck', handler => 'doccheck', description => "Stale POD -- doc DRIFT (distinct from pcg_undocumented, which is MISSING docs): call-shaped POD entries (`=head2 name(\$args)` or `=item C<< \$obj->name >>`) documenting a method/function that no longer exists in the documenting file's package(s) or their \@ISA -- a method removed or renamed while its docs were left behind. Package + MRO aware, so an inherited method documented in a subclass is fine; auto-provided names (new/import/...) are skipped. Requires the call form (parens or `->`) so prose section headings ('DESCRIPTION', 'Configuration') never match. Heuristic -- verify.",
      inputSchema => { type => 'object', properties => {} } },
    { name => 'pcg_scaffold', handler => 'scaffold', description => "Generate a POD + test SKELETON (with TODO placeholders) for a sub, derived from its signature -- the actionable starting point for pcg_untested / pcg_undocumented. Returns a `=head2` POD stub (using \$obj->name and dropping the invocant for a method) and a Test2::V0 test stub that loads the package and calls the sub with one placeholder argument per parameter, plus an assertion to fill in. Read-only: it emits text to paste/adapt, it does not write any file.",
      inputSchema => { type => 'object', properties => { symbol => { type => 'string', description => 'The sub to scaffold: Pkg::sub, or a unique bare name' } }, required => ['symbol'] } },
    { name => 'pcg_duplication', handler => 'duplication', description => "Structural code clones: groups of subs whose BODY has an identical CST shape -- same structure with identifiers and literals abstracted away, so type-1 (exact) and type-2 (copy-paste with renamed vars / changed constants) duplicates are caught. Ranked by size x number of copies, so the biggest, most-copied groups -- the best extract-a-shared-helper / DRY targets -- come first. Near-duplicates with small edits (type-3) are NOT grouped, so a reported group is a real structural match, not a guess. To collapse an exact (type-1) duplicate group into a single canonical function, use pcg_dedupe.",
      inputSchema => { type => 'object', properties => {
          limit     => { type => 'integer', description => 'Max clone groups to return (default 20)' },
          min_nodes => { type => 'integer', description => 'Ignore subs whose body has fewer than N AST nodes (default 30)' },
      } } },
    { name => 'pcg_tidy', handler => 'tidy', description => "One-call cleanup dashboard: the codebase's actionable tech-debt, each item paired with the WRITE tool that fixes it -- composes pcg_unused + pcg_dead_exports + pcg_duplication into one curated, de-overlapped survey so an agent gets the whole cleanup surface in a single call. Three disjoint buckets: REMOVABLE (unreferenced, non-exported subs `pcg_rm` deletes outright), RETRACTABLE (exported subs no other in-repo package uses -- stop exporting, then remove; kept separate because pcg_rm refuses exported subs), and CLONES (structural duplicate groups `pcg_dedupe` collapses). A survey by default (names the exact follow-up commands, changes nothing); with apply:true it ORCHESTRATES the safe subset -- dedupe each exact clone + rm each removable sub (with rm's guards + cascade), re-syncing the graph between phases so freed helpers surface. Dead exports are never auto-retracted (public API). Same dead-code/clone caveats as its components (dynamic dispatch and downstream consumers are invisible) -- review the survey before apply:true.",
      inputSchema => { type => 'object', properties => {
          limit     => { type => 'integer', description => 'Max clone groups in the clones bucket (default 20)' },
          min_nodes => { type => 'integer', description => 'Ignore clones whose body has fewer than N AST nodes (default 30)' },
          apply     => { type => 'boolean', description => 'Execute the safe cleanup (dedupe clones + rm removable, re-syncing between); default false = survey only' },
      } } },
    { name => 'pcg_smells', handler => 'smells', description => "Structural refactoring smells -- the NAMED, actionable cousins of pcg_hotspots (which just ranks fan-in/out/complexity). Three classic ones, all from the call graph: FEATURE ENVY (a method making several calls into a SINGLE other class and none into its own -- it lives in the wrong place; refactor: move it there), GOD CLASS (a class with many methods AND many distinct external callers -- doing too much; refactor: split it), and LONG PARAMETER LIST (a sub whose signature declares many params, a \$self/\$class invocant aside; refactor: introduce a parameter object). Each smell names its refactoring. Heuristic: feature-envy counts only RESOLVED call edges (opaque \$obj->method layering doesn't trigger it, but a deliberate facade still can) and long-param is signature-based (old-style my(...)=\@_ subs are invisible) -- verify before refactoring.",
      inputSchema => { type => 'object', properties => {
          limit => { type => 'integer', description => 'Max items per smell category (default 20)' },
      } } },
    { name => 'pcg_sinks', handler => 'sinks', description => 'Security attack surface: command-execution (system/exec/syscall) and SQL-execution (DBI do/execute/select*) call sites, and -- for a web app -- which routes/endpoints can transitively REACH each sink (route handler -> call closure). Each sink is flagged [dynamic] when its command/SQL STRING is built from a variable (interpolated or concatenated) -- the injection-shaped sites to verify; a constant or placeholdered call is parameterized and safe. Still heuristic (no full taint dataflow), so a [dynamic] reached sink is a site to VERIFY for tainted input, not a confirmed bug.',
      inputSchema => { type => 'object', properties => {} } },
    { name => 'pcg_taint', handler => 'taint', description => "Source -> sink TAINT PATHS: trace a call path from a user-input SOURCE to an injectable SINK. Sharper than pcg_sinks (route->sink reachability): the SOURCES are broader -- a web endpoint, any sub that calls a request accessor (param / params / cookie(s) / upload(s) / header(s) / query_parameters / body_parameters / route_parameters), OR any sub that reads external process input (\$ENV / \@ARGV / STDIN -- CLI/env injection) -- and only DYNAMIC sinks (whose command/SQL string is built from a variable -- the injectable ones) are targets, with the actual call PATH shown (source -> ... -> sink). CONFIDENCE tiers: a `[value-flow]` hit applies INTRA-PROCEDURAL value-flow -- the tainted value provably reaches the sink's ARGUMENT inside one sub (the strongest signal); a plain `[local]` hit is co-located (source + sink share the sub, but the value may not reach the arg); a cross-sub path is call-graph REACHABILITY only. So `[value-flow]` is a strong lead and the rest are leads to VERIFY (cross-sub reachability does not prove the tainted value lands in the argument).",
      inputSchema => { type => 'object', properties => {
          limit => { type => 'integer', description => 'Max taint paths to return (default 50)' },
      } } },
    { name => 'pcg_rename', handler => 'rename', description => 'Rename a function/method to a new name within its OWN package, using the graph to locate every reference precisely and the resolver to decide which call sites actually target it (a same-named method on a different class is left alone). Returns the edit plan; set apply=true to write the files. Dynamic `$obj->method` dispatch of the same name that the resolver could not tie to this symbol is reported for manual review, never silently edited. Call pcg_sync after apply. (Sync first if you have unsaved edits.)',
      inputSchema => { type => 'object', properties => {
          old   => { type => 'string',  description => 'Symbol to rename: Pkg::sub, or a unique bare name' },
          new   => { type => 'string',  description => 'The new (short) name' },
          apply => { type => 'boolean', description => 'Write the edits to disk (default false = dry-run plan)' },
      }, required => ['old', 'new'] } },
    { name => 'pcg_move', handler => 'move', description => "Move a function to another (already-existing) package, using the graph: relocate its source from its origin file into the target package's file, and requalify every resolved call site (Foo::bar and bareword bar -> NewPkg::bar). The SECOND write tool. Returns the plan; set apply=true to write. Dynamic `\$obj->method` dispatch and stale `use` imports of the moved sub are reported for manual review, never silently edited. Call pcg_sync after apply.",
      inputSchema => { type => 'object', properties => {
          old   => { type => 'string',  description => 'Symbol to move: Pkg::sub, or a unique bare name' },
          to    => { type => 'string',  description => 'Target package (must already exist in the project), e.g. Other::Pkg' },
          apply => { type => 'boolean', description => 'Write the edits to disk (default false = dry-run plan)' },
      }, required => ['old', 'to'] } },
    { name => 'pcg_inline', handler => 'inline', description => "Inline a simple FUNCTION at its resolved call sites and remove the definition -- the THIRD write tool, the inverse of extracting a helper. Each call is replaced with a `do { my (params) = (args); body }` block (binds the arguments once, preserves precedence, supports multi-statement bodies). Strictly scoped for safety: only a plain function (not a method), with params via a leading `my (...) = \@_` or a simple all-scalar signature, and a body with no return/wantarray/shift/pop/\$_[N]/caller/goto/local. Dynamic `\$obj->method` and unresolved call sites are reported and the definition kept; refuses (with a reason) anything it can't inline safely. Returns the plan; set apply=true to write. Call pcg_sync after.",
      inputSchema => { type => 'object', properties => {
          target => { type => 'string',  description => 'Function to inline: Pkg::sub, or a unique bare name' },
          apply  => { type => 'boolean', description => 'Write the edits to disk (default false = dry-run plan)' },
      }, required => ['target'] } },
    { name => 'pcg_dedupe', handler => 'dedupe', description => "De-duplicate a structural clone group (from pcg_duplication) -- the FOURTH write tool, the inverse of copy-paste. Given a target function in a clone group, keep it as the canonical copy and rewrite every OTHER plain function in the group whose signature+body is BYTE-IDENTICAL into a one-line delegation `sub name { goto &Canonical }`, so the duplicated logic lives in one place while every name stays callable. Conservative by design: only EXACT (type-1) duplicate FUNCTIONS are rewritten; type-2 clones (renamed vars / changed literals) and methods are reported, never edited. It also refuses outright when the canonical carries a prototype or :attribute the goto-stub can't preserve, and skips a cross-package clone whose file does not `use` the canonical's package (the delegation would die). Returns the plan; set apply=true to write. Call pcg_sync after.",
      inputSchema => { type => 'object', properties => {
          target => { type => 'string',  description => 'A function in the clone group to keep as canonical: Pkg::sub, or a unique bare name' },
          apply  => { type => 'boolean', description => 'Write the edits to disk (default false = dry-run plan)' },
      }, required => ['target'] } },
    { name => 'pcg_rm', handler => 'rm', description => "Safely DELETE a dead sub -- the FIFTH write tool. REFUSES if the target is still called by any in-repo node (lists the callers -- remove those first) or is exported (it may have out-of-repo consumers). When it IS dead, removes it AND cascade-removes the now-dead PRIVATE helpers it solely used (recursively, to a fixed point), so a whole dead subtree goes at once -- the actionable follow-up to pcg_unused. Returns the plan (what would be removed); set apply=true to write. Call pcg_sync after.",
      inputSchema => { type => 'object', properties => {
          target => { type => 'string',  description => 'The dead function/method to delete: Pkg::sub, or a unique bare name' },
          apply  => { type => 'boolean', description => 'Write the deletions to disk (default false = dry-run plan)' },
      }, required => ['target'] } },
    { name => 'pcg_change_signature', handler => 'change_signature', description => "Change a plain function's PARAMETER LIST and propagate it to every resolved call site -- the SIXTH write tool, the actionable fix for a parameter change pcg_checkargs would otherwise flag everywhere. Three conservative operations: ADD a parameter (`add`, e.g. '\$verbose' or '\$n = 0', at 1-based position `at` or appended, inserting `value` (default `undef`) at each call site), REMOVE one (`remove`: a 1-based position, dropping that positional argument at each site), or REORDER (`reorder`: a comma list of 1-based positions that is a permutation of the params, e.g. '2,1,3' -- reorders the signature AND the argument list at every resolved call site to match). Function-only: a method (\$self/\$class first param) is refused, and a `\$obj->method` call site is reported to the frontier, because the invocant offsets the positions and the dispatch can't be statically tied. A call site whose argument list is statically indeterminate (a splat / deref / call-result among the args) or that doesn't reach the touched position is reported for manual review, never edited. Returns the plan (the new signature + the per-site edits); set apply=true to write. Call pcg_sync after.",
      inputSchema => { type => 'object', properties => {
          target => { type => 'string',  description => 'The function to re-signature: Pkg::func, or a unique bare name' },
          add     => { type => 'string',  description => "A parameter to add, e.g. '\$verbose' or '\$n = 0' (one of add/remove/reorder)" },
          remove  => { type => 'integer', description => 'The 1-based parameter position to remove (one of add/remove/reorder)' },
          reorder => { type => 'string',  description => "A permutation of 1-based positions, e.g. '2,1,3', that reorders the params + every call site's args (one of add/remove/reorder)" },
          at      => { type => 'integer', description => 'For add: the 1-based position to insert at (default: appended)' },
          value  => { type => 'string',  description => "For add: the argument expression to insert at each call site (default 'undef')" },
          apply  => { type => 'boolean', description => 'Write the edits to disk (default false = dry-run plan)' },
      }, required => ['target'] } },
    { name => 'pcg_extract', handler => 'extract', description => "Extract a contiguous STATEMENT RANGE out of a sub into a new named sub -- the SEVENTH write tool, the inverse of pcg_inline (and the actor for a pcg_duplication / long-method finding). Infers the interface from variable liveness: variables declared OUTSIDE the range that it reads become the new sub's PARAMETERS, and variables the range `my`-declares that are read AFTER it become its RETURN list (with a `my (...) =` binding at the call site). CONSERVATIVE -- refuses anything it can't prove behaviour-preserving: non-local control flow in the range (return / next / last / redo / goto / wantarray), a direct \@_ read, an outer variable the range MUTATES (the new value can't be threaded back), a `state` declaration (its cross-call persistence wouldn't survive), a range that splits a statement (or ends on the sub's closing-brace line), or more than one array/hash parameter OR return value. `lines` is a 1-based inclusive `START-END` range within ONE sub body; `file` is repo-relative. Returns the generated sub + the call that replaces the range + the inferred inputs/outputs; set apply=true to write (the new sub is placed right after the enclosing one). Call pcg_sync after.",
      inputSchema => { type => 'object', properties => {
          file  => { type => 'string',  description => 'The repo-relative file containing the code to extract' },
          lines => { type => 'string',  description => "A 1-based inclusive line range within one sub body, e.g. '12-18'" },
          name  => { type => 'string',  description => 'The bare name for the new sub' },
          apply => { type => 'boolean', description => 'Write the edits to disk (default false = dry-run plan)' },
      }, required => ['file', 'lines', 'name'] } },
    { name => 'pcg_hotspots', handler => 'hotspots', description => 'Call-graph hotspots, four lists: the most depended-upon symbols (fan-in, each with its transitive blast radius -- change with care), the symbols that make the most calls (fan-out), the most cyclomatically-complex symbols, and the most efferently-coupled modules. Good for review/refactor triage.',
      inputSchema => { type => 'object', properties => { limit => { type => 'integer', description => 'Top N per list (default 15)' } } } },
    { name => 'pcg_risk', handler => 'risk', description => 'History-aware risk: symbols ranked by git churn (commits touching their file) x fan-in (how many depend on them). Frequently-changed AND widely-depended-upon code is the top refactor/test target. With `since`, count only churn from commits since that ref (risk on the current branch). Needs a git work tree.',
      inputSchema => { type => 'object', properties => {
          limit => { type => 'integer', description => 'Top N (default 15)' },
          since => { type => 'string', description => 'Only count churn from commits since this ref (e.g. main)' },
      } } },
    { name => 'pcg_owners', handler => 'owners', description => "Code ownership x importance for bus-factor: each indexed file's primary author (most commits) and that author's share, ranked by how depended-upon the file is (cross-file inbound call/reference edges). A high-importance file owned almost entirely by one author is flagged a bus-factor risk. Needs a git work tree.",
      inputSchema => { type => 'object', properties => { limit => { type => 'integer', description => 'Top N (default 20)' } } } },
    { name => 'pcg_suggest_reviewers', handler => 'suggest_reviewers', description => "Suggest reviewers for a change: the authors of the files changed vs a git ref, ranked by how many commits they've made to that touched code (git authorship x the diff). The people who wrote the changed code review it best. The change's own author tends to rank first -- pick the next most familiar. Needs a git work tree.",
      inputSchema => { type => 'object', properties => { ref => { type => 'string', description => 'Git ref the change is measured against (e.g. main, HEAD~3)' } }, required => ['ref'] } },
    { name => 'pcg_cochange', handler => 'cochange', description => 'Logical (temporal) coupling: code files that change together in git history, ranked by Jaccard of their commit sets. Pairs marked with no static link are HIDDEN coupling the call graph cannot see (a change in one tends to need a change in the other). Needs a git work tree.',
      inputSchema => { type => 'object', properties => {
          limit       => { type => 'integer', description => 'Top N (default 15)' },
          min_support => { type => 'integer', description => 'Min shared commits (default 3)' },
          max_files   => { type => 'integer', description => 'Skip commits touching more than N code files (default 25; filters version-bump sweeps)' },
      } } },
    { name => 'pcg_semver', handler => 'semver', description => 'Recommend a Semantic Versioning bump (major/minor/patch) for the change vs a git ref, from the STRUCTURAL diff: removed or re-signatured PUBLIC API forces MAJOR; otherwise new public API is MINOR; otherwise internal-only changes are PATCH. Lists the evidence. To also draft the Changes entry text, use pcg_changelog. Needs a git work tree.',
      inputSchema => { type => 'object', properties => { ref => { type => 'string', description => 'Git ref to compare against (e.g. the last release tag, or main)' } }, required => ['ref'] } },
    { name => 'pcg_changelog', handler => 'changelog', description => "Draft a release-notes / Changes entry from the STRUCTURAL diff vs a git ref: the added, removed, and signature-changed functions/methods/constants/packages grouped under Added / Removed / Changed, each tagged public vs internal and breaking-vs-not, with the suggested version bump at the top. A ready-to-edit scaffold for a CPAN-style Changes entry (turn the bullet list into prose before release) -- complements pcg_semver (which only recommends the bump). Needs a git work tree.",
      inputSchema => { type => 'object', properties => { ref => { type => 'string', description => 'Git ref to compare against (the last release tag, or main)' } }, required => ['ref'] } },
    { name => 'pcg_diff', handler => 'diff', description => 'Structural ("semantic") diff vs a git ref: which functions/methods/constants/packages/classes were added, removed, or had their signature change between <ref> and the working tree -- with breaking changes (removed or re-signatured PUBLIC API) flagged. Ideal for reviewing a branch or PR. Needs a git work tree.',
      inputSchema => { type => 'object', properties => { ref => { type => 'string', description => 'Git ref to compare against (e.g. main, HEAD~3)' } }, required => ['ref'] } },
    { name => 'pcg_review', handler => 'review', description => 'Review a branch/PR in one call: the structural diff vs a git ref (added/removed/re-signatured symbols, breaking PUBLIC API flagged), the blast radius (count of files affected by the change), the tests to run, and -- for each breaking symbol -- how many callers still reference it. Plus graph-derived findings: untested public changes (no test reaches them) and wide-blast-radius changes (a touched public symbol many things still call). Composes the structural diff with the affected-files closure. Needs a git work tree and an index.',
      inputSchema => { type => 'object', properties => { ref => { type => 'string', description => 'Git ref to review against (e.g. main, HEAD~3)' } }, required => ['ref'] } },
    { name => 'pcg_pr', handler => 'pr', description => "A SCORED PR-HEALTH GATE for CI -- pcg_review folded into a single 0-100 health score and a PASS / REVIEW / BLOCK verdict, so a branch gets one yes/no-ish signal instead of a report to read. Adds to review what review doesn't do: it LINTS THE CHANGED FILES for call bugs (pcg_checkcalls + pcg_checkargs scoped to the touched files -- broken \$obj->method calls and wrong-arity calls in code this PR edits). The score is 100 minus weighted concerns: 15 per breaking public-API change, 12 per broken call, 10 per wrong-arity call, 6 per untested public change, 4 per wide-blast-radius change (>=85 PASS, 60-84 REVIEW, <60 BLOCK); concerns are listed worst-first, with the affected tests to run. Heuristic signal, not a substitute for human review. Needs a git work tree and an index.",
      inputSchema => { type => 'object', properties => { ref => { type => 'string', description => 'Git ref to gate against (e.g. main, HEAD~3)' } }, required => ['ref'] } },
    { name => 'pcg_api', handler => 'api', description => "A module's public surface: its exported and public (non-_) functions/methods/constants. To find which of those no other in-repo package calls, use pcg_dead_exports.",
      inputSchema => { type => 'object', properties => { module => { type => 'string', description => 'Module name' } }, required => ['module'] } },
    { name => 'pcg_covers', handler => 'covers', description => 'Which test files (transitively) exercise a symbol -- the reverse of pcg_affected(tests_only). Limited to statically-resolved calls.',
      inputSchema => { type => 'object', properties => { symbol => { type => 'string', description => 'Symbol name' } }, required => ['symbol'] } },
    { name => 'pcg_untested', handler => 'untested', description => "Untested public API: exported/public functions/methods/constants that no test file statically reaches. Omit `module` for the whole project. (A symbol exercised only via opaque \$obj->method dispatch from a test is invisible to static analysis and may appear here.) To generate a test + POD skeleton for a symbol from this list, use pcg_scaffold.",
      inputSchema => { type => 'object', properties => { module => { type => 'string', description => 'Focus on one module (optional)' } } } },
    { name => 'pcg_undocumented', handler => 'undocumented', description => "Undocumented public API: exported/public functions/methods/constants that carry no POD docstring (distinct from pcg_doccheck, which catches STALE docs -- a =head2 entry for a method that no longer exists). Omit `module` for the whole project. A documentation-coverage check for a release. To generate a POD + test skeleton for a symbol from this list, use pcg_scaffold.",
      inputSchema => { type => 'object', properties => { module => { type => 'string', description => 'Focus on one module (optional)' } } } },
    { name => 'pcg_dead_exports', handler => 'dead_exports', description => "Dead exports: exported functions/methods (\@EXPORT / \@EXPORT_OK) that NO other in-repo package calls -- public API you could stop exporting to shrink the surface. A caller in any OTHER package (tests included) makes an export live; same-package use does not. Constants are excluded (their bareword use isn't call-tracked). Honest caveat: a CPAN module's exports may be there for external/downstream consumers the graph can't see, so these are candidates to verify, not certain removals.",
      inputSchema => { type => 'object', properties => {} } },
    { name => 'pcg_unresolved', handler => 'unresolved', description => "Opaque `\$obj->method` calls static analysis could not resolve but which DO match candidate methods in the graph -- i.e. the calls you can resolve by inferring the receiver's class. Each lists its real candidates. Set by_receiver=true to instead group by (caller, receiver) and intersect the classes defining EVERY method called on that receiver -- a unique intersection is a near-certain type you can confirm and pass straight to pcg_resolve's { caller, receiver, class } form. Pair with pcg_resolve.",
      inputSchema => { type => 'object', properties => {
          name        => { type => 'string',  description => 'Restrict to this method name (optional; default mode: just its call sites; by_receiver mode: just the receivers that call it)' },
          limit       => { type => 'integer', description => 'Max items to return (default 50, highest-frequency first)' },
          by_receiver => { type => 'boolean', description => 'Group by receiver + suggest its class (the candidate-class intersection), instead of per-call' },
      } } },
    { name => 'pcg_resolve', handler => 'resolve', description => 'Record resolutions for opaque method calls (from pcg_unresolved). Two item forms, both writing `llm`-provenance edges that persist across reindex and NEVER fabricate a method the class lacks: (1) PREFERRED receiver-type form { caller, receiver, class } -- infer the receiver variable\'s class ONCE and every call on it in that caller resolves against the class\'s MRO (one entry resolves $db->query, $db->fetch, ... together); (2) explicit form { caller, method, receiver, target } -- map a single call to one Class::method. Targets/classes must be real (hallucinations are rejected).',
      inputSchema => { type => 'object', properties => {
          resolutions => { type => 'array', description => 'Resolutions to apply (each item uses the receiver-type OR the explicit form)',
              items => { type => 'object', properties => {
                  caller   => { type => 'string', description => 'Calling sub (qualified_name) -- both forms' },
                  receiver => { type => 'string', description => 'Receiver expression, e.g. $db -- both forms' },
                  class    => { type => 'string', description => 'Receiver-type form: the receiver\'s class; resolves ALL its calls at once' },
                  method   => { type => 'string', description => 'Explicit form: the single method name' },
                  target   => { type => 'string', description => 'Explicit form: resolved Class::method (one of the candidates)' },
              }, required => ['caller', 'receiver'] } },
      }, required => ['resolutions'] } },
    # --- lifecycle tools: build / refresh the graph in-session ---
    { name => 'pcg_index', handler => 'index', description => 'Build (or rebuild) the code graph for this project. Run this first if a read tool reports no index, or after large changes. Set runtime=true to also LOAD AND RUN the project code (forked + timeout-guarded) for dynamic-dispatch resolution. Set deps=true to also index the public API of the CPAN modules the project uses (from @INC, without running them), so calls into dependencies resolve.',
      inputSchema => { type => 'object', properties => {
          runtime => { type => 'boolean', description => 'Also run runtime enrichment -- executes the project code; default false' },
          deps    => { type => 'boolean', description => 'Also index used CPAN modules\' public API from @INC (no code run); default false' },
          embed   => { type => 'boolean', description => 'Also compute semantic-search embeddings (needs a local provider: PCG_EMBED_CMD or Ollama); default false' },
      } } },
    { name => 'pcg_sync', handler => 'sync', description => 'Incrementally refresh the graph after you edit files (re-resolves changed files and their dependents). Call this after changing Perl code so subsequent queries reflect it. (Does not refresh semantic-search embeddings -- re-run pcg_index embed:true to rebuild those.)',
      inputSchema => { type => 'object', properties => {} } },
    { name => 'pcg_status', handler => 'status', description => 'Graph health: node/edge counts and the edge provenance breakdown, or whether the graph has been built yet.',
      inputSchema => { type => 'object', properties => {} } },
);

# Tool names, for the installer's permission allow-list (single source of truth).
sub tool_names ($class) { map { $_->{name} } @TOOLS }

sub _result ($self, $id, $result) { return { jsonrpc => '2.0', id => $id, result => $result } }
sub _error  ($self, $id, $code, $msg) { return { jsonrpc => '2.0', id => $id, error => { code => $code, message => $msg } } }

sub dispatch ($self, $req) {
    # A well-formed JSON line that isn't an object (a bare number/string/array,
    # which decode accepts via allow_nonref) is not a valid request -> ignore it
    # rather than crash the server loop on $req->{method}.
    return undef unless ref $req eq 'HASH';
    my $method = $req->{method} // '';
    my $id     = $req->{id};
    # JSON-RPC 2.0: a message with no id is a notification — never reply.
    return undef unless defined $id;
    if ($method eq 'initialize') {
        return $self->_result($id, {
            protocolVersion => PROTOCOL_VERSION,
            capabilities    => { tools => {} },
            serverInfo      => { name => $self->server_name, version => $App::PerlGraph::VERSION },
            instructions    => INSTRUCTIONS,
        });
    }
    if ($method eq 'tools/list') {
        return $self->_result($id, { tools => [
            map { +{ name => $_->{name}, description => $_->{description}, inputSchema => $_->{inputSchema} } } @TOOLS
        ] });
    }
    if ($method eq 'tools/call') { return $self->_call_tool($id, $req->{params} // {}) }
    return $self->_error($id, -32601, "Method not found: $method");
}

sub _maybe_sync ($self) {
    return unless $self->watch && $self->indexer;
    my $now = time;
    return if defined $self->{_last_sync} && $now - $self->{_last_sync} < 2;   # debounce
    $self->{_last_sync} = $now;
    eval { $self->indexer->sync };   # fail-soft: stale data beats a crashed server
}

sub _call_tool ($self, $id, $params) {
    $self->_maybe_sync;
    my $name = $params->{name} // '';
    my ($tool) = grep { $_->{name} eq $name } @TOOLS;
    return $self->_error($id, -32602, "Unknown tool: $name") unless $tool;
    my $text = eval { $self->_run_tool($tool->{handler}, $params->{arguments} // {}) };
    return $self->_result($id, { content => [{ type => 'text', text => "Error: $@" }], isError => \1 }) if $@;
    return $self->_result($id, { content => [{ type => 'text', text => $text }] });
}

sub _indexed ($self) {
    my $q = $self->query or return 0;
    my $store = eval { $q->store } or return 1;   # a query with no introspectable store -> assume usable
    return scalar @{ $store->dbh->selectcol_arrayref('select 1 from nodes limit 1') };
}

sub _status_text ($self) {
    my $q = $self->query or return "Graph not built yet -- call pcg_index.";
    return "Graph not built yet -- call pcg_index." unless $self->_indexed;
    my $s = $q->store;
    my ($n)  = $s->dbh->selectrow_array('select count(*) from nodes');
    my ($e)  = $s->dbh->selectrow_array('select count(*) from edges');
    my ($u)  = $s->dbh->selectrow_array('select count(*) from unresolved_refs');
    my ($md) = $s->dbh->selectrow_array("select count(*) from unresolved_refs where reference_kind = 'method_call'");
    my ($ut) = $s->dbh->selectrow_array("select count(*) from unresolved_refs where file_path like '%.t'");
    my $by   = $s->dbh->selectall_arrayref('select provenance, count(*) c from edges group by provenance order by provenance');
    my $prov = @$by ? "\nedges by provenance: " . join(', ', map { "$_->[0]=$_->[1]" } @$by) : "";
    my $uget = $u ? " ($md dynamic method-dispatch, @{[ $u - $md ]} bareword calls; pcg_index with runtime:true, or pcg_unresolved+pcg_resolve, resolves much of the former)" : "";
    my $split = ($u && $ut) ? "\n@{[ $u - $ut ]} unresolved in your code, $ut in tests (test calls into CPAN clients are the expected frontier)" : "";
    return "nodes=$n edges=$e unresolved=$u$uget$split$prov";
}

sub _run_tool ($self, $handler, $args) {
    my $idx = $self->indexer;

    # lifecycle tools operate even before any graph exists
    if ($handler eq 'index') {
        return "No project to index (the server was started without an indexer)." unless $idx;
        my $rt = $args->{runtime} ? 1 : 0;
        my $st = App::PerlGraph::Indexer->new(store => $idx->store, root => $self->base,
            runtime => $rt, deps => ($args->{deps} ? 1 : 0), embed => ($args->{embed} ? 1 : 0))->index_all;
        return "Indexed $st->{files} files ($st->{reindexed} (re)parsed)"
            . ($st->{deps} ? " + $st->{deps} CPAN deps" : "") . ($rt ? " + runtime enrichment" : "")
            . ($st->{embedded} ? " + $st->{embedded} embeddings" : "") . ".";
    }
    if ($handler eq 'sync') {
        return "No project to sync (the server was started without an indexer)." unless $idx;
        my $st = $idx->sync;
        return "Synced: $st->{reindexed} reindexed"
            . ($st->{dependents} ? ", $st->{dependents} dependent(s) refreshed" : "")
            . ($st->{deleted}    ? ", $st->{deleted} deleted" : "") . ".";
    }
    return $self->_status_text if $handler eq 'status';

    # read tools require a built graph -- except pcg_diff, which parses git directly
    # (no graph needed), matching the CLI `pcg diff`. pcg_review still needs the index.
    return "No index yet. Call pcg_index first to build the graph for this project."
        unless $self->_indexed || $handler eq 'diff' || $handler eq 'semver' || $handler eq 'changelog';
    my $q = $self->query;
    my $sym = $args->{symbol} // '';
    if ($handler eq 'search') {
        my $query = $args->{query} // '';
        return $args->{semantic} ? App::PerlGraph::Format::semantic($query, $q->semantic($query))
                                 : App::PerlGraph::Format::search($query, [ $q->search($query) ]);
    }
    return App::PerlGraph::Format::callers($sym, [ $q->callers($sym) ]) if $handler eq 'callers';
    return App::PerlGraph::Format::callees($sym, [ $q->callees($sym) ]) if $handler eq 'callees';
    return App::PerlGraph::Format::impact($sym,  [ $q->impact($sym) ])  if $handler eq 'impact';
    return App::PerlGraph::Format::node_view($sym, [ $q->node_view($sym) ], $self->base) if $handler eq 'node';
    return App::PerlGraph::Format::explain($sym, [ $q->explain($sym) ], $self->base) if $handler eq 'explain';
    return App::PerlGraph::Format::context($q->context($sym), $self->base, ($args->{budget} || 16000)) if $handler eq 'context';
    return App::PerlGraph::Format::explore($args->{query} // '', [ $q->explore($args->{query} // '') ], $self->base)
        if $handler eq 'explore';
    return App::PerlGraph::Format::unused([ $q->unused(all => $args->{all}) ]) if $handler eq 'unused';
    return App::PerlGraph::Format::path($args->{from} // '', $args->{to} // '', [ $q->path($args->{from} // '', $args->{to} // '') ])
        if $handler eq 'path';
    if ($handler eq 'affected') {
        my $files = ref $args->{files} eq 'ARRAY' ? [ @{ $args->{files} } ] : [];
        if (defined $args->{since} && length $args->{since}) {
            require App::PerlGraph::Git;
            my $git = App::PerlGraph::Git->new(root => $self->base);
            return "`since` needs a git work tree." unless $git->available;
            push @$files, @{ $git->changed($args->{since}) };
        }
        return App::PerlGraph::Format::affected($files, [ $q->affected($files, tests_only => $args->{tests_only}) ]);
    }
    return App::PerlGraph::Format::deps([ $q->deps($args->{module}) ])             if $handler eq 'deps';
    return App::PerlGraph::Format::prereqs($q->prereqs($self->base))               if $handler eq 'prereqs';
    return App::PerlGraph::Format::cycles([ $q->cycles ])                          if $handler eq 'cycles';
    return App::PerlGraph::Format::layers($q->layers)                              if $handler eq 'layers';
    return App::PerlGraph::Format::checkcalls($q->checkcalls)                      if $handler eq 'checkcalls';
    return App::PerlGraph::Format::checkargs($q->checkargs($self->base))           if $handler eq 'checkargs';
    return App::PerlGraph::Format::doccheck($q->doccheck($self->base))             if $handler eq 'doccheck';
    return App::PerlGraph::Format::scaffold($q->scaffold($args->{symbol} // ''))    if $handler eq 'scaffold';
    return App::PerlGraph::Format::metrics($q->metrics)                            if $handler eq 'metrics';
    return App::PerlGraph::Format::dead_exports($q->dead_exports)                  if $handler eq 'dead_exports';
    return App::PerlGraph::Format::duplication($q->duplication(map { defined $args->{$_} ? ($_ => $args->{$_}) : () } qw(limit min_nodes))) if $handler eq 'duplication';
    if ($handler eq 'tidy') {
        my %o = map { defined $args->{$_} ? ($_ => $args->{$_}) : () } qw(limit min_nodes);
        if ($args->{apply}) {                                    # execute the safe cleanup (dedupe + rm), re-syncing as it goes
            require App::PerlGraph::Refactor;
            return App::PerlGraph::Format::tidy(
                App::PerlGraph::Refactor->new(store => $q->store, root => $self->base)->tidy(%o, apply => 1));
        }
        return App::PerlGraph::Format::tidy($q->tidy(%o));
    }
    return App::PerlGraph::Format::smells($q->smells(map { defined $args->{$_} ? ($_ => $args->{$_}) : () } qw(limit))) if $handler eq 'smells';
    return App::PerlGraph::Format::overview($q->overview(defined $args->{limit} ? (limit => $args->{limit}) : ())) if $handler eq 'overview';
    return App::PerlGraph::Format::sinks($q->sinks) if $handler eq 'sinks';
    return App::PerlGraph::Format::taint($q->taint(map { defined $args->{$_} ? ($_ => $args->{$_}) : () } qw(limit))) if $handler eq 'taint';
    if ($handler eq 'rename') {
        require App::PerlGraph::Refactor;
        return App::PerlGraph::Format::rename(
            App::PerlGraph::Refactor->new(store => $q->store, root => $self->base)
                ->rename($args->{old} // '', $args->{new} // '', ($args->{apply} ? (apply => 1) : ())));
    }
    if ($handler eq 'move') {
        require App::PerlGraph::Refactor;
        return App::PerlGraph::Format::move(
            App::PerlGraph::Refactor->new(store => $q->store, root => $self->base)
                ->move($args->{old} // '', $args->{to} // '', ($args->{apply} ? (apply => 1) : ())));
    }
    if ($handler eq 'inline') {
        require App::PerlGraph::Refactor;
        return App::PerlGraph::Format::inline(
            App::PerlGraph::Refactor->new(store => $q->store, root => $self->base)
                ->inline($args->{target} // '', ($args->{apply} ? (apply => 1) : ())));
    }
    if ($handler eq 'change_signature') {
        require App::PerlGraph::Refactor;
        return App::PerlGraph::Format::change_signature(
            App::PerlGraph::Refactor->new(store => $q->store, root => $self->base)->change_signature(
                $args->{target} // '',
                (map { defined $args->{$_} ? ($_ => $args->{$_}) : () } qw(add remove reorder at value)),
                ($args->{apply} ? (apply => 1) : ())));
    }
    if ($handler eq 'dedupe') {
        require App::PerlGraph::Refactor;
        return App::PerlGraph::Format::dedupe(
            App::PerlGraph::Refactor->new(store => $q->store, root => $self->base)
                ->dedupe($args->{target} // '', ($args->{apply} ? (apply => 1) : ())));
    }
    if ($handler eq 'rm') {
        require App::PerlGraph::Refactor;
        return App::PerlGraph::Format::rm(
            App::PerlGraph::Refactor->new(store => $q->store, root => $self->base)
                ->rm($args->{target} // '', ($args->{apply} ? (apply => 1) : ())));
    }
    if ($handler eq 'extract') {
        require App::PerlGraph::Refactor;
        return App::PerlGraph::Format::extract(
            App::PerlGraph::Refactor->new(store => $q->store, root => $self->base)
                ->extract($args->{file} // '', $args->{lines} // '', $args->{name} // '', ($args->{apply} ? (apply => 1) : ())));
    }
    return App::PerlGraph::Format::hotspots($q->hotspots(defined $args->{limit} ? (limit => $args->{limit}) : ())) if $handler eq 'hotspots';
    if ($handler eq 'diff' || $handler eq 'review' || $handler eq 'semver' || $handler eq 'changelog' || $handler eq 'pr') {
        require App::PerlGraph::Git; require App::PerlGraph::Diff; require App::PerlGraph::Parser;
        my $git = App::PerlGraph::Git->new(root => $self->base);
        return "This needs a git work tree." unless $git->available;
        my $ref = $args->{ref}; return "a `ref` is required." unless defined $ref && length $ref;
        my $parser = eval { App::PerlGraph::Parser->new } or return "parser unavailable.";
        return App::PerlGraph::Format::diff(
            App::PerlGraph::Diff->new(root => $self->base, ref => $ref, parser => $parser)->diff, $ref)
            if $handler eq 'diff';
        return App::PerlGraph::Format::semver(
            App::PerlGraph::Diff->new(root => $self->base, ref => $ref, parser => $parser)->diff, $ref)
            if $handler eq 'semver';
        return App::PerlGraph::Format::changelog(
            App::PerlGraph::Diff->new(root => $self->base, ref => $ref, parser => $parser)->diff, $ref)
            if $handler eq 'changelog';
        require App::PerlGraph::Review;
        return App::PerlGraph::Format::pr(
            App::PerlGraph::Review->new(root => $self->base, ref => $ref, parser => $parser, store => $q->store)->pr)
            if $handler eq 'pr';
        return App::PerlGraph::Format::review(
            App::PerlGraph::Review->new(root => $self->base, ref => $ref, parser => $parser, store => $q->store)->review);
    }
    if ($handler eq 'risk' || $handler eq 'cochange' || $handler eq 'owners' || $handler eq 'suggest_reviewers') {
        require App::PerlGraph::Git;
        my $git = App::PerlGraph::Git->new(root => $self->base);
        return "This analysis needs git history -- the project root isn't a git work tree." unless $git->available;
        if ($handler eq 'suggest_reviewers') {
            my $ref = $args->{ref}; return "a `ref` is required." unless defined $ref && length $ref;
            my $changed = $git->changed($ref);
            return App::PerlGraph::Format::suggest_reviewers($q->suggest_reviewers($git->authors, $changed), $ref, scalar @$changed);
        }
        return App::PerlGraph::Format::owners($q->owners($git->authors,
            defined $args->{limit} ? (limit => $args->{limit}) : ())) if $handler eq 'owners';
        return App::PerlGraph::Format::risk([ $q->risk($git->churn(defined $args->{since} ? (since => $args->{since}) : ()),
            defined $args->{limit} ? (limit => $args->{limit}) : ()) ])
            if $handler eq 'risk';
        return App::PerlGraph::Format::cochange([ $q->cochange($git->commits,
            (defined $args->{limit}       ? (limit       => $args->{limit})       : ()),
            (defined $args->{min_support} ? (min_support => $args->{min_support}) : ()),
            (defined $args->{max_files}   ? (max_files   => $args->{max_files})   : ())) ]);
    }
    return App::PerlGraph::Format::api($args->{module} // '', [ $q->api($args->{module} // '') ]) if $handler eq 'api';
    return App::PerlGraph::Format::covers($sym, [ $q->covers($sym) ])              if $handler eq 'covers';
    return App::PerlGraph::Format::untested([ $q->untested($args->{module}) ])     if $handler eq 'untested';
    return App::PerlGraph::Format::undocumented([ $q->undocumented($args->{module}) ]) if $handler eq 'undocumented';
    if ($handler eq 'unresolved') {
        return App::PerlGraph::Format::resolve_targets([ $q->resolve_targets(
            ($args->{name}          ? (name  => $args->{name})  : ()),
            (defined $args->{limit} ? (limit => $args->{limit}) : ())) ]) if $args->{by_receiver};
        return App::PerlGraph::Format::unresolved([ $q->unresolved(
            ($args->{name}          ? (name  => $args->{name})  : ()),
            (defined $args->{limit} ? (limit => $args->{limit}) : ()),
        ) ]);
    }
    if ($handler eq 'resolve') {
        my $r = ref $args->{resolutions} eq 'ARRAY' ? $args->{resolutions} : [];
        return App::PerlGraph::Format::resolved($q->resolve($r));
    }
    die "unhandled tool: $handler\n";
}

sub run ($self) {
    my ($in, $out) = ($self->in, $self->out);
    # We do our own UTF-8 via Cpanel::JSON::XS->utf8, so byte-orient both handles
    # regardless of any ambient encoding layer (e.g. bin/pcg sets STDOUT utf8).
    binmode $in,  ':raw';
    binmode $out, ':raw';
    { my $old = select($out); $| = 1; select($old); }   # autoflush responses
    while (defined(my $line = readline $in)) {
        chomp $line;
        next unless length $line;
        my $req = eval { $self->_json->decode($line) } or next;
        my $resp = $self->dispatch($req);
        next unless defined $resp;
        print {$out} $self->_json->encode($resp), "\n";
    }
}

1;

__END__

=head1 NAME

App::PerlGraph::MCP - Model Context Protocol server over the graph

=head1 DESCRIPTION

A hand-rolled JSON-RPC 2.0 server over stdio that exposes the query API as MCP tools for AI agents.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
