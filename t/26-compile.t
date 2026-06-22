use v5.36;
use Test2::V0;

# Every module compiles and loads (no syntax errors, deps resolvable).
my @mods = qw(
    App::PerlGraph
    App::PerlGraph::Parser   App::PerlGraph::Grammar  App::PerlGraph::Model
    App::PerlGraph::Schema    App::PerlGraph::Store    App::PerlGraph::Extractor
    App::PerlGraph::Resolver  App::PerlGraph::Indexer  App::PerlGraph::Query
    App::PerlGraph::Format    App::PerlGraph::Source   App::PerlGraph::MCP
    App::PerlGraph::Installer App::PerlGraph::CLI      App::PerlGraph::Runtime
    App::PerlGraph::XS        App::PerlGraph::Watcher  App::PerlGraph::Pod
    App::PerlGraph::LSP       App::PerlGraph::Git       App::PerlGraph::Diff       App::PerlGraph::Review
);
for my $m (@mods) {
    my $loaded = eval "require $m; 1";
    ok $loaded, "$m loads" or diag $@;
}
done_testing;
