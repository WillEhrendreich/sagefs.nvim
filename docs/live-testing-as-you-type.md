# Live Testing — Neovim Plugin

Live testing in sagefs.nvim gives you pass/fail feedback in the gutter as you work, powered by SageFs's three-speed test pipeline. No manual test runs needed — results stream in via SSE and update inline.

## How It Works

SageFs's daemon runs a three-speed pipeline that detects, analyzes, and executes tests automatically:

1. **Tree-sitter detection** (~50ms) — Finds `[<Test>]`, `[<Fact>]`, `[<Property>]` attributes even in broken code
2. **F# Compiler Service analysis** (~350ms) — Builds a dependency graph to determine which tests are affected by your change
3. **Test execution** (~500ms) — Runs only the affected tests via the appropriate framework (Expecto, xUnit, NUnit, MSTest, TUnit)

The plugin receives results through the SSE event stream and renders them as gutter signs.

## Gutter Signs

Test results appear as signs in the sign column:

| Sign | Meaning |
|------|---------|
| `✓` (green) | Test passed |
| `✗` (red) | Test failed |
| `●` (yellow) | Test running |
| `◌` (dim) | Test discovered but not yet run |

Signs are placed at the line where the test attribute appears. They update in real-time as SSE events arrive.

## Commands

| Command | Description |
|---------|-------------|
| `:SageFsEnableTesting` | Enable the live testing pipeline |
| `:SageFsDisableTesting` | Disable the live testing pipeline |
| `:SageFsRunTests [pattern]` | Run tests manually, with optional name filter |
| `:SageFsTestPanel` | Toggle persistent test results split panel |
| `:SageFsTests` | Show test results in a floating window |
| `:SageFsTestsHere` | Show tests for the current file only |
| `:SageFsFailures` | Jump to failing tests |
| `:SageFsTestPolicy` | Configure run policies per test category |
| `:SageFsTestTrace` | Show the three-speed pipeline state |

## Test Panel

`:SageFsTestPanel` opens a persistent split showing all test results. Features:

- **Scope filters**: Press `b` (binding/treesitter scope), `f` (current file), `m` (module), `a` (all), or `Tab` to cycle
- **Failure-first sort**: Failing tests always appear at the top
- **Jump to source**: Press `<CR>` on a test to jump to its definition
- **Live updates**: Panel refreshes as SSE events arrive

## Run Policies

`:SageFsTestPolicy` lets you configure when each test category runs:

| Policy | Behavior |
|--------|----------|
| `every` | Run on every hot reload (keystroke-level) |
| `save` | Run only on file save |
| `demand` | Run only when explicitly triggered |
| `disabled` | Never run |

Categories: `unit`, `integration`, `browser`, `benchmark`, `architecture`, `property`.

Typical setup: unit tests on `every`, integration on `save`, browser on `demand`.

## SSE Events

The plugin handles these test-related SSE events:

| Event | Action |
|-------|--------|
| `test_summary` | Update overall test counts |
| `test_results_batch` | Update individual test pass/fail state and gutter signs |
| `test_trace` | Update the three-speed pipeline state display |
| `SageFsTestRunStarted` | Mark tests as running |
| `SageFsTestRunCompleted` | Finalize test run |
| `SageFsProvidersDetected` | Show which test frameworks are active |
| `SageFsAffectedTestsComputed` | Show dependency graph analysis results |
| `SageFsTestCycleTimingRecorded` | Record pipeline timing for the test trace |

## Coverage Integration

When live testing is enabled, FCS-based code coverage runs alongside tests. Coverage results appear as separate gutter signs (see [coverage documentation](./coverage.md) or the main README).

## Architecture

The testing subsystem spans several modules:

- **`testing.lua`** (~1200 lines) — Core testing state machine: SSE handlers, gutter sign management, panel formatting, policy configuration, pipeline state, annotation integration
- **`test_trace.lua`** (~65 lines) — Test trace parsing and formatting for the three-speed pipeline display
- **`annotations.lua`** (~240 lines) — Coverage annotation formatting, branch coverage signs, CodeLens-style markers, inline failure display
- **`events.lua`** — Defines 10+ test-related User autocmd events for scripting integration

All test modules are pure Lua with zero vim API dependencies — they're fully testable under busted without Neovim.
