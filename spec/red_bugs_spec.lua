-- RED tests for bugs and design flaws found in plan-vs-reality analysis
-- Each test documents a specific defect and will FAIL until the fix is applied.
-- Organized by severity: bugs first, then missing validation, then design gaps.

require("spec.helper")
local model = require("sagefs.model")
local format = require("sagefs.format")
local sessions = require("sagefs.sessions")
local sse = require("sagefs.sse")

-- =============================================================================
-- BUG: Stale cells get success formatting (init.lua line 82)
-- =============================================================================
-- render_cell_result builds: ok = cell.status == "success" or cell.status == "stale"
-- This means stale cells are passed to format_inline with ok=true, getting
-- SageFsSuccess highlight instead of SageFsStale. The gutter sign is correct
-- (format.gutter_sign handles "stale"), but inline text is wrong.
--
-- The fix needs a dedicated rendering path for stale — either a separate
-- format function or a third state in the result table ({stale=true}).
-- These tests define what correct stale rendering looks like.

describe("BUG: stale cell rendering [RED]", function()
  -- format.lua currently only takes {ok, output, error}. There's no way to
  -- express "stale" through this interface. We need format.format_inline to
  -- accept a status or a stale flag.

  it("format_inline for stale uses SageFsStale highlight, not SageFsSuccess", function()
    -- Option A: format_inline accepts a status parameter
    -- Option B: format_inline accepts {ok, output, error, stale}
    -- Either way, stale must NOT produce SageFsSuccess
    local result = format.format_inline({
      ok = true,
      output = "val it: int = 42",
      stale = true,
    })
    assert.are.equal("SageFsStale", result.hl)
  end)

  it("format_inline for stale uses a dim/faded prefix, not → ", function()
    local result = format.format_inline({
      ok = true,
      output = "val it: int = 42",
      stale = true,
    })
    -- Stale output should use a different prefix to visually distinguish
    -- from fresh success. e.g. "⊘ " or "~ " instead of "→ "
    assert.is_not_nil(result.text)
    -- Must NOT start with the success prefix
    assert.is_falsy(result.text:match("^→ "))
  end)

  it("format_virtual_lines for stale uses SageFsStale highlight", function()
    local lines = format.format_virtual_lines({
      ok = true,
      output = "val it: int = 42",
      stale = true,
    })
    assert.is_true(#lines > 0)
    assert.are.equal("SageFsStale", lines[1].hl)
  end)

  it("gutter_sign for stale is already correct (sanity check)", function()
    -- This should PASS — gutter_sign already handles "stale" correctly.
    -- Included as a GREEN anchor proving the gutter is fine, the inline is the bug.
    local sign = format.gutter_sign("stale")
    assert.are.equal("~", sign.text)
    assert.are.equal("SageFsStale", sign.hl)
  end)
end)

-- =============================================================================
-- BUG: render_cell_result skips stale cells entirely for inline/vlines
-- =============================================================================
-- init.lua lines 80 and 107 both check:
--   if cell.status == "success" or cell.status == "error" then
-- A stale cell passes the first check (because of the line 82 bug), but
-- the virtual lines check on line 107 uses `ok = cell.status == "success"`
-- which is false for stale. So stale cells show SUCCESS inline text
-- with ERROR virtual lines. This is doubly wrong.

describe("BUG: stale rendering consistency [RED]", function()
  it("stale cell should still show its preserved output inline", function()
    -- A cell that was success with output "42", then marked stale,
    -- should show the old output with stale styling, not disappear.
    -- This requires render_cell_result to handle stale as a distinct case.
    --
    -- We test this by checking format_inline handles {stale=true, ok=true}
    -- and still produces text containing the output value.
    local result = format.format_inline({
      ok = true,
      output = "val it: int = 42",
      stale = true,
    })
    assert.is_truthy(result.text:find("42"))
    assert.are.equal("SageFsStale", result.hl)
  end)

  it("stale cell virtual lines use SageFsStale, not SageFsOutput", function()
    local lines = format.format_virtual_lines({
      ok = true,
      output = "line1\nline2\nline3",
      stale = true,
    })
    for _, line in ipairs(lines) do
      assert.are.equal("SageFsStale", line.hl)
    end
  end)
end)

-- =============================================================================
-- MISSING: model.lua accepts any string as status (no validation)
-- =============================================================================
-- testing.lua validates statuses with VALID_TEST_STATUSES. model.lua does not.
-- You can set_cell_state(m, 1, "banana") and it silently succeeds.
-- You can set_status(m, "quantum_superposition") and it works.

describe("model status validation [RED]", function()
  it("set_cell_state rejects invalid status strings", function()
    local m = model.new()
    local ok, err = pcall(model.set_cell_state, m, 1, "banana")
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("invalid"))
  end)

  it("set_cell_state rejects empty string status", function()
    local m = model.new()
    local ok, err = pcall(model.set_cell_state, m, 1, "")
    assert.is_false(ok)
  end)

  it("set_cell_state rejects nil status", function()
    local m = model.new()
    local ok, err = pcall(model.set_cell_state, m, 1, nil)
    assert.is_false(ok)
  end)

  it("set_cell_state accepts all valid statuses", function()
    local m = model.new()
    -- Valid transitions: idle→running, running→success, running→error
    m = model.set_cell_state(m, 1, "running")
    assert.are.equal("running", model.get_cell_state(m, 1).status)
    m = model.set_cell_state(m, 1, "success", "ok")
    assert.are.equal("success", model.get_cell_state(m, 1).status)
    -- stale via mark_stale
    m = model.mark_stale(m, 1)
    assert.are.equal("stale", model.get_cell_state(m, 1).status)
    -- stale→running
    m = model.set_cell_state(m, 1, "running")
    m = model.set_cell_state(m, 1, "error", "err")
    assert.are.equal("error", model.get_cell_state(m, 1).status)
  end)

  it("set_status rejects invalid connection status", function()
    local m = model.new()
    local ok, err = pcall(model.set_status, m, "quantum_superposition")
    assert.is_false(ok)
  end)

  it("set_status accepts all valid connection statuses", function()
    local m = model.new()
    local valid = { "connected", "disconnected", "reconnecting" }
    for _, status in ipairs(valid) do
      m = model.set_status(m, status)
      assert.are.equal(status, m.status)
    end
  end)

  it("model exposes VALID_CELL_STATUSES set", function()
    assert.is_table(model.VALID_CELL_STATUSES)
    assert.is_true(model.VALID_CELL_STATUSES["idle"])
    assert.is_true(model.VALID_CELL_STATUSES["running"])
    assert.is_true(model.VALID_CELL_STATUSES["success"])
    assert.is_true(model.VALID_CELL_STATUSES["error"])
    assert.is_true(model.VALID_CELL_STATUSES["stale"])
    assert.is_nil(model.VALID_CELL_STATUSES["banana"])
  end)

  it("model exposes VALID_CONNECTION_STATUSES set", function()
    assert.is_table(model.VALID_CONNECTION_STATUSES)
    assert.is_true(model.VALID_CONNECTION_STATUSES["connected"])
    assert.is_true(model.VALID_CONNECTION_STATUSES["disconnected"])
    assert.is_true(model.VALID_CONNECTION_STATUSES["reconnecting"])
  end)
end)

