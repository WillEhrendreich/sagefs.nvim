# sagefs.nvim

Neovim frontend for [SageFs](https://github.com/WillEhrendreich/SageFs) — a live F# development server that eliminates the edit-build-run cycle. SageFs provides sub-second hot reload, an MCP server for AI agents, multi-session management, file watching, and more. This plugin connects Neovim to the running daemon, giving you access to all of that from your editor.

## Features

- **Cell evaluation** — `;;` boundaries define cells. `<Alt-Enter>` evaluates the cell under your cursor; results appear inline via extmarks.
- **Inline results & virtual lines** — Success/error output as virtual text at the `;;` boundary, with multi-line output rendered below.
- **Gutter signs** — ✓/✗/⟳ indicators for cell state.
- **Session management** — Create, switch, and stop SageFs sessions from Neovim. Auto-detects the session for your working directory.
- **Hot reload controls** — Toggle file watching per-file or bulk watch/unwatch through a picker UI.
- **SSE live updates** — Subscribes to SageFs's event stream for real-time feedback with auto-reconnect.
- **Stale detection** — Editing a cell marks its result as stale automatically.
- **Statusline component** — Shows active session, project, and eval count via `SageFs.statusline()`.

## Requirements

- [SageFs](https://github.com/WillEhrendreich/SageFs) running (`sagefs --proj YourApp.fsproj`)
- Neovim 0.10+
- `curl` on PATH

## Installation

### lazy.nvim

```lua
{
  "WillEhrendreich/sagefs.nvim",
  ft = { "fsharp" },
  opts = {
    port = 37749,          -- MCP server port
    dashboard_port = 37750, -- Dashboard/hot-reload port
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
    dashboard_port = 37750,
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
| `<leader>ss` | n | Session picker |
| `<leader>sh` | n | Hot reload file picker |

## Commands

| Command | Description |
|---------|-------------|
| `:SageFsEval` | Evaluate current cell |
| `:SageFsClear` | Clear all extmarks |
| `:SageFsConnect` | Connect SSE stream |
| `:SageFsDisconnect` | Disconnect SSE stream |
| `:SageFsStatus` | Show connection status |
| `:SageFsSessions` | Session picker (create/switch/stop) |
| `:SageFsCreateSession` | Discover projects and create session |
| `:SageFsHotReload` | Hot reload file picker |
| `:SageFsWatchAll` | Watch all project files for hot reload |
| `:SageFsUnwatchAll` | Unwatch all files |

## Architecture

Pure Lua modules (tested with [busted](https://lunarmodules.github.io/busted/) outside Neovim) + one integration layer:

| Module | Purpose |
|--------|---------|
| `cells.lua` | `;;` boundary detection, cell finding |
| `format.lua` | Result formatting for extmarks |
| `model.lua` | Cell state machine (idle → running → success/error → stale) |
| `sse.lua` | SSE event stream parser |
| `sessions.lua` | Session response parsing, directory matching, formatting |
| `hotreload.lua` | Hot reload file state and toggle API |
| `init.lua` | Neovim integration (keymaps, extmarks, curl, autocmds) |

All modules except `init.lua` and `hotreload.lua` have zero vim API dependencies — they are pure functions testable under busted without a running Neovim instance.

## Running Tests

```cmd
test.cmd              # Run full suite
busted spec/cells_spec.lua  # Run a single spec
busted --filter "find_cell" # Filter by test name
```

Requires [busted](https://lunarmodules.github.io/busted/) and `dkjson` via LuaRocks.

## License

MIT
