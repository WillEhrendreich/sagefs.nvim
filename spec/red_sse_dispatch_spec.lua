-- RED tests for Tier 1: SSE Dispatch Pipeline
-- Tests classify_event extension, dispatch table construction, and state recovery.
-- All tests here FAIL until the SSE dispatch pipeline is implemented.

require("spec.helper")
local sse = require("sagefs.sse")
local testing = require("sagefs.testing")

-- =============================================================================
-- T1: Extend classify_event for all 11+ SSE event types
-- =============================================================================

describe("sse.classify_event — testing events [RED]", function()
  it("classifies TestLocationsDetected", function()
    local result = sse.classify_event({ type = "TestLocationsDetected", data = "{}" })
    assert.are.equal("test_locations_detected", result.action)
  end)

  it("classifies TestsDiscovered", function()
    local result = sse.classify_event({ type = "TestsDiscovered", data = "{}" })
    assert.are.equal("tests_discovered", result.action)
  end)

  it("classifies TestRunStarted", function()
    local result = sse.classify_event({ type = "TestRunStarted", data = "{}" })
    assert.are.equal("test_run_started", result.action)
  end)

  it("classifies TestResultsBatch", function()
    local result = sse.classify_event({ type = "TestResultsBatch", data = "{}" })
    assert.are.equal("test_results_batch", result.action)
  end)

  it("classifies LiveTestingToggled", function()
    local result = sse.classify_event({ type = "LiveTestingToggled", data = "{}" })
    assert.are.equal("live_testing_toggled", result.action)
  end)

  it("classifies AffectedTestsComputed", function()
    local result = sse.classify_event({ type = "AffectedTestsComputed", data = "{}" })
    assert.are.equal("affected_tests_computed", result.action)
  end)

  it("classifies RunPolicyChanged", function()
    local result = sse.classify_event({ type = "RunPolicyChanged", data = "{}" })
    assert.are.equal("run_policy_changed", result.action)
  end)

  it("classifies ProvidersDetected", function()
    local result = sse.classify_event({ type = "ProvidersDetected", data = "{}" })
    assert.are.equal("providers_detected", result.action)
  end)

  it("classifies PipelineTimingRecorded", function()
    local result = sse.classify_event({ type = "PipelineTimingRecorded", data = "{}" })
    assert.are.equal("pipeline_timing_recorded", result.action)
  end)

  it("classifies RunTestsRequested", function()
    local result = sse.classify_event({ type = "RunTestsRequested", data = "{}" })
    assert.are.equal("run_tests_requested", result.action)
  end)
end)

describe("sse.classify_event — coverage events [RED]", function()
  it("classifies CoverageUpdated", function()
    local result = sse.classify_event({ type = "CoverageUpdated", data = "{}" })
    assert.are.equal("coverage_updated", result.action)
  end)

  it("classifies CoverageCleared", function()
    local result = sse.classify_event({ type = "CoverageCleared", data = "{}" })
    assert.are.equal("coverage_cleared", result.action)
  end)
end)

describe("sse.classify_event — session events [RED]", function()
  it("classifies HotReloadTriggered", function()
    local result = sse.classify_event({ type = "HotReloadTriggered", data = "{}" })
    assert.are.equal("hot_reload_triggered", result.action)
  end)

  it("classifies FileChanged", function()
    local result = sse.classify_event({ type = "FileChanged", data = "{}" })
    assert.are.equal("file_changed", result.action)
  end)
end)

-- Verify existing classifications still work (regression guard)
describe("sse.classify_event — existing events [regression]", function()
  it("still classifies EvalCompleted", function()
    local result = sse.classify_event({ type = "EvalCompleted", data = "{}" })
    assert.are.equal("eval_completed", result.action)
  end)

  it("still classifies state", function()
    local result = sse.classify_event({ type = "state", data = "{}" })
    assert.are.equal("state_update", result.action)
  end)

  it("still classifies DiagnosticsUpdated", function()
    local result = sse.classify_event({ type = "DiagnosticsUpdated", data = "{}" })
    assert.are.equal("diagnostics_updated", result.action)
  end)
end)

