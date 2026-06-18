#!/usr/bin/env bash
set -euo pipefail
# Build the tree-sitter-perl grammar into a loadable .so for Text::Treesitter.
# The release branch ships the generated src/parser.c (master does not — it's 18MB).
DIR="${PCG_TS_PARSER_DIR:-$HOME/.cache/pcg/tree-sitter-perl}"
if [ ! -f "$DIR/src/parser.c" ]; then
  rm -rf "$DIR"
  git clone --depth 1 --branch release https://github.com/tree-sitter-perl/tree-sitter-perl "$DIR"
fi
# Compile parser.c + scanner.c into $DIR/tree-sitter-perl.so (Text::Treesitter::build is positional: build($output, @dirs)).
perl -MText::Treesitter::Language -e 'Text::Treesitter::Language::build("'"$DIR"'/tree-sitter-perl.so", "'"$DIR"'")'
echo "Built grammar: $DIR/tree-sitter-perl.so"
