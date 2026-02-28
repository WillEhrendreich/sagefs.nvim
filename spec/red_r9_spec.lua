-- =============================================================================
-- R9 RED Tests — Dispatch contract, eval deduplication
-- =============================================================================
-- TDD: These tests document findings and verify fixes.
-- =============================================================================

require("spec.helper")
local sse = require("sagefs.sse")

-- ─── Finding #1: classify_event.data should be the dispatch payload ──────────
-- The contract: classify_event returns {action, data} where data is what
-- handlers receive. on_sse_events should use c.data, not the raw event table.

describe("sse dispatch contract", function()
  it("classify_event returns data as a string, not the event table", function()
    local event = { type = "TestsDiscovered", data = '{"tests":[]}' }
    local classified = sse.classify_event(event)
    assert.are.equal("string", type(classified.data),
      "classify_event should return data as string, got " .. type(classified.data))
    assert.are.equal('{"tests":[]}', classified.data)
  end)

  it("dispatch passes data (not event table) to handler", function()
    local received = nil
    local dt = sse.build_dispatch_table({
      tests_discovered = function(data) received = data end,
    })

    -- Simulate correct dispatch: use classify_event's output directly
    local event = { type = "TestsDiscovered", data = '{"tests":["a","b"]}' }
    local c = sse.classify_event(event)
    sse.dispatch(dt, c)

    assert.are.equal("string", type(received),
      "handler should receive string, got " .. type(received))
    assert.are.equal('{"tests":["a","b"]}', received)
  end)

  it("safe_dispatch_batch passes data string to each handler", function()
    local received_types = {}
    local dt = sse.build_dispatch_table({
      tests_discovered = function(data)
        table.insert(received_types, type(data))
      end,
      eval_completed = function(data)
        table.insert(received_types, type(data))
      end,
    })

    -- Build classified list the CORRECT way (using classify_event)
    local events = {
      { type = "TestsDiscovered", data = '{"x":1}' },
      { type = "EvalCompleted", data = '{"y":2}' },
    }
    local classified = {}
    for _, event in ipairs(events) do
      local c = sse.classify_event(event)
      if c then table.insert(classified, c) end
    end

    sse.safe_dispatch_batch(dt, classified)
    for _, t in ipairs(received_types) do
      assert.are.equal("string", t, "handler received " .. t .. " instead of string")
    end
  end)
end)

-- ─── Finding #7+#6: eval_cell duplication is an init.lua concern ─────────────
-- We can't test init.lua under busted, but we CAN verify that the model
-- allows the refactored flow: running→running is valid (needed if post_exec
-- redundantly sets running after caller already did)

local model = require("sagefs.model")

describe("model — eval flow correctness", function()
  it("running → running is a valid transition (no error)", function()
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    -- Should not error — this is the double-set scenario
    m = model.set_cell_state(m, 1, "running")
    assert.are.equal("running", model.get_cell_state(m, 1).status)
  end)

  it("running → success overwrites running (latest result wins)", function()
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    m = model.set_cell_state(m, 1, "success", "result 1")
    assert.are.equal("success", model.get_cell_state(m, 1).status)
    assert.are.equal("result 1", model.get_cell_state(m, 1).output)
  end)

  it("success can be overwritten by another success (concurrent eval scenario)", function()
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    m = model.set_cell_state(m, 1, "success", "stale result")
    -- Second eval completes — overwrites
    m = model.set_cell_state(m, 1, "running")
    m = model.set_cell_state(m, 1, "success", "fresh result")
    assert.are.equal("fresh result", model.get_cell_state(m, 1).output)
  end)
end)
