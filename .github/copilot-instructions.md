# Copilot Instructions — sagefs.nvim

Neovim plugin (pure Lua) that provides Jupyter-notebook-like F# development powered by [SageFs](https://github.com/WillEhrendreich/SageFs). Users write F# in `.fsx` files with `;;`-delimited cells and evaluate them with `<Alt-Enter>`, seeing results inline via extmarks.

## Build & Test

```bash
# Run all tests (busted via LuaRocks, Lua 5.1)
test.cmd

# Run a single spec file
busted spec/cells_spec.lua

# Run tests matching a pattern
busted --filter "find_cell"
```

Tests require `busted` and `dkjson` from LuaRocks. `test.cmd` sets `LUA_PATH`/`LUA_CPATH` for the local LuaRocks install.

## Architecture

**Pure modules + integration layer**: Four modules (`cells`, `format`, `model`, `sse`) plus `sessions` and `hotreload` are pure Lua with zero vim API dependencies. They are fully testable under busted outside Neovim. `init.lua` is the only module that touches `vim.*` APIs — it wires the pure modules to keymaps, extmarks, autocmds, and curl-based HTTP.

**Cell model**: `;;` at end of a line (outside strings/comments) defines a cell boundary. `cells.lua` handles boundary detection, cell finding by cursor position, and code preparation for submission.

**State machine**: Cell states flow `idle → running → success|error`. Buffer edits push `success|error → stale`. The model (`model.lua`) is a plain Lua table — no metatables, no OOP. All transitions are pure functions returning a new (mutated) table.

**Communication with SageFs**: HTTP via `curl` (jobstart). `POST /exec` sends code, `GET /events` is an SSE stream for live updates. Session management hits `/api/sessions/*`. Hot reload uses a separate dashboard port (default 37750).

## Conventions

- **Test structure**: Each spec file mirrors its source module (`cells_spec.lua` → `cells.lua`). Tests use `describe`/`it` blocks with busted's `assert` library. `spec/helper.lua` provides `vim.*` mocks so tests run outside Neovim.
- **No vim APIs in pure modules**: If a module lives under `lua/sagefs/` and isn't `init.lua` or `hotreload.lua`, it must not call `vim.api.*`, `vim.fn.*`, `vim.keymap.*`, etc. This is what makes them testable under busted.
- **JSON decoding pattern**: Pure modules use a `json_decode` helper that tries `vim.json.decode` first, then `vim.fn.json_decode`, to work in both Neovim and busted environments.
- **1-indexed lines**: All line numbers in the cell API are 1-indexed (matching Neovim convention). Conversion to 0-indexed happens only in `init.lua` when calling `nvim_buf_set_extmark`.
- **Config via `.busted`**: Test runner config lives in `.busted` (not a CLI flag). Pattern is `_spec`, root is `spec/`, helper is `spec/helper.lua`.

## MCP Servers

**Neovim MCP** — Use the `NeovimMCP` tools (`vim_buffer`, `vim_command`, `vim_edit`, etc.) for integration testing and debugging inside a live Neovim instance. This is useful for verifying extmark rendering, keymap behavior, command registration, and the full eval → extmark pipeline that can't be tested under busted alone. The pure module tests (busted) cover logic; Neovim MCP covers the `init.lua` integration layer.