-- =============================================================================
-- MISSING: model.lua state machine transition validation
-- =============================================================================
-- Wlaschin's principle: make illegal states unrepresentable.
-- Currently you can go idle→stale, stale→stale, running→idle.
-- Valid transitions should be:
--   idle → running (eval started)
--   running → success|error (eval completed)
--   success|error → stale (code changed)
--   stale → running (re-eval)
--   any → idle (clear_cells)

describe("model state machine transitions [RED]", function()
  it("rejects idle → stale transition", function()
    local m = model.new()
    -- Cell starts as idle. Setting to stale should be rejected — you can't
    -- mark something stale that was never evaluated.
    local ok, _ = pcall(model.set_cell_state, m, 1, "stale")
    assert.is_false(ok)
  end)

  it("rejects idle → success transition (must go through running)", function()
    local m = model.new()
    local ok, _ = pcall(model.set_cell_state, m, 1, "success", "42")
    assert.is_false(ok)
  end)

  it("rejects idle → error transition (must go through running)", function()
    local m = model.new()
    local ok, _ = pcall(model.set_cell_state, m, 1, "error", "oops")
    assert.is_false(ok)
  end)

  it("allows idle → running", function()
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    assert.are.equal("running", model.get_cell_state(m, 1).status)
  end)

  it("allows running → success", function()
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    m = model.set_cell_state(m, 1, "success", "42")
    assert.are.equal("success", model.get_cell_state(m, 1).status)
  end)

  it("allows running → error", function()
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    m = model.set_cell_state(m, 1, "error", "oops")
    assert.are.equal("error", model.get_cell_state(m, 1).status)
  end)

  it("allows stale → running (re-eval)", function()
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    m = model.set_cell_state(m, 1, "success", "42")
    m = model.mark_stale(m, 1)
    m = model.set_cell_state(m, 1, "running")
    assert.are.equal("running", model.get_cell_state(m, 1).status)
  end)

  it("rejects running → stale (eval must complete first)", function()
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    local ok, _ = pcall(model.set_cell_state, m, 1, "stale")
    assert.is_false(ok)
  end)
end)

-- =============================================================================
-- MISSING: session_actions is context-blind
-- =============================================================================
-- sessions.session_actions(s) returns the same 5 actions regardless of
-- session state. A stopped session shouldn't offer "Stop". The active
-- session shouldn't offer "Switch to this session" when it's already active.

describe("sessions.session_actions context sensitivity [RED]", function()
  it("excludes 'stop' for a stopped session", function()
    local s = {
      id = "s1", status = "Stopped", projects = { "A.fsproj" },
      working_directory = "/a", eval_count = 0, avg_duration_ms = 0,
    }
    local actions = sessions.session_actions(s)
    local names = {}
    for _, a in ipairs(actions) do names[a.name] = true end
    assert.is_nil(names["stop"])
  end)

  it("excludes 'switch' when session is already active", function()
    local s = {
      id = "s1", status = "Ready", projects = { "A.fsproj" },
      working_directory = "/a", eval_count = 0, avg_duration_ms = 0,
    }
    -- session_actions should accept a second parameter: is_active
    local actions = sessions.session_actions(s, true)
    local names = {}
    for _, a in ipairs(actions) do names[a.name] = true end
    assert.is_nil(names["switch"])
  end)

  it("includes 'switch' when session is not active", function()
    local s = {
      id = "s1", status = "Ready", projects = { "A.fsproj" },
      working_directory = "/a", eval_count = 0, avg_duration_ms = 0,
    }
    local actions = sessions.session_actions(s, false)
    local names = {}
    for _, a in ipairs(actions) do names[a.name] = true end
    assert.is_true(names["switch"] ~= nil)
  end)

  it("excludes 'reset' and 'hard_reset' for a stopped session", function()
    local s = {
      id = "s1", status = "Stopped", projects = {},
      working_directory = "/a", eval_count = 0, avg_duration_ms = 0,
    }
    local actions = sessions.session_actions(s)
    local names = {}
    for _, a in ipairs(actions) do names[a.name] = true end
    assert.is_nil(names["reset"])
    assert.is_nil(names["hard_reset"])
  end)

  it("includes all relevant actions for a Ready session that is not active", function()
    local s = {
      id = "s1", status = "Ready", projects = { "A.fsproj" },
      working_directory = "/a", eval_count = 5, avg_duration_ms = 10,
    }
    local actions = sessions.session_actions(s, false)
    local names = {}
    for _, a in ipairs(actions) do names[a.name] = true end
    assert.is_true(names["switch"] ~= nil)
    assert.is_true(names["stop"] ~= nil)
    assert.is_true(names["reset"] ~= nil)
    assert.is_true(names["hard_reset"] ~= nil)
  end)
end)

-- =============================================================================
-- MISSING: SSE reconnection backoff (currently fixed 3s)
-- =============================================================================
-- The plan called for exponential backoff: 1s → 2s → 4s → 8s → ... → 32s cap.
-- Current implementation uses fixed 3000ms. This should be a pure function
-- that computes the next delay given current attempt count.

describe("sse.reconnect_delay [RED]", function()
  it("first reconnect delay is 1 second", function()
    assert.is_function(sse.reconnect_delay)
    local delay = sse.reconnect_delay(1)
    assert.are.equal(1000, delay)
  end)

  it("second reconnect doubles to 2 seconds", function()
    assert.are.equal(2000, sse.reconnect_delay(2))
  end)

  it("third reconnect doubles to 4 seconds", function()
    assert.are.equal(4000, sse.reconnect_delay(3))
  end)

  it("caps at 32 seconds", function()
    assert.are.equal(32000, sse.reconnect_delay(6))
    assert.are.equal(32000, sse.reconnect_delay(10))
    assert.are.equal(32000, sse.reconnect_delay(100))
  end)

  it("resets after successful connection", function()
    -- After a successful connect, the attempt counter resets.
    -- sse.reconnect_delay(0) or sse.reset_backoff() should give initial state.
    assert.are.equal(1000, sse.reconnect_delay(1))
  end)
end)

-- =============================================================================
-- MISSING: SSE event routing / dispatch
-- =============================================================================
-- Currently init.lua's SSE on_stdout only checks for event.type == "state".
-- It ignores all other event types (EvalCompleted, TestRunCompleted,
-- SessionCreated, SessionStopped, DiagnosticsUpdated).
-- The plan's Elmish reducer would route all of these.
-- These tests define a pure event→action mapper.

describe("sse.classify_event [RED]", function()
  it("classifies eval completion events", function()
    assert.is_function(sse.classify_event)
    local result = sse.classify_event({
      type = "EvalCompleted",
      data = '{"request_id":"r1","success":true,"output":"42"}',
    })
    assert.are.equal("eval_completed", result.action)
  end)

  it("classifies test run events", function()
    local result = sse.classify_event({
      type = "TestRunCompleted",
      data = '{"total":5,"passed":4,"failed":1}',
    })
    assert.are.equal("test_run_completed", result.action)
  end)

  it("classifies session lifecycle events", function()
    local result = sse.classify_event({ type = "SessionCreated", data = '{"id":"s1"}' })
    assert.are.equal("session_created", result.action)

    result = sse.classify_event({ type = "SessionStopped", data = '{"id":"s1"}' })
    assert.are.equal("session_stopped", result.action)
  end)

  it("classifies diagnostics events", function()
    local result = sse.classify_event({
      type = "DiagnosticsUpdated",
      data = '{"diagnostics":[]}',
    })
    assert.are.equal("diagnostics_updated", result.action)
  end)

  it("classifies state/heartbeat events", function()
    local result = sse.classify_event({ type = "state", data = '{}' })
    assert.are.equal("state_update", result.action)
  end)

  it("classifies unknown event types as 'unknown'", function()
    local result = sse.classify_event({ type = "FutureEventType", data = '{}' })
    assert.are.equal("unknown", result.action)
  end)

  it("handles nil event gracefully", function()
    local result = sse.classify_event(nil)
    assert.is_nil(result)
  end)
end)

-- =============================================================================
-- MISSING: Diagnostics parsing as pure function
-- =============================================================================
-- init.lua has apply_diagnostics(diags) that groups by file and converts
-- severity strings to vim.diagnostic.severity constants. The grouping and
-- conversion logic is pure and should be extractable/testable.

