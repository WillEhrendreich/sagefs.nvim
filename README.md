# sagefs.nvim

Neovim frontend for [SageFs](https://github.com/WillEhrendreich/SageFs) — a live F# development server that eliminates the edit-build-run cycle. SageFs provides sub-second hot reload, live unit testing, IL coverage, an MCP server for AI agents, multi-session management, file watching, and more. This plugin connects Neovim to the running daemon, giving you cell evaluation with inline results, session management, hot reload controls, live test state, and SSE live updates from your editor.

## What is SageFs?

SageFs is a [.NET global tool](https://learn.microsoft.com/en-us/dotnet/core/tools/global-tools) that turns F# Interactive into a full development environment. Start the daemon once (`sagefs --proj YourApp.fsproj`), then connect from VS Code, Neovim, the terminal, a GPU-rendered GUI, a web dashboard, or all of them at once — they all share the same live session state.

**Key SageFs capabilities:**

- **Sub-second hot reload** — Save a `.fs` file and your running web server picks up the change in ~100ms. [Harmony](https://github.com/pardeike/Harmony) patches method pointers at runtime — no restart, no rebuild.
- **Live unit testing** — Edit code and affected tests run automatically in under 500ms. Gutter markers show pass/fail inline. Covers xUnit, NUnit, MSTest, TUnit, and Expecto. Configurable run policies per test category (unit tests on every keystroke, integration on save, browser on demand). Free — no VS Enterprise license needed.
- **IL coverage** — Line-level code coverage computed from instrumented test runs, streamed as SSE events.
- **Full project context in the REPL** — All NuGet packages, project references, and namespaces loaded automatically. No `#r` directives.
- **MCP server for AI agents** — AI tools (Copilot, Claude, etc.) can execute F# code, type-check, explore .NET APIs, run tests, and manage sessions against your real project via [Model Context Protocol](https://modelcontextprotocol.io/).
- **Multi-session isolation** — Run multiple FSI sessions simultaneously across different projects, each in an isolated worker sub-process.
- **Crash-proof supervisor** — Erlang-style auto-restart with exponential backoff.

See the [SageFs README](https://github.com/WillEhrendreich/SageFs) for full details.

## Plugin Status

This plugin provides the Neovim integration layer. **12 pure Lua modules, 469 tests, zero failures.**

### Implemented & Tested

| Feature | Description |
|---------|-------------|
| **Cell evaluation** | `;;` boundaries define cells. `<Alt-Enter>` evaluates the cell under cursor. |
| **Visual selection eval** | Select code in visual mode, `<Alt-Enter>` to evaluate. |
| **File evaluation** | Evaluate the entire buffer with `:SageFsEvalFile`. |
| **Inline results** | Success/error output as virtual text at the `;;` boundary. |
| **Virtual lines** | Multi-line output rendered below the `;;` boundary. |
| **Gutter signs** | Check/X/spinner indicators for cell state (success/error/running). |
| **CodeLens-style markers** | Eval virtual text above idle/stale cells. |
| **Stale detection** | Editing a cell marks its result as stale automatically. |
| **Flash animation** | Brief highlight flash when a cell begins evaluation. |
| **Session management** | Create, switch, stop sessions via picker (`:SageFsSessions`). |
| **Project discovery** | Auto-discovers `.fsproj` files and offers to create sessions. |
| **Smart eval** | If no session exists, prompts to create one before evaluating. |
| **Session context** | Floating window showing assemblies, namespaces, warmup details (`:SageFsContext`). |
| **Hot reload controls** | Per-file toggle, watch-all, unwatch-all via picker (`:SageFsHotReload`). |
| **SSE dispatch pipeline** | All 22 SageFs event types classified and routed through a dispatch table. |
| **SSE live updates** | Subscribes to SageFs event stream with auto-reconnect on disconnect. |
| **Live diagnostics** | F# errors/warnings streamed via SSE into `vim.diagnostic`. Consolidated pure pipeline. |
| **Live test state model** | Full testing state machine: test tracking, discovery, result batching, policy management. |
| **Test formatting** | Format test lists by file, filter by category/status, picker items, policy options. |
| **Test statusline** | `testing.format_statusline()` and `testing.format_pipeline_statusline()` for statusline. |
| **State recovery** | `build_recovery_request()` and `needs_recovery()` for SSE reconnect — no stale state. |
| **Coverage state model** | Line-level coverage tracking, file/total summaries, gutter signs, statusline formatting. |
| **Type explorer formatting** | Assembly → namespace → type → member drill-down formatting for pickers and floats. |
| **History formatting** | FSI event history formatted for picker display and floating window preview. |
| **Export to .fsx** | Format session history as executable F# script (user events only). |
| **User autocmd events** | 9 event types for scripting: `SageFsEvalCompleted`, `SageFsTestPassed`, etc. |
| **Treesitter cell detection** | Structural `;;` detection filtering out boundaries inside strings/comments. |
| **Hot reload model** | Pure URL builder, state management, picker formatting for hot reload controls. |
| **Code completion** | Omnifunc-based completions via SageFs completion endpoint. |
| **Session reset** | Soft reset (`:SageFsReset`) and hard reset with rebuild (`:SageFsHardReset`). |
| **Health check** | Connection status check (`:SageFsStatus`). |
| **Statusline component** | `SageFs.statusline()` shows session, project, eval count. |
| **Auto-connect** | Connects to the running daemon on startup. |

### Integration Wiring (Coming Next)

The pure modules above are fully tested and ready. The remaining work is wiring them into `init.lua` — creating the Neovim commands, keymaps, and extmark rendering that connect the pure logic to the editor:

| Feature | Pure Module | What Needs Wiring |
|---------|-------------|-------------------|
| **Live test gutter markers** | `testing.lua` — `gutter_sign()` | Extmarks from test state on `BufEnter`/SSE push |
| **Live test panel** | `testing.lua` — `format_test_list()` | `:SageFsTests` → floating window or quickfix |
| **Run tests** | `testing.lua` — `build_run_request()` | `:SageFsRunTests` → `vim.ui.select` → MCP call |
| **Run policy controls** | `testing.lua` — `format_policy_options()` | `:SageFsTestPolicy` → `vim.ui.select` → MCP call |
| **Toggle live testing** | `testing.lua` — SSE handler | `:SageFsToggleTesting` → MCP call |
| **Coverage gutter** | `coverage.lua` — `gutter_sign()` | `:SageFsCoverage` toggle → extmarks |
| **Coverage statusline** | `coverage.lua` — `format_statusline()` | Wire into statusline component |
| **Type explorer** | `type_explorer.lua` — formatters | `:SageFsExploreType` → drill-down `vim.ui.select` |
| **History search** | `history.lua` — `format_events()` | `:SageFsHistory` → picker → preview float |
| **Export .fsx** | `export.lua` — `format_fsx()` | `:SageFsExport` → new buffer |
| **User autocmds** | `events.lua` — `build_autocmd_data()` | Fire `vim.api.nvim_exec_autocmds` at event points |
| **Pipeline statusline** | `testing.lua` — `format_pipeline_statusline()` | Wire into statusline component |

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
| `<Alt-Enter>` | n | Evaluate cell under cursor (with smart session check) |
| `<Alt-Enter>` | v | Evaluate selection |
| `<leader>se` | n | Evaluate cell |
| `<leader>sc` | n | Clear all results |
| `<leader>ss` | n | Session picker |
| `<leader>sh` | n | Hot reload file picker |

## Commands

| Command | Description |
|---------|-------------|
| `:SageFsEval` | Evaluate current cell |
| `:SageFsEvalFile` | Evaluate entire file |
| `:SageFsClear` | Clear all extmarks |
| `:SageFsConnect` | Connect SSE stream |
| `:SageFsDisconnect` | Disconnect SSE stream |
| `:SageFsStatus` | Show connection status |
| `:SageFsSessions` | Session picker (create/switch/stop/reset) |
| `:SageFsCreateSession` | Discover projects and create session |
| `:SageFsHotReload` | Hot reload file picker |
| `:SageFsWatchAll` | Watch all project files for hot reload |
| `:SageFsUnwatchAll` | Unwatch all files |
| `:SageFsReset` | Soft reset active FSI session |
| `:SageFsHardReset` | Hard reset (rebuild) active FSI session |
| `:SageFsContext` | Show session context (assemblies, namespaces, warmup) |

## Architecture

Pure Lua modules (tested with [busted](https://lunarmodules.github.io/busted/) outside Neovim) + one integration layer:

| Module | Lines | Purpose |
|--------|-------|---------|
| `cells.lua` | ~190 | `;;` boundary detection, cell finding, treesitter boundary support |
| `format.lua` | ~170 | Result formatting with stale-awareness, `build_render_options` |
| `model.lua` | ~120 | Elmish state machine with validated transitions (idle→running→success/error→stale) |
| `sse.lua` | ~130 | SSE parser, event classification (22 types), dispatch table |
| `sessions.lua` | ~80 | Session response parsing, context-sensitive action filtering |
| `diagnostics.lua` | ~95 | Pure diagnostic grouping and vim.diagnostic conversion |
| `testing.lua` | ~580 | Live testing state model — test tracking, discovery, result batching, policy, formatting |
| `coverage.lua` | ~135 | Line-level coverage state, file/total summaries, gutter signs, statusline |
| `type_explorer.lua` | ~100 | Assembly/namespace/type/member formatting for pickers and floats |
| `history.lua` | ~70 | FSI event history formatting for picker and preview |
| `export.lua` | ~25 | Session export to .fsx format |
| `events.lua` | ~45 | User autocmd event definitions (9 event types) |
| `hotreload.lua` | ~150 | Hot reload file state and toggle API (vim-dependent) |
| `hotreload_model.lua` | ~65 | Pure hot reload URL builder, state, picker formatting |
| `init.lua` | ~1060 | Neovim integration (keymaps, extmarks, curl, autocmds) |

All modules except `init.lua` and `hotreload.lua` have zero vim API dependencies — they are pure functions testable under busted without a running Neovim instance.

### How it communicates with SageFs

- **POST `/exec`** — Send F# code for evaluation (via curl jobstart)
- **GET `/events`** — SSE stream for live updates (connection state, events)
- **GET `/diagnostics`** — SSE stream for F# diagnostics (errors, warnings)
- **`/api/sessions/*`** — Session management (list, create, switch, stop)
- **`/api/sessions/{id}/hotreload/*`** — Hot reload file management (toggle, watch-all, unwatch-all)
- **`/api/sessions/{id}/warmup-context`** — Session context (assemblies, namespaces)
- **POST `/dashboard/completions`** — Code completions at cursor position
- **POST `/reset`**, **POST `/hard-reset`** — Session reset endpoints

## Running Tests

```cmd
test.cmd                        # Run full suite (busted + integration)
busted spec/cells_spec.lua      # Run a single busted spec
busted --filter "find_cell"     # Filter by test name
nvim --headless --clean -u NONE -l spec/nvim_harness.lua  # Integration only
```

### Test architecture

| Suite | Runner | Count | What it covers |
|-------|--------|-------|----------------|
| **Busted (pure)** | `busted` via LuaRocks | 420 | Pure module logic — cells, format, model, SSE dispatch, sessions, testing, diagnostics, coverage, type explorer, history, export, events, hotreload model. State machine validation, property tests, snapshot tests, composition, idempotency. |
| **Integration** | Headless Neovim (`nvim -l`) | 49 | Real vim APIs — plugin setup, command registration, extmark rendering, highlight groups, keymaps, autocmds, cell lifecycle, SSE→model→extmark pipeline, multi-buffer isolation. |
| **Total** | | **469** | All passing, zero failures |

Requires [busted](https://lunarmodules.github.io/busted/) and `dkjson` via LuaRocks. Integration tests require Neovim 0.10+ on PATH.

## SageFs MCP Tools Reference

These are the MCP tools exposed by SageFs that AI agents (and potentially future plugin features) can use:

| Tool | Description |
|------|-------------|
| `send_fsharp_code` | Execute F# code (each `;;` is a transaction boundary) |
| `check_fsharp_code` | Type-check without executing |
| `get_completions` | Code completions at cursor position |
| `cancel_eval` | Cancel a running evaluation |
| `load_fsharp_script` | Load an `.fsx` file with partial progress |
| `get_recent_fsi_events` | Recent evals, errors, and loads with timestamps |
| `get_fsi_status` | Session health, loaded projects, statistics |
| `get_startup_info` | Projects, features, CLI arguments |
| `get_available_projects` | Discover `.fsproj`/`.sln`/`.slnx` in working directory |
| `explore_namespace` | Browse types and functions in a .NET namespace |
| `explore_type` | Browse members and properties of a .NET type |
| `get_elm_state` | Current UI render state |
| `reset_fsi_session` | Soft reset — clear definitions, keep DLL locks |
| `hard_reset_fsi_session` | Full reset — rebuild, reload, fresh session |
| `create_session` | Create a new isolated FSI session |
| `list_sessions` | List all active sessions |
| `stop_session` | Stop a session by ID |
| `switch_session` | Switch active session by ID |
| `get_live_test_status` | Query live test state (with optional file filter) |
| `toggle_live_testing` | Enable/disable live test pipeline |
| `set_run_policy` | Control when test categories auto-run (every/save/demand/disabled) |
| `get_pipeline_trace` | Debug the three-speed test pipeline |
| `run_tests` | Explicitly run tests with name/category filters |

## License

MIT