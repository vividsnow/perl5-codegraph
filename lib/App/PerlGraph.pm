package App::PerlGraph;
use v5.36;
our $VERSION = '0.064';
1;

__END__

=head1 NAME

App::PerlGraph - a Perl-native code knowledge graph for AI agents

=head1 SYNOPSIS

    pcg index .                       # build .pcg/graph.db for a Perl project
    pcg sync                          # incremental update (changed files + dependents)
    pcg watch                         # keep it fresh: re-index on file changes
    pcg overview                      # codebase map: scale, frameworks, entry points, central symbols
    pcg metrics                       # code-health snapshot: coverage, complexity, dead code, clones, cycles
    pcg explore Some::Module          # symbols with source + POD + relationships
    pcg node|search Some::thing       # a symbol's definition / symbol search
    pcg explain Some::thing           # one-call dossier: source + callers/callees + blast radius + tests
    pcg context Some::thing           # paste-ready editing set: source + each project callee's source + tests
    pcg callers|callees|impact X      # who calls X / what X calls / blast radius
    pcg path Foo::a Bar::z            # shortest call path between two symbols
    pcg unused                        # dead-code candidates (nothing references)
    pcg untested|undocumented         # public API symbols no test reaches / with no POD
    pcg doccheck                      # stale POD: documents a method/sub that no longer exists (drift)
    pcg scaffold Some::thing          # a POD + test skeleton (with TODOs) for a sub, from its signature
    pcg dead-exports                  # exported functions/methods no other in-repo pkg calls (retractable API)
    pcg checkcalls                    # broken method calls: $obj->method the receiver's known class lacks
    pcg checkargs                     # wrong-arity calls: too few / too many args vs a sub's signature
    pcg affected lib/Foo.pm           # files/tests impacted by a change
    pcg deps|cycles|layers            # module deps / cycles / architecture layers (by dependency depth)
    pcg api|covers X                  # a module's public surface / which tests exercise a symbol
    pcg prereqs                       # declared CPAN prereqs vs actually-used (missing / unused)
    pcg unresolved [--by-receiver]    # opaque $obj->method calls (--by-receiver suggests each receiver's class)
    pcg hotspots                      # fan-in / fan-out / complexity / coupling leaders
    pcg duplication                   # structural code clones (type-1/2): extract-a-shared-helper targets
    pcg tidy                          # one cleanup dashboard: removable dead code, retractable exports, clones + fix commands
    pcg smells                        # refactoring smells: feature-envy (move), god-class (split), long-parameter-list
    pcg risk [--since main]           # git churn x fan-in (--since: churn on the current branch)
    pcg cochange                      # files that change together (logical coupling)
    pcg owners                        # code ownership x importance (bus-factor risks)
    pcg suggest-reviewers main        # who should review a change: authors of the changed files, ranked
    pcg sinks                         # command/SQL execution sites + which web endpoints reach them
    pcg taint                         # source -> sink paths: user-input source -> dynamic command/SQL sink (reachability)
    pcg diff main                     # structural diff vs a ref (added/removed/changed + breaking)
    pcg semver main                   # recommend a major/minor/patch version bump from the diff
    pcg changelog main                # draft a Changes-style entry from the structural diff
    pcg review main                   # PR review: diff + blast radius + tests + breaking + findings
    pcg pr main                       # scored PR-health gate: 0-100 + PASS/REVIEW/BLOCK (for CI)
    pcg rename Foo::bar baz [--apply] # graph-driven rename within a package (dry-run by default)
    pcg move Foo::bar Other::Pkg [--apply]  # move a sub to another package: relocate source + requalify calls
    pcg inline Foo::helper [--apply]  # inline a simple function at its call sites (do{} block) + remove def
    pcg dedupe Foo::canon [--apply]   # de-duplicate a clone group: each exact dup -> { goto &Foo::canon }
    pcg change-signature Foo::f --remove 2   # add/remove a function param + propagate to every resolved call site
    pcg rm Foo::dead [--apply]        # safely delete a dead sub + cascade now-dead private helpers
    pcg search --semantic "intent"    # rank symbols by meaning (needs `index --embed` + a local provider)
    pcg export --format html          # render the graph (dot|mermaid|json|html -- html is interactive)
    pcg index --deps                  # also resolve calls into used CPAN modules (@INC)
    pcg index --embed                 # also compute semantic-search embeddings (optional local provider)
    pcg index --runtime               # also add runtime introspection (loads code)
    pcg install                       # register the MCP server with Claude Code
    pcg serve  --mcp                  # run the MCP server (stdio JSON-RPC 2.0)
    pcg lsp                           # run a Language Server (go-to-def / find-refs / hover)

=head1 DESCRIPTION

C<App::PerlGraph> parses a Perl codebase (via L<Text::Treesitter> and the
tree-sitter-perl grammar) into a SQLite knowledge graph of packages, subs,
calls, imports and inheritance, answers structural queries over it, and serves
them to AI coding agents over MCP so they read the graph instead of grepping.

Beyond static parsing it offers, opt-in (C<--runtime>), runtime enrichers
(L<Devel::Symdump>, the C<B::> optree, and Moo/Moose MOP) that resolve dynamic
dispatch, the real C<@ISA>, and roles/attributes; framework-route resolvers
(Dancer2 / Mojolicious::Lite / Catalyst); and an XS/C bridge linking Perl subs
to their XSUBs. Every relationship records its provenance (C<static>,
C<inferred>, C<heuristic>, C<framework>, C<symtab>, C<optree>, C<mop>, C<xs>,
C<llm>) so
partial coverage stays honest.

Even without C<--runtime>, the static resolver follows idiomatic OO: C<$self>/
C<$class> method calls resolve against the enclosing package, its C<@ISA> (full
MRO), and composed Moo/Moose roles, as C<heuristic>-provenance edges that a later
runtime pass upgrades.

The C<pcg> command-line tool is the entry point; C<pcg install> registers the
MCP server with Claude Code so an agent can query the graph directly.

=head1 SEE ALSO

The C<pcg> command (C<perldoc pcg>) for the full command reference, and
L<Text::Treesitter> for the underlying parser.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow.

This library is free software; you may redistribute it and/or modify it under
the same terms as Perl itself, either Perl version 5.36.0 or, at your option,
any later version of Perl 5 you may have available.

=cut