-- =============================================================================
-- T1: Dispatch table builder
-- =============================================================================

describe("sse.build_dispatch_table [RED]", function()
  it("exists as a function", function()
    assert.is_function(sse.build_dispatch_table)
  end)

  it("returns a table mapping action strings to handler functions", function()
    local handlers = {
      test_results_batch = function() end,
      eval_completed = function() end,
    }
    local table = sse.build_dispatch_table(handlers)
    assert.is_table(table)
    assert.is_function(table["test_results_batch"])
    assert.is_function(table["eval_completed"])
  end)

  it("dispatch returns nil for unknown actions", function()
    local dt = sse.build_dispatch_table({})
    assert.is_nil(dt["nonexistent_action"])
  end)
end)

describe("sse.dispatch [RED]", function()
  it("routes classified event to correct handler", function()
    local called_with = nil
    local handlers = {
      test_results_batch = function(data) called_with = data end,
    }
    local dt = sse.build_dispatch_table(handlers)
    local event = { type = "TestResultsBatch", data = '{"results":[]}' }
    local classified = sse.classify_event(event)
    sse.dispatch(dt, classified)
    assert.are.equal('{"results":[]}', called_with)
  end)

  it("silently ignores events with no handler", function()
    local dt = sse.build_dispatch_table({})
    local classified = { action = "unknown", data = "{}" }
    -- Should not error
    assert.has_no.errors(function()
      sse.dispatch(dt, classified)
    end)
  end)

  it("silently ignores nil classified events", function()
    local dt = sse.build_dispatch_table({})
    assert.has_no.errors(function()
      sse.dispatch(dt, nil)
    end)
  end)
end)

-- =============================================================================
-- T1: Wire SSE handlers to testing.lua state functions
-- =============================================================================

describe("testing.handle_results_batch [RED]", function()
  it("updates multiple test results from a batch event", function()
    assert.is_function(testing.handle_results_batch)
    local state = testing.new()
    state = testing.set_enabled(state, true)
    testing.update_test(state, {
      testId = "t1", displayName = "test 1", fullName = "test 1",
      category = "Unit", currentPolicy = "OnEveryChange", status = "Detected",
    })
    testing.update_test(state, {
      testId = "t2", displayName = "test 2", fullName = "test 2",
      category = "Unit", currentPolicy = "OnEveryChange", status = "Detected",
    })

    local batch_data = {
      results = {
        { testId = "t1", status = "Passed" },
        { testId = "t2", status = "Failed", output = "assertion failed" },
      },
    }
    state = testing.handle_results_batch(state, batch_data)
    assert.are.equal("Passed", state.tests["t1"].status)
    assert.are.equal("Failed", state.tests["t2"].status)
    assert.are.equal("assertion failed", state.tests["t2"].output)
  end)

  it("handles empty results array", function()
    local state = testing.new()
    state = testing.handle_results_batch(state, { results = {} })
    assert.are.equal(0, testing.test_count(state))
  end)
end)

describe("testing.handle_tests_discovered [RED]", function()
  it("bulk-adds discovered tests to state", function()
    assert.is_function(testing.handle_tests_discovered)
    local state = testing.new()
    local discovery_data = {
      tests = {
        {
          testId = "d1", displayName = "discovered 1", fullName = "M.discovered 1",
          origin = { Case = "SourceMapped", Fields = { "src/Math.fs", 10 } },
          framework = "Expecto", category = "Unit", currentPolicy = "OnEveryChange",
          status = "Detected",
        },
        {
          testId = "d2", displayName = "discovered 2", fullName = "M.discovered 2",
          origin = { Case = "ReflectionOnly" },
          framework = "xUnit", category = "Integration", currentPolicy = "OnSaveOnly",
          status = "Detected",
        },
      },
    }
    state = testing.handle_tests_discovered(state, discovery_data)
    assert.are.equal(2, testing.test_count(state))
    assert.is_not_nil(state.tests["d1"])
    assert.is_not_nil(state.tests["d2"])
  end)
end)

describe("testing.handle_live_testing_toggled [RED]", function()
  it("updates enabled state from toggle event", function()
    assert.is_function(testing.handle_live_testing_toggled)
    local state = testing.new()
    state = testing.handle_live_testing_toggled(state, { enabled = true })
    assert.is_true(state.enabled)
    state = testing.handle_live_testing_toggled(state, { enabled = false })
    assert.is_false(state.enabled)
  end)
end)

describe("testing.handle_run_policy_changed [RED]", function()
  it("updates policy for a category", function()
    assert.is_function(testing.handle_run_policy_changed)
    local state = testing.new()
    state = testing.handle_run_policy_changed(state, {
      category = "Unit", policy = "OnDemand",
    })
    assert.are.equal("OnDemand", testing.get_run_policy(state, "Unit"))
  end)

  it("rejects invalid category gracefully", function()
    local state = testing.new()
    state = testing.handle_run_policy_changed(state, {
      category = "Bogus", policy = "OnDemand",
    })
    -- Should not crash, state unchanged
    assert.are.equal("OnEveryChange", testing.get_run_policy(state, "Unit"))
  end)
end)

describe("testing.handle_test_run_started [RED]", function()
  it("marks affected tests as Running", function()
    assert.is_function(testing.handle_test_run_started)
    local state = testing.new()
    testing.update_test(state, {
      testId = "t1", displayName = "t1", fullName = "t1",
      category = "Unit", currentPolicy = "OnEveryChange", status = "Passed",
    })
    testing.update_test(state, {
      testId = "t2", displayName = "t2", fullName = "t2",
      category = "Unit", currentPolicy = "OnEveryChange", status = "Passed",
    })
    state = testing.handle_test_run_started(state, {
      testIds = { "t1", "t2" },
    })
    assert.are.equal("Running", state.tests["t1"].status)
    assert.are.equal("Running", state.tests["t2"].status)
  end)

  it("marks all tests Running when no testIds specified", function()
    local state = testing.new()
    testing.update_test(state, {
      testId = "t1", displayName = "t1", fullName = "t1",
      category = "Unit", currentPolicy = "OnEveryChange", status = "Passed",
    })
    state = testing.handle_test_run_started(state, {})
    assert.are.equal("Running", state.tests["t1"].status)
  end)
end)

describe("testing.handle_test_run_completed", function()
  it("exists as a function", function()
    assert.is_function(testing.handle_test_run_completed)
  end)

  it("updates summary from completed data", function()
    local state = testing.new()
    state = testing.handle_test_run_completed(state, {
      summary = { total = 5, passed = 4, failed = 1, stale = 0, running = 0 },
    })
    assert.are.equal(5, state.summary.total)
    assert.are.equal(4, state.summary.passed)
    assert.are.equal(1, state.summary.failed)
  end)

  it("handles nil data gracefully", function()
    local state = testing.new()
    local result = testing.handle_test_run_completed(state, nil)
    assert.is_table(result)
  end)
end)

-- =============================================================================
-- T1: State recovery on SSE reconnect
-- =============================================================================

describe("testing.build_recovery_request [RED]", function()
  it("builds the MCP request to get full test status", function()
    assert.is_function(testing.build_recovery_request)
    local req = testing.build_recovery_request()
    assert.is_table(req)
    -- Should produce params for get_live_test_status
    assert.is_not_nil(req.method or req.tool)
  end)
end)

describe("testing.needs_recovery [RED]", function()
  it("returns true when state has stale tests", function()
    assert.is_function(testing.needs_recovery)
    local state = testing.new()
    state = testing.set_enabled(state, true)
    testing.update_test(state, {
      testId = "t1", displayName = "t1", fullName = "t1",
      category = "Unit", currentPolicy = "OnEveryChange", status = "Stale",
    })
    assert.is_true(testing.needs_recovery(state))
  end)

  it("returns true when enabled but no tests", function()
    local state = testing.new()
    state = testing.set_enabled(state, true)
    assert.is_true(testing.needs_recovery(state))
  end)

  it("returns false when disabled", function()
    local state = testing.new()
    assert.is_false(testing.needs_recovery(state))
  end)
end)
