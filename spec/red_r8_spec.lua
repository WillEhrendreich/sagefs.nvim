-- =============================================================================
-- R8 RED Tests — Panel findings proved as failing tests
-- =============================================================================
-- TDD: These tests MUST fail before any fix is applied.
-- Each test documents a verified panel finding.
-- =============================================================================

require("spec.helper")
local events = require("sagefs.events")
local format = require("sagefs.format")

-- ─── Finding #2: 10 fire_user_event types missing from EVENT_MAP ────────────

describe("events.build_autocmd_data — completeness", function()
  -- These are ALL event types fired by init.lua via fire_user_event().
  -- Every one MUST have an EVENT_MAP entry so downstream User autocmds fire.
  local all_fired_event_types = {
    "eval_completed",
    "test_passed",
    "test_failed",
    "test_results_batch",
    "test_run_started",
    "test_run_completed",
    "test_state",
    "tests_discovered",
    "connected",
    "disconnected",
    "coverage_updated",
    "hot_reload_triggered",
    "warmup_context",
    "hotreload_snapshot",
    -- These 10 are fired by init.lua but MISSING from EVENT_MAP:
    "providers_detected",
    "affected_tests_computed",
    "test_cycle_timing_recorded",
    "run_tests_requested",
    "test_summary",
    "file_annotations",
    "bindings_snapshot",
    "test_trace",
    "reconnecting",
    "test_recovery_needed",
  }

  for _, event_type in ipairs(all_fired_event_types) do
    it("maps '" .. event_type .. "' to an autocmd pattern", function()
      local result = events.build_autocmd_data(event_type, { test = true })
      assert.is_not_nil(result, "EVENT_MAP missing entry for '" .. event_type .. "'")
      assert.is_string(result.pattern)
      assert.truthy(result.pattern:match("^SageFs"), result.pattern .. " should start with SageFs")
    end)
  end
end)

describe("events.EVENT_NAMES — completeness", function()
  it("contains entries for all 28 event types", function()
    -- 14 original + 10 new + 4 hooks + 1 = 29, +4 Phase 7C = 34
    assert.are.equal(34, #events.EVENT_NAMES)
  end)
end)

-- ─── Finding #11: tracker_from_snapshot only handles PascalCase ──────────────

describe("format.tracker_from_snapshot — casing", function()
  it("handles PascalCase fields (existing behavior)", function()
    local snapshot = {
      { Name = "x", TypeSig = "int", ShadowCount = 0 },
      { Name = "y", TypeSig = "string", ShadowCount = 2 },
    }
    local tracker = format.tracker_from_snapshot(snapshot)
    assert.is_not_nil(tracker.bindings["x"])
    assert.are.equal("int", tracker.bindings["x"].type_sig)
    assert.are.equal(0, tracker.bindings["x"].count)
    assert.are.equal("string", tracker.bindings["y"].type_sig)
    assert.are.equal(2, tracker.bindings["y"].count)
  end)

  it("handles camelCase fields from server", function()
    local snapshot = {
      { name = "a", typeSig = "float", shadowCount = 1 },
      { name = "b", typeSig = "bool", shadowCount = 0 },
    }
    local tracker = format.tracker_from_snapshot(snapshot)
    assert.is_not_nil(tracker.bindings["a"], "camelCase 'name' field not handled")
    if tracker.bindings["a"] then
      assert.are.equal("float", tracker.bindings["a"].type_sig)
      assert.are.equal(1, tracker.bindings["a"].count)
    end
    assert.is_not_nil(tracker.bindings["b"])
    if tracker.bindings["b"] then
      assert.are.equal("bool", tracker.bindings["b"].type_sig)
    end
  end)

  it("handles mixed casing in same snapshot", function()
    local snapshot = {
      { Name = "pascal", TypeSig = "int", ShadowCount = 0 },
      { name = "camel", typeSig = "string", shadowCount = 1 },
    }
    local tracker = format.tracker_from_snapshot(snapshot)
    assert.is_not_nil(tracker.bindings["pascal"])
    assert.is_not_nil(tracker.bindings["camel"], "mixed casing not handled")
  end)

  it("returns empty tracker for empty snapshot", function()
    local tracker = format.tracker_from_snapshot({})
    assert.is_table(tracker.bindings)
    local count = 0
    for _ in pairs(tracker.bindings) do count = count + 1 end
    assert.are.equal(0, count)
  end)
end)

-- ─── Finding #5: HTTP GET sends Content-Type unconditionally ─────────────────
-- Transport uses vim.loop TCP so we can't test the actual HTTP call under busted.
-- But we CAN test the header construction logic if we extract it.
-- For now, document the expected behavior as a specification test.

describe("transport — HTTP header spec (documented, not yet testable)", function()
  pending("GET requests should NOT include Content-Type header")
  pending("POST requests with body SHOULD include Content-Type: application/json")
  pending("POST requests without body should NOT include Content-Type header")
end)