describe("diagnostics pure parsing [RED]", function()
  -- This tests a function that should be extracted from init.lua into
  -- either diagnostics.lua or format.lua

  local diag_format
  local ok
  ok, diag_format = pcall(require, "sagefs.diagnostics")
  if not ok then
    diag_format = {}
  end

  it("groups diagnostics by file", function()
    assert.is_function(diag_format.group_by_file)
    local diags = {
      { file = "src/A.fs", startLine = 1, message = "err1", severity = "error" },
      { file = "src/A.fs", startLine = 5, message = "warn1", severity = "warning" },
      { file = "src/B.fs", startLine = 3, message = "info1", severity = "info" },
    }
    local grouped = diag_format.group_by_file(diags)
    assert.is_table(grouped)
    assert.are.equal(2, #grouped["src/A.fs"])
    assert.are.equal(1, #grouped["src/B.fs"])
  end)

  it("converts severity strings to numeric levels", function()
    assert.is_function(diag_format.severity_to_level)
    assert.are.equal(1, diag_format.severity_to_level("error"))
    assert.are.equal(2, diag_format.severity_to_level("warning"))
    assert.are.equal(3, diag_format.severity_to_level("info"))
    assert.are.equal(4, diag_format.severity_to_level("hint"))
    -- Unknown severity defaults to hint
    assert.are.equal(4, diag_format.severity_to_level("unknown"))
  end)

  it("converts raw diag to vim.diagnostic-shaped table", function()
    assert.is_function(diag_format.to_vim_diagnostic)
    local raw = {
      file = "src/A.fs",
      startLine = 10,
      startColumn = 5,
      endLine = 10,
      endColumn = 15,
      message = "Type mismatch",
      severity = "error",
    }
    local d = diag_format.to_vim_diagnostic(raw)
    -- vim.diagnostic uses 0-indexed lines/cols
    assert.are.equal(9, d.lnum)
    assert.are.equal(4, d.col)
    assert.are.equal(9, d.end_lnum)
    assert.are.equal(14, d.end_col)
    assert.are.equal("Type mismatch", d.message)
    assert.are.equal(1, d.severity)
    assert.are.equal("sagefs", d.source)
  end)

  it("handles missing line/column fields with defaults", function()
    local raw = { file = "a.fs", message = "oops", severity = "error" }
    local d = diag_format.to_vim_diagnostic(raw)
    assert.are.equal(0, d.lnum)
    assert.are.equal(0, d.col)
  end)
end)

-- =============================================================================
-- MISSING: format.build_render_options — pure extmark option builder
-- =============================================================================
-- init.lua render_cell_result mixes format decisions with vim API calls.
-- A pure function should take cell state and return extmark options tables,
-- letting init.lua just call nvim_buf_set_extmark with the results.

describe("format.build_render_options [RED]", function()
  it("builds extmark options for a success cell", function()
    assert.is_function(format.build_render_options)
    local opts = format.build_render_options({
      status = "success",
      output = "val it: int = 42",
    }, 1) -- cell_id=1
    assert.is_table(opts)
    assert.is_table(opts.sign)
    assert.are.equal("✓", opts.sign.text)
    assert.are.equal("SageFsSuccess", opts.sign.hl)
    assert.is_table(opts.inline)
    assert.are.equal("SageFsSuccess", opts.inline.hl)
    assert.is_table(opts.virtual_lines)
    assert.is_true(#opts.virtual_lines > 0)
  end)

  it("builds extmark options for an error cell", function()
    local opts = format.build_render_options({
      status = "error",
      output = "type mismatch",
    }, 2)
    assert.are.equal("✖", opts.sign.text)
    assert.are.equal("SageFsError", opts.sign.hl)
    assert.are.equal("SageFsError", opts.inline.hl)
  end)

  it("builds extmark options for a stale cell with SageFsStale", function()
    local opts = format.build_render_options({
      status = "stale",
      output = "val it: int = 42",
    }, 3)
    assert.are.equal("~", opts.sign.text)
    assert.are.equal("SageFsStale", opts.sign.hl)
    assert.are.equal("SageFsStale", opts.inline.hl)
    -- Virtual lines should also use stale highlight
    for _, vl in ipairs(opts.virtual_lines) do
      assert.are.equal("SageFsStale", vl.hl)
    end
  end)

  it("builds extmark options for a running cell (no inline, no vlines)", function()
    local opts = format.build_render_options({
      status = "running",
      output = nil,
    }, 4)
    assert.are.equal("⏳", opts.sign.text)
    assert.is_nil(opts.inline)
    assert.is_nil(opts.virtual_lines)
  end)

  it("builds extmark options for an idle cell (no rendering)", function()
    local opts = format.build_render_options({
      status = "idle",
      output = nil,
    }, 5)
    assert.is_nil(opts)
  end)

  it("includes codelens for idle/stale cells", function()
    local opts = format.build_render_options({
      status = "stale",
      output = "old value",
    }, 6)
    assert.is_table(opts.codelens)
    assert.is_truthy(opts.codelens.text:find("Eval"))
  end)
end)

-- =============================================================================
-- MISSING: SSE subscription uses different parser than diagnostics SSE
-- =============================================================================
-- init.lua has two SSE connections. The diagnostics handler (lines 660-674)
-- has its own inline parser that doesn't use sse.lua. The main SSE handler
-- does use sse.lua. This tests that sse.parse_chunk correctly handles
-- the diagnostics event format too (proving sse.lua is sufficient).

describe("sse.parse_chunk handles diagnostics events [RED by design gap]", function()
  it("parses a diagnostics data event without event: field", function()
    -- The diagnostics SSE stream may only send data: lines without event: type.
    -- sse.parse_chunk should handle this (event.type = nil, event.data = payload)
    local chunk = "data: {\"diagnostics\":[{\"file\":\"a.fs\",\"message\":\"err\"}]}\n\n"
    local events, _ = sse.parse_chunk(chunk)
    assert.are.equal(1, #events)
    assert.is_nil(events[1].type)
    assert.is_truthy(events[1].data:find("diagnostics"))
  end)

  -- This test PASSES (sse.lua already handles typeless events)
  -- but is included to document that sse.lua IS sufficient for diagnostics
  -- and the duplicate parser in init.lua should be removed.
end)

-- =============================================================================
-- PROPERTY: model state machine invariants
-- =============================================================================

describe("model property: status validation is total [RED]", function()
  it("every string that isn't in VALID_CELL_STATUSES is rejected", function()
    local m = model.new()
    -- Use set_cell_state with running first to get a valid starting state
    m = model.set_cell_state(m, 1, "running")

    local garbage = {
      "banana", "SUCCESS", "Error", "STALE", "idle_ish",
      "running!", "", " ", "nil", "1", "true",
    }
    for _, bad in ipairs(garbage) do
      local ok, _ = pcall(model.set_cell_state, m, 1, bad)
      assert.is_false(ok, "should reject status: " .. tostring(bad))
    end
  end)

  it("every string that isn't in VALID_CONNECTION_STATUSES is rejected", function()
    local m = model.new()
    local garbage = {
      "Connected", "DISCONNECTED", "", " ", "online", "offline",
    }
    for _, bad in ipairs(garbage) do
      local ok, _ = pcall(model.set_status, m, bad)
      assert.is_false(ok, "should reject connection status: " .. tostring(bad))
    end
  end)
end)

-- =============================================================================
-- PROPERTY: format functions are total (never error on any input)
-- =============================================================================

describe("format totality [RED]", function()
  it("build_render_options exists as a function", function()
    assert.is_function(format.build_render_options)
  end)

  it("build_render_options never errors for any valid cell state", function()
    local statuses = { "idle", "running", "success", "error", "stale" }
    local outputs = { nil, "", "42", "line1\nline2", string.rep("x", 500) }

    for _, status in ipairs(statuses) do
      for _, output in ipairs(outputs) do
        local ok, result = pcall(format.build_render_options, {
          status = status,
          output = output,
        }, 1)
        assert.is_true(ok, "errored on status=" .. status .. " output=" .. tostring(output))
      end
    end
  end)
end)
