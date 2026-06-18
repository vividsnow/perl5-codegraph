# tree-sitter-perl — ground truth (verified 2026-06-16)

Empirically verified against tree-sitter-perl grammar **v1.1.2** (release branch) via `Text::Treesitter 0.13` on this machine. Supersedes the guessed constants/regex in the plan: extractors MUST use the **field-based** access below, not text regex.

## Build (what actually works)

- Grammar source `src/parser.c` is **NOT** on `master` (18 MB, generated). It **is** on the `release` branch. So clone the release branch:
  `git clone --depth 1 --branch release https://github.com/tree-sitter-perl/tree-sitter-perl $DIR`
- `Text::Treesitter->new(lang_name=>'perl', lang_dir=>$DIR)` **auto-compiles** `$DIR/tree-sitter-perl.so` from `$DIR/src/parser.c` + `scanner.c` on first use (via `Text::Treesitter::Language::build($output, @dirs)` — positional args). Compile takes ~3 s with gcc.
- libtree-sitter 0.26.8 is already installed system-wide (pkg-config finds it). `Text::Treesitter` is installed.
- Convention: `PCG_TS_PARSER_DIR` env → grammar dir, default `~/.cache/pcg/tree-sitter-perl`.

## Text::Treesitter API (verified accessors)

- `my $ts = Text::Treesitter->new(lang_name=>'perl', lang_dir=>$dir);`
- `my $tree = $ts->parse_string($src);` / `$ts->parse_file($path)` (0.13+)
- `my $root = $tree->root_node;` → `Text::Treesitter::Node`
- Node methods: `->type`, `->text` (char-offset substring — no manual slicing needed), `->is_named`, `->is_extra`, `->has_error`, `->start_point` → `($row,$col)` 0-based, `->end_point`, `->start_byte/->end_byte`, `->child_count`, `->child_nodes` (list of Node), `->field_names_with_child_nodes` (even-length `($fieldname_or_undef, $child)...` list), `->child_by_field_name($f)` (throws if absent), `->try_child_by_field_name($f)` (undef if absent), `->debug_sprintf` (S-expr dump).
- There is **no** `->child($i)` / `->field_name_for_child($i)`. Normalize via `field_names_with_child_nodes`.

## Node types & fields for our constructs (from src/node-types.json)

| Construct | node type | fields |
|---|---|---|
| root | `source_file` | — |
| package | `package_statement` | `name`, `version` |
| sub (named) | `subroutine_declaration_statement` | `name`, `body`, `attributes`, `lexical` |
| method (native/Object::Pad) | `method_declaration_statement` | `name`, `body`, `attributes`, `lexical` |
| use / no | `use_statement` | `module`, `version` |
| require | `require_expression` | — (module is a child node, read its text) |
| call | `function_call_expression` | `function`, `arguments` |
| call (e.g. `bless {…}`) | `ambiguous_function_call_expression` | `function`, `arguments` |
| call (named unary/list op) | `func0op_call_expression` | `function` |
| method call | `method_call_expression` | `invocant`, `method`, `arguments` |
| assignment (`our @ISA = …`) | `assignment_expression` | `left`, `operator`, `right` |
| var decl (`our @X`) | `variable_declaration` | `variable`, `variables`, `attributes` |
| `qw(...)` | `quoted_word_list` | `content` (one string_content with the whole list; split on whitespace) |
| sub attribute (`:Path('/x')`) | `attribute` | `name`, `value` |

**Name-bearing leaf nodes** (read `->text`): `package` (package/module name, e.g. `Acme::Widget`, `parent`, `constant`), `bareword` (sub name), `function` (called function name, e.g. `helper`, `Acme::Util::log`, `bless`), `method` (method name), `varname` (variable name without sigil, e.g. `ISA`, `EXPORT_OK`).

## Extraction recipes (field-based)

- **package**: `pkg_stmt->fields{name}->text`
- **sub**: `sub_stmt->fields{name}->text`; body = `fields{body}`; signature = child of type `signature`. Treat `subroutine_declaration_statement` and `method_declaration_statement` alike (method-vs-function decided by enclosing package being a class).
- **use parent/base**: `use_stmt` where `fields{module}->text` is `parent` or `base` → read child `string_literal`/`quoted_word_list` contents → `extends`. (`use parent -norequire, 'X'` — skip the `-norequire`.)
- **use constant**: `fields{module}->text eq 'constant'` → `constant` node from the following `autoquoted_bareword`/list.
- **plain use/require**: otherwise → `imports` edge with module = `fields{module}->text` (or require's child text).
- **our @ISA / @EXPORT(_OK)**: `assignment_expression` whose `fields{left}` is a `variable_declaration` with `variable`→`array`→`varname` text `ISA`/`EXPORT`/`EXPORT_OK`. Values from `fields{right}`: gather `string_literal` `string_content` text and `quoted_word_list` content (split on whitespace).
- **calls**: any of `function_call_expression` / `ambiguous_function_call_expression` / `func0op_call_expression` → `fields{function}->text` is the callee name (may be `Foo::Bar::baz`). `func0op` callees are usually builtins (filter).
- **method calls**: `method_call_expression` → `fields{method}->text` = method; `fields{invocant}->text` = receiver (`$self`, `Thing`, `__PACKAGE__`). Method chains nest: invocant may itself be a `method_call_expression`.

## Sample S-expr (reference)

`sub run ($self) { $self->make->render; helper(); Acme::Util::log("hi"); Thing->build }` parses to nested `method_call_expression`/`function_call_expression` with the fields above; `our @EXPORT_OK = qw(make build)` →
`(assignment_expression left: (variable_declaration "our" variable: (array "@" (varname))) operator: "=" right: (quoted_word_list "qw" "(" content: (string_content) ")"))`.

Verified clean parse (`has_error: no`) on a representative modern+legacy sample.
