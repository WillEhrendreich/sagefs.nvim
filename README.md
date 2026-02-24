# sagefs.nvim

Neovim frontend for [SageFs](https://github.com/WillEhrendreich/SageFs) — a live F# development server that eliminates the edit-build-run cycle. SageFs provides sub-second hot reload, live unit testing with a three-speed pipeline, FCS-based code coverage, an affordance-driven MCP server for AI agents, multi-session management, file watching, and more. This plugin connects Neovim to the running daemon, giving you cell evaluation with inline results, session management, hot reload controls, live test state, coverage gutter signs, and SSE live updates from your editor.

## What is SageFs?

SageFs is a [.NET global tool](https://learn.microsoft.com/en-us/dotnet/core/tools/global-tools) that turns F# Interactive into a full development environment. Start the daemon once (`sagefs --proj YourApp.fsproj`), then connect from VS Code, Neovim, the terminal, a GPU-rendered GUI, a web dashboard, or all of them at once — they all share the same live session state.

**Key SageFs capabilities:**

- **Sub-second hot reload** — Save a `.fs` file and your running web server picks up the change in ~100ms. [Harmony](https://github.com/pardeike/Harmony) patches method pointers at runtime — no restart, no rebuild. Browsers auto-refresh via SSE.
- **Live unit testing** — A three-speed pipeline: tree-sitter detects tests in ~50ms (even in broken code), F# Compiler Service type-checks and builds a dependency graph in ~350ms, then affected tests execute in ~500ms total. Gutter markers show pass/fail inline. Covers xUnit, NUnit, MSTest, TUnit, and Expecto via a two-tier provider system. Configurable run policies per test category (unit tests on every keystroke, integration on save, browser on demand). Free — no VS Enterprise license needed.
- **FCS-based coverage** — Line-level code coverage computed from F# Compiler Service typed AST symbol graph (lightweight, no IL instrumentation), streamed as SSE events with per-file and per-line annotations.
- **Full project context in the REPL** — All NuGet packages, project references, and namespaces loaded automatically. No `#r` directives.
- **Affordance-driven MCP** — AI tools (Copilot, Claude, etc.) can execute F# code, type-check, explore .NET APIs, run tests, and manage sessions against your real project via [Model Context Protocol](https://modelcontextprotocol.io/). The MCP server only presents tools valid for the current session state — agents see `get_fsi_status` during warmup, then `send_fsharp_code` once ready. No wasted tokens from guessing.
- **Multi-session isolation** — Run multiple FSI sessions simultaneously across different projects, each in an isolated worker sub-process. A standby pool of pre-warmed sessions makes hard resets near-instant.
- **Crash-proof supervisor** — Erlang-style auto-restart with exponential backoff (`sagefs --supervised`). Watchdog state exposed via API and shown in editor status bars.
- **Event sourcing** — All session events (evals, resets, diagnostics, errors) stored in PostgreSQL via [Marten](https://martendb.io/) for history replay and analytics.

See the [SageFs README](https://github.com/WillEhrendreich/SageFs) for full details, including CLI reference, per-directory config (`.SageFs/config.fsx`), startup profiles, and the full [frontend feature matrix](https://github.com/WillEhrendreich/SageFs#frontend-feature-matrix).

## Plugin Status

This plugin provides the Neovim integration layer. **18 Lua modules, 637 tests, zero failures.**

### Fully Implemented & Tested

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
| **Session context** | Floating window showing assemblies, namespaces, warmup details. |
| **Hot reload controls** | Per-file toggle, watch-all, unwatch-all via picker. |
| **SSE dispatch pipeline** | All 22 SageFs event types classified and routed through dispatch. |
| **SSE live updates** | Subscribes to SageFs event stream with auto-reconnect. |
| **State recovery** | Full test state synced on SSE reconnect — no stale data after drops. |
| **Live diagnostics** | F# errors/warnings streamed via SSE into `vim.diagnostic`. |
| **Live test gutter signs** | Pass/fail/running/stale signs per test in the sign column. |
| **Live test panel** | `:SageFsTests` → floating window with test results grouped by file. |
| **Run tests** | `:SageFsRunTests [pattern]` → trigger test execution with optional filter. |
| **Test policy controls** | `:SageFsTestPolicy` → drill-down `vim.ui.select` for category+policy. |
| **Toggle live testing** | `:SageFsToggleTesting` → enable/disable live test pipeline. |
| **Coverage gutter signs** | Green=covered, Red=uncovered per-line signs from FCS symbol graph. |
| **Coverage panel** | `:SageFsCoverage` → floating window with per-file breakdown + total. |
| **Coverage statusline** | Coverage percentage in combined statusline component. |
| **Type explorer** | `:SageFsTypeExplorer` → assembly→namespace→type→members drill-down. |
| **History browser** | `:SageFsHistory` → picker with preview of past evaluations. |
| **Export to .fsx** | `:SageFsExport` → export session history as executable F# script. |
| **Call graph** | `:SageFsCallers`/`:SageFsCallees` → floating window with call graph. |
| **User autocmd events** | 9 event types fired via `User` autocmds for scripting integration. |
| **Combined statusline** | `require("sagefs").statusline()` → session │ testing │ coverage. |
| **Code completion** | Omnifunc-based completions via SageFs completion endpoint. |
| **Session reset** | Soft reset and hard reset with rebuild. |
| **Treesitter cell detection** | Structural `;;` detection filtering boundaries in strings/comments. |

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
| `:SageFsTests` | Show live test results panel |
| `:SageFsRunTests [pattern]` | Run tests (optional name filter) |
| `:SageFsTestPolicy` | Configure test run policies per category |
| `:SageFsToggleTesting` | Toggle live testing on/off |
| `:SageFsCoverage` | Show coverage summary with per-file breakdown |
| `:SageFsTypeExplorer` | Browse assemblies → namespaces → types → members |
| `:SageFsHistory` | Browse FSI eval history with preview |
| `:SageFsExport` | Export session history as `.fsx` file |
| `:SageFsCallers <symbol>` | Show callers of a symbol |
| `:SageFsCallees <symbol>` | Show callees of a symbol |

## Architecture

Pure Lua modules (tested with [busted](https://lunarmodules.github.io/busted/) outside Neovim) + a thin integration layer:

| Module | Lines | Purpose |
|--------|-------|---------|
| `cells.lua` | ~190 | `;;` boundary detection, cell finding, treesitter boundary support |
| `format.lua` | ~170 | Result formatting with stale-awareness, `build_render_options` |
| `model.lua` | ~120 | Elmish state machine with validated transitions (idle→running→success/error→stale) |
| `sse.lua` | ~130 | SSE parser, event classification (22 types), dispatch table |
| `sessions.lua` | ~80 | Session response parsing, context-sensitive action filtering |
| `diagnostics.lua` | ~95 | Pure diagnostic grouping and vim.diagnostic conversion |
| `testing.lua` | ~650 | Live testing state model — SSE handlers, gutter signs, formatting, policies |
| `coverage.lua` | ~135 | Line-level coverage state, file/total summaries, gutter signs, statusline |
| `type_explorer.lua` | ~100 | Assembly/namespace/type/member formatting for pickers and floats |
| `history.lua` | ~70 | FSI event history formatting for picker and preview |
| `export.lua` | ~25 | Session export to .fsx format |
| `events.lua` | ~45 | User autocmd event definitions (9 event types) |
| `hotreload_model.lua` | ~65 | Pure hot reload URL builder, state, picker formatting |
| **Integration layer** | | |
| `init.lua` | ~600 | Thin coordinator: SSE dispatch, eval, session API |
| `transport.lua` | ~100 | HTTP via curl, SSE connections with auto-reconnect |
| `render.lua` | ~215 | Extmarks, test/coverage gutter signs, floating windows |
| `commands.lua` | ~440 | All 24 commands, keymaps, autocmds |
| `hotreload.lua` | ~115 | Hot reload file toggle API |

All pure modules have zero vim API dependencies — they are testable under busted without a running Neovim instance.

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
| **Busted (pure)** | `busted` via LuaRocks | 585 | Pure module logic — cells, format, model, SSE dispatch, sessions, testing, diagnostics, coverage, type explorer, history, export, events, hotreload model. State machine validation, property tests, snapshot tests, composition, idempotency. |
| **Integration** | Headless Neovim (`nvim -l`) | 52 | Real vim APIs — plugin setup, 24 command registration, extmark rendering, highlight groups, keymaps, autocmds, cell lifecycle, SSE→model→extmark pipeline, multi-buffer isolation, test gutter signs, coverage gutter signs, combined statusline. |
| **Total** | | **637** | All passing, zero failures |

Requires [busted](https://lunarmodules.github.io/busted/) and `dkjson` via LuaRocks. Integration tests require Neovim 0.10+ on PATH.

## SageFs MCP Tools Reference

These are the MCP tools exposed by SageFs. The server uses **affordance-driven tool exposure** — only tools valid for the current session state are presented. During warmup you see `get_fsi_status`; once ready, the full tool set appears.

| Tool | Description |
|------|-------------|
| `send_fsharp_code` | Execute F# code (each `;;` is a transaction — failures are isolated) |
| `check_fsharp_code` | Type-check without executing (pre-validate before committing) |
| `get_completions` | Code completions at cursor position |
| `cancel_eval` | Cancel a running evaluation (recover from infinite loops) |
| `load_fsharp_script` | Load an `.fsx` file with partial progress |
| `get_recent_fsi_events` | Recent evals, errors, and loads with timestamps |
| `get_fsi_status` | Session health, loaded projects, statistics, affordances |
| `get_startup_info` | Projects, features, CLI arguments |
| `get_available_projects` | Discover `.fsproj`/`.sln`/`.slnx` in working directory |
| `explore_namespace` | Browse types and functions in a .NET namespace |
| `explore_type` | Browse members and properties of a .NET type |
| `get_elm_state` | Current UI render state (editor, output, diagnostics) |
| `reset_fsi_session` | Soft reset — clear definitions, keep DLL locks |
| `hard_reset_fsi_session` | Full reset — rebuild, reload, fresh session |
| `create_session` | Create a new isolated FSI session |
| `list_sessions` | List all active sessions |
| `stop_session` | Stop a session by ID |
| `switch_session` | Switch active session by ID |
| `get_live_test_status` | Query live test state (with optional file filter) |
| `toggle_live_testing` | Enable/disable live test pipeline |
| `set_run_policy` | Control when test categories auto-run (every/save/demand/disabled) |
| `get_pipeline_trace` | Debug the three-speed test pipeline waterfall |
| `run_tests` | Run tests on demand with name/category filters |

## License

MIT