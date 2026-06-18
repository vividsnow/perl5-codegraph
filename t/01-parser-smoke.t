use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "Text::Treesitter unavailable: $@";
my $tree = eval { $parser->raw_parse("my \$x = 1;\n") }
    or skip_all "tree-sitter-perl grammar not built (run tools/build-grammar.sh): $@";

ok $tree, 'got a parse tree';
my $root = $tree->root_node;
ok $root, 'tree has a root node';
is $root->type, 'source_file', 'root node type is source_file';
done_testing;
