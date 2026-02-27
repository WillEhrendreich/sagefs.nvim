# Testing sagefs.nvim

sagefs.nvim uses **two test runners** for different types of tests:

## 1. Busted (unit tests)

Pure Lua tests that don't require Neovim runtime. Run with:

```bash
lua run_busted.lua --helper=spec/helper.lua
```

Tests live in `spec/*.lua` and use busted's `describe`/`it`/`assert` API.
These tests mock `vim.*` APIs via `spec/helper.lua`.

**Coverage:** SSE parsing, cell boundary detection (`;;`), model state, transport, rendering, completions, format, diagnostics, etc.

## 2. nvim --headless (tree-sitter integration tests)

Tests requiring Neovim's tree-sitter runtime. Run with:

```bash
nvim --headless -l spec/treesitter_cells_spec.lua
```

These tests use a minimal self-contained harness (no busted dependency)
because they need `vim.treesitter`, `vim.api`, and the tree-sitter-fsharp
grammar — none of which are available in busted.

**Prerequisite:** tree-sitter-fsharp grammar must be installed in Neovim
(`TSInstall fsharp`).

The spec file includes a guard (`if not vim or not vim.opt then return end`)
so busted skips it without errors.

**Coverage:** Tree-sitter cell detection across 5 fixture files:
- `fixtures/basic_bindings.fs` — simple lets, records, DUs, match
- `fixtures/complex_expressions.fs` — multi-arm match, async CE, seq CE
- `fixtures/attributed_and_typed.fs` — attributes, let rec...and, interfaces
- `fixtures/nested_modules.fs` — namespace with nested modules
- `fixtures/type_with_members.fs` — `type...with` member workaround
- `fixtures/do_expressions.fs` — `do` expressions (common in .fsx)

## Fixture files

Fixture files in `fixtures/` are test data. **Do not edit without updating
`spec/treesitter_cells_spec.lua`** — tests assert specific line numbers.

## Known gaps

- **Transport integration:** No test starts a real curl process or connects
  to a mock SSE server. Transport behavior is tested via mocked callbacks.
- **tree-sitter-fsharp `with` members:** The grammar incorrectly parses
  `type Foo = { ... } with member ...` as separate nodes. We work around
  this in `treesitter_cells.lua` (see `extract_from_app_expr`).
