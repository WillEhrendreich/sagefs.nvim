# Testing sagefs.nvim

sagefs.nvim uses **two test runners** for different types of tests:

## 1. Busted (unit tests)

Pure Lua tests that don't require Neovim runtime. Run with:

```bash
lua run_busted.lua --helper=spec/helper.lua
```

Tests live in `spec/*.lua` and use busted's `describe`/`it`/`assert` API.
These tests mock `vim.*` APIs via `spec/helper.lua`.

`run_busted.lua` carries Windows LuaRocks paths. On Linux and macOS, plain
`busted` at the repo root is enough: `.busted` points it at `spec/` and at
`spec/helper.lua` (which mocks `vim.*`), and skips `spec/e2e/`. This is the
command the GitHub workflow runs and the one SageFs's `scripts/sync-nvim-version`
runs as its gate before it publishes a plugin release.

```bash
busted                                                      # exits non-zero on any failure
nvim --headless --clean -u NONE -l spec/nvim_harness.lua    # headless integration
```

If `busted` says `module 'busted.runner' not found`, LuaRocks is not on the Lua
path of your shell. With several Lua versions installed, pick the tree that
matches the interpreter busted will use, for example:

```bash
eval "$(luarocks --lua-version 5.5 path)"
```

Do not add a `lua = "..."` key to `.busted`. It makes busted re-run itself through
that interpreter name without the LuaRocks package path, which is exactly the
failure above, and `spec/busted_config_spec.lua` guards against it.

The specs run on Lua 5.1 (what the workflow installs), 5.4, 5.5 and LuaJIT. That
means no `file:read("a")` or `("l")` (use `"*a"` and `"*l"`), no `//`, no
`goto`, and no assigning to a loop variable (5.5 makes those constants). To
check another interpreter, run busted with that Lua and its LuaRocks tree, for
example `eval "$(luarocks --lua-version 5.1 path)"; lua5.1 ~/.luarocks/lib/luarocks/rocks-5.1/busted/*/bin/busted`.

The summary line is where the current counts live: busted prints
`N successes / N failures / N errors / N pending`, the headless harness prints
`Results: N passed, N failed`. I do not copy those numbers into the README or
into this file, because they change with every spec.

The plugin's version tracks the SageFs release (see "Versions" in the README).
`spec/version_spec.lua` checks it against a SageFs checkout:

- `SAGEFS_REPO=~/Work/SageFs busted spec/version_spec.lua` is strict. It fails
  while `lua/sagefs/version.lua` differs from that checkout's
  `Directory.Build.props`, and the fix is `./sync-version.sh ~/Work/SageFs`.
- With no `SAGEFS_REPO`, it looks for a checkout at `../SageFs` (or the same
  from a git worktree under `.worktrees/`). Equal versions pass. Different
  versions make it pending with both numbers, never failing: the release
  script bumps this plugin after it pushes SageFs and gates the bump on this
  suite, so a plugin that is one release behind has to stay green.
- With no checkout (the GitHub workflow has none) it is pending and says so.

**Coverage:** SSE parsing, cell boundary detection (`;;`), model state, transport, rendering, completions, format, diagnostics, etc.

## 1b. nvim --headless display and session specs

How results are placed in a real window, how an eval is routed by working
directory, `:SageFsHelp`, the first-run hint and the slow-eval status. They run
in a real headless Neovim with only the daemon transport stubbed (real
windows, real extmarks, real checkouts on disk, including a git worktree):

```bash
nvim --headless --clean -u NONE -l spec/nvim_display_harness.lua
```

The file is self-contained like `spec/nvim_harness.lua` and exits non-zero on a
failure. It is not named `*_spec.lua` so busted does not try to load it.

The pure pieces have busted specs: `spec/placement_spec.lua` (where a result is
drawn, with a seeded generator for the property that it is inside the window),
`spec/result_display_spec.lua`, `spec/pending_spec.lua`,
`spec/session_routing_spec.lua`, `spec/help_spec.lua`, `spec/cells_refine_spec.lua`.

## 2. nvim --headless (tree-sitter integration tests)

Tests requiring Neovim's tree-sitter runtime. Run with:

```bash
nvim --headless -l spec/treesitter_cells_spec.lua
```

These tests use a minimal self-contained harness (no busted dependency)
because they need `vim.treesitter`, `vim.api`, and the tree-sitter-fsharp
grammar, none of which are available in busted.

**Prerequisite:** tree-sitter-fsharp grammar must be installed in Neovim
(`TSInstall fsharp`).

The spec file includes a guard (`if not vim or not vim.opt then return end`)
so busted skips it without errors.

**Coverage:** Tree-sitter cell detection across the fixture files in `fixtures/`:
- `fixtures/basic_bindings.fs`: simple lets, records, DUs, match
- `fixtures/complex_expressions.fs`: multi-arm match, async CE, seq CE
- `fixtures/attributed_and_typed.fs`: attributes, let rec...and, interfaces
- `fixtures/nested_modules.fs`: namespace with nested modules
- `fixtures/type_with_members.fs`: `type...with` member workaround
- `fixtures/do_expressions.fs`: `do` expressions (common in .fsx)

## Fixture files

Fixture files in `fixtures/` are test data. **Do not edit without updating
`spec/treesitter_cells_spec.lua`** - tests assert specific line numbers.

## Known gaps

- **Transport integration:** No test starts a real curl process or connects
  to a mock SSE server. Transport behavior is tested via mocked callbacks.
- **tree-sitter-fsharp `with` members:** The grammar incorrectly parses
  `type Foo = { ... } with member ...` as separate nodes. We work around
  this in `treesitter_cells.lua` (see `extract_from_app_expr`).
