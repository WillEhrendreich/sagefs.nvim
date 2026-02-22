# sagefs.nvim

Jupyter-notebook-like F# development in Neovim, powered by [SageFs](https://github.com/WillEhrendreich/SageFs).

Write F# in plain `.fsx` files with `;;`-delimited cells. Press `<Alt-Enter>` to evaluate — results appear inline via extmarks.

## Features

- **Cell evaluation** — `;;` boundaries define cells (like Jupyter). `<Alt-Enter>` evaluates the cell under your cursor.
- **Inline results** — Success/error output shown as virtual text at the `;;` boundary.
- **Virtual lines** — Multi-line output rendered below the cell.
- **Gutter signs** — ✓/✗/⟳ indicators for cell state.
- **SSE live updates** — Subscribe to SageFs event stream for real-time feedback.
- **Stale detection** — Editing a cell marks its result as stale automatically.

## Requirements

- [SageFs](https://github.com/WillEhrendreich/SageFs) running with MCP server (default port 37749)
- Neovim 0.10+
- `curl` on PATH

## Installation

### lazy.nvim

```lua
{
  "WillEhrendreich/sagefs.nvim",
  ft = { "fsharp" },
  opts = {
    port = 37749,
    auto_connect = true,
  },
}
```

### Local development

```lua
{
  "WillEhrendreich/sagefs.nvim",
  dev = true,
  dir = "C:/Code/Repos/sagefs.nvim",
  ft = { "fsharp" },
  opts = {
    port = 37749,
    auto_connect = true,
  },
}
```

## Keymaps

| Key | Mode | Description |
|-----|------|-------------|
| `<Alt-Enter>` | n | Evaluate cell under cursor |
| `<Alt-Enter>` | v | Evaluate selection |
| `<leader>se` | n | Evaluate cell |
| `<leader>sc` | n | Clear all results |
| `<leader>ss` | n | Health check |

## Commands

| Command | Description |
|---------|-------------|
| `:SageFsEval` | Evaluate current cell |
| `:SageFsClear` | Clear all extmarks |
| `:SageFsConnect` | Connect SSE stream |
| `:SageFsDisconnect` | Disconnect SSE stream |
| `:SageFsStatus` | Show connection status |

## Architecture

Four pure Lua modules (tested with [busted](https://lunarmodules.github.io/busted/)) + one Neovim integration layer:

| Module | Purpose | Tests |
|--------|---------|-------|
| `cells.lua` | `;;` boundary detection, cell finding | 46 |
| `format.lua` | Result formatting for extmarks | 24 |
| `sse.lua` | SSE event stream parser | 10 |
| `model.lua` | Cell state machine | 17 |
| `init.lua` | Neovim integration (keymaps, extmarks, curl) | — |

## Running Tests

```cmd
cd sagefs.nvim
test.cmd
```

Requires [busted](https://lunarmodules.github.io/busted/) via LuaRocks.

## License

MIT
