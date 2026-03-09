# sagefs.nvim Documentation

Developer documentation for the sagefs.nvim Neovim plugin — the Neovim frontend for [SageFs](https://github.com/WillEhrendreich/SageFs).

## Guides

| Document | Description |
|----------|-------------|
| [Live Testing](./live-testing-as-you-type.md) | How live testing works: three-speed pipeline, gutter signs, test panel, run policies, SSE events |

## Quick Links

- **[Main README](../README.md)** — Full feature table, installation, keymaps, commands, architecture, MCP tools reference
- **[Vim Help](../doc/sagefs.txt)** — `:help sagefs` documentation with command/config reference
- **[Screenshots](./screenshots/)** — Visual tour of all major features

## Architecture Overview

sagefs.nvim is structured as **37 pure Lua modules** (zero vim API dependencies) plus an integration layer:

```
lua/sagefs/
├── Pure modules (testable under busted without Neovim)
│   ├── cells.lua          — ;; boundary detection and cell finding
│   ├── model.lua          — Elmish state machine (idle→running→success/error→stale)
│   ├── format.lua         — Result formatting and render option building
│   ├── sse.lua            — SSE parser, event classification, dispatch table
│   ├── testing.lua        — Live testing state, gutter signs, panel, policies
│   ├── coverage.lua       — Line-level coverage state and summaries
│   ├── annotations.lua    — Coverage annotations, branch signs, CodeLens, inline failures
│   ├── diagnostics.lua    — Diagnostic grouping and vim.diagnostic conversion
│   ├── sessions.lua       — Session response parsing and action filtering
│   ├── type_explorer.lua  — Assembly/namespace/type/member formatting
│   ├── depgraph.lua       — Cross-cell dependency graph
│   ├── depgraph_viz.lua   — ASCII arrow rendering for dependency visualization
│   ├── timeline.lua       — Eval timeline and flame-chart formatting
│   ├── time_travel.lua    — Cell history with snapshot management
│   ├── scope_map.lua      — Binding scope map per cell
│   ├── type_flow.lua      — Cross-cell type propagation analysis
│   ├── notebook.lua       — Literate notebook export (markdown + fsx)
│   ├── diff.lua           — Semantic diff between evaluations
│   ├── density.lua        — Display density presets (minimal/normal/full)
│   ├── cell_highlight.lua — Dynamic eval region visuals (4 styles)
│   ├── daemon.lua         — Daemon lifecycle state machine
│   ├── events.lua         — 28 User autocmd event definitions
│   ├── health.lua         — :checkhealth sagefs validation
│   └── ...more pure modules
│
├── Integration layer (requires Neovim APIs)
│   ├── init.lua           — Coordinator: SSE dispatch, eval, session API
│   ├── commands.lua       — 46 commands, keymaps, autocmds
│   ├── transport.lua      — HTTP via curl, SSE with exponential backoff
│   ├── render.lua         — Extmarks, gutter signs, floating windows
│   └── hotreload.lua      — Hot reload file toggle API
│
└── version.lua            — Plugin version (synced from SageFs)
```

## Communication Protocol

The plugin communicates with the SageFs daemon over two ports:

- **Port 37749** (main) — HTTP POST for commands (`/exec`, `/reset`, etc.) + SSE stream (`/events`) for live updates
- **Port 37750** (dashboard) — Code completions, callers/callees, hot reload

All state flows from daemon to plugin via SSE. POST responses carry only acknowledgment — results always arrive through the event stream.

## Testing

| Suite | Runner | Count | Description |
|-------|--------|-------|-------------|
| Busted | `busted` (LuaRocks) | 1107 | Pure module logic — state machines, parsing, formatting |
| Integration | Headless Neovim (`nvim -l`) | 53 | Real vim APIs — commands, extmarks, keymaps |
| E2E | Neovim + real SageFs | 27 | Full daemon lifecycle — eval, SSE, sessions, testing |

Run with:
```cmd
test.cmd                          # Busted + integration
test_e2e.cmd                      # E2E (requires running SageFs)
busted spec/cells_spec.lua        # Single spec file
busted --filter "find_cell"       # Filter by test name
```
