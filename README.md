# sagefs.nvim

Neovim frontend for [SageFs](https://github.com/WillEhrendreich/SageFs) — a live F# development server that eliminates the edit-build-run cycle. SageFs provides sub-second hot reload, live unit testing, an MCP server for AI agents, multi-session management, file watching, and more. This plugin connects Neovim to the running daemon, giving you cell evaluation with inline results, session management, hot reload controls, and SSE live updates from your editor.

## What is SageFs?

SageFs is a [.NET global tool](https://learn.microsoft.com/en-us/dotnet/core/tools/global-tools) that turns F# Interactive into a full development environment. Start the daemon once (`sagefs --proj YourApp.fsproj`), then connect from VS Code, Neovim, the terminal, a GPU-rendered GUI, a web dashboard, or all of them at once — they all share the same live session state.

**Key SageFs capabilities:**

- **Sub-second hot reload** — Save a `.fs` file and your running web server picks up the change in ~100ms. [Harmony](https://github.com/pardeike/Harmony) patches method pointers at runtime — no restart, no rebuild.
- **Live unit testing** — Edit code and affected tests run automatically in under 500ms. Gutter markers show pass/fail inline. Covers xUnit, NUnit, MSTest, TUnit, and Expecto. Configurable run policies per test category (unit tests on every keystroke, integration on save, browser on demand). Free — no VS Enterprise license needed.
- **Full project context in the REPL** — All NuGet packages, project references, and namespaces loaded automatically. No `#r` directives.
- **MCP server for AI agents** — AI tools (Copilot, Claude, etc.) can execute F# code, type-check, explore .NET APIs, run tests, and manage sessions against your real project via [Model Context Protocol](https://modelcontextprotocol.io/).
- **Multi-session isolation** — Run multiple FSI sessions simultaneously across different projects, each in an isolated worker sub-process.
- **Crash-proof supervisor** — Erlang-style auto-restart with exponential backoff.

See the [SageFs README](https://github.com/WillEhrendreich/SageFs) for full details.

## Plugin Status

This plugin provides the Neovim integration layer. Here is what is implemented and tested vs what is coming:

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
| **SSE live updates** | Subscribes to SageFs event stream with auto-reconnect on disconnect. |
| **Live diagnostics** | F# errors/warnings streamed via SSE into `vim.diagnostic`. |
| **Code completion** | Omnifunc-based completions via SageFs completion endpoint. |
| **Session reset** | Soft reset (`:SageFsReset`) and hard reset with rebuild (`:SageFsHardReset`). |
| **Health check** | Connection status check (`:SageFsStatus`). |
| **Statusline component** | `SageFs.statusline()` shows session, project, eval count. |
| **Auto-connect** | Connects to the running daemon on startup. |

### Not Yet Implemented

| Feature | SageFs Support | Plugin Status |
|---------|---------------|---------------|
| **Live test gutter markers** | Full pipeline: discovery, execution, SSE push of results | Not yet — needs extmark signs for test pass/fail/pending indicators |
| **Live test status panel** | `get_live_test_status` MCP tool with file filtering | Not yet — could show in floating window or quickfix |
| **Run policy controls** | `set_run_policy` MCP tool (per-category: every/save/demand/disabled) | Not yet — needs UI for toggling policies |
| **Toggle live testing** | `toggle_live_testing` MCP tool | Not yet — needs command/keymap |
| **Pipeline trace** | `get_pipeline_trace` MCP tool (debug the three-speed pipeline) | Not yet |
| **Explicit test runner** | `run_tests` MCP tool with name/category filters | Not yet |
| **Coverage annotations** | `CoverageAnnotation` types with line-level data | Not yet — needs extmark rendering for covered/uncovered lines |
| **Rich picker UI** | n/a | Pickers use `vim.ui.select` — snacks.nvim / fzf-lua integration planned |

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

| Module | Purpose |
|--------|---------|
| `cells.lua` | `;;` boundary detection, cell finding |
| `format.lua` | Result formatting for extmarks |
| `model.lua` | Cell state machine (idle -> running -> success/error -> stale) |
| `sse.lua` | SSE event stream parser |
| `sessions.lua` | Session response parsing, directory matching, formatting |
| `hotreload.lua` | Hot reload file state and toggle API |
| `init.lua` | Neovim integration (keymaps, extmarks, curl, autocmds) |

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
test.cmd              # Run full suite
busted spec/cells_spec.lua  # Run a single spec
busted --filter "find_cell" # Filter by test name
```

Requires [busted](https://lunarmodules.github.io/busted/) and `dkjson` via LuaRocks.

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