require("spec.helper")
local events = require("sagefs.events")

describe("events", function()
  -- ─── EVENT_NAMES ─────────────────────────────────────────────────────────
  describe("EVENT_NAMES", function()
    it("is a non-empty table", function()
      assert.is_table(events.EVENT_NAMES)
      assert.is_true(#events.EVENT_NAMES > 0)
    end)

    it("contains 36 event names", function()
      assert.are.equal(36, #events.EVENT_NAMES)
    end)

    it("all names start with SageFs", function()
      for _, name in ipairs(events.EVENT_NAMES) do
        assert.truthy(name:match("^SageFs"), name .. " should start with SageFs")
      end
    end)

    it("contains eval completed event", function()
      local found = false
      for _, name in ipairs(events.EVENT_NAMES) do
        if name == "SageFsEvalCompleted" then found = true; break end
      end
      assert.is_true(found)
    end)

    it("contains test events", function()
      local has_passed, has_failed = false, false
      for _, name in ipairs(events.EVENT_NAMES) do
        if name == "SageFsTestPassed" then has_passed = true end
        if name == "SageFsTestFailed" then has_failed = true end
      end
      assert.is_true(has_passed)
      assert.is_true(has_failed)
    end)

    it("contains source location and failure narrative events", function()
      local has_source_locations, has_failure_narratives = false, false
      for _, name in ipairs(events.EVENT_NAMES) do
        if name == "SageFsTestSourceLocations" then has_source_locations = true end
        if name == "SageFsFailureNarratives" then has_failure_narratives = true end
      end
      assert.is_true(has_source_locations)
      assert.is_true(has_failure_narratives)
    end)
  end)

  -- ─── build_autocmd_data ──────────────────────────────────────────────────
  describe("build_autocmd_data", function()
    it("returns pattern and data for known event type", function()
      local result = events.build_autocmd_data("eval_completed", { code = "1+1;;" })
      assert.is_table(result)
      assert.are.equal("SageFsEvalCompleted", result.pattern)
      assert.is_table(result.data)
      assert.are.equal("1+1;;", result.data.code)
    end)

    it("returns nil for unknown event type", function()
      local result = events.build_autocmd_data("completely_unknown", {})
      assert.is_nil(result)
    end)

    it("maps all supported event types correctly", function()
      local mappings = {
        { "eval_completed", "SageFsEvalCompleted" },
        { "test_passed", "SageFsTestPassed" },
        { "test_failed", "SageFsTestFailed" },
        { "test_results_batch", "SageFsTestResultsBatch" },
        { "test_run_started", "SageFsTestRunStarted" },
        { "test_run_completed", "SageFsTestRunCompleted" },
        { "test_state", "SageFsTestState" },
        { "tests_discovered", "SageFsTestsDiscovered" },
        { "test_source_locations", "SageFsTestSourceLocations" },
        { "connected", "SageFsConnected" },
        { "disconnected", "SageFsDisconnected" },
        { "coverage_updated", "SageFsCoverageUpdated" },
        { "hot_reload_triggered", "SageFsHotReloadTriggered" },
        { "warmup_context", "SageFsWarmupContext" },
        { "hotreload_snapshot", "SageFsHotReloadSnapshot" },
        { "providers_detected", "SageFsProvidersDetected" },
        { "affected_tests_computed", "SageFsAffectedTestsComputed" },
        { "test_cycle_timing_recorded", "SageFsTestCycleTimingRecorded" },
        { "run_tests_requested", "SageFsRunTestsRequested" },
        { "test_summary", "SageFsTestSummary" },
        { "file_annotations", "SageFsFileAnnotations" },
        { "bindings_snapshot", "SageFsBindingsSnapshot" },
        { "test_trace", "SageFsTestTrace" },
        { "reconnecting", "SageFsReconnecting" },
        { "test_recovery_needed", "SageFsTestRecoveryNeeded" },
        { "eval_diff", "SageFsEvalDiff" },
        { "cell_dependencies", "SageFsCellDependencies" },
        { "binding_scope_map", "SageFsBindingScopeMap" },
        { "eval_timeline", "SageFsEvalTimeline" },
        { "eval_result", "SageFsEvalResult" },
        { "failure_narratives", "SageFsFailureNarratives" },
        { "warmup_progress", "SageFsWarmupProgress" },
        -- Phase 7C: lifecycle events
        { "session_faulted", "SageFsSessionFaulted" },
        { "warmup_completed", "SageFsWarmupCompleted" },
        { "file_reloaded", "SageFsFileReloaded" },
        { "system_alarm", "SageFsSystemAlarm" },
      }
      for _, pair in ipairs(mappings) do
        local result = events.build_autocmd_data(pair[1], {})
        assert.is_table(result, "expected result for " .. pair[1])
        assert.are.equal(pair[2], result.pattern)
      end
    end)

    it("uses empty table when payload is nil", function()
      local result = events.build_autocmd_data("connected")
      assert.is_table(result.data)
    end)

    it("preserves payload data", function()
      local payload = { session_id = "abc", timestamp = 12345 }
      local result = events.build_autocmd_data("connected", payload)
      assert.are.equal("abc", result.data.session_id)
      assert.are.equal(12345, result.data.timestamp)
    end)

    -- ── Phase 7C: new lifecycle event autocmd mappings ──────────────────────
    it("maps session_faulted to SageFsSessionFaulted", function()
      local result = events.build_autocmd_data("session_faulted", { session_id = "x", reason = "crash" })
      assert.is_table(result)
      assert.are.equal("SageFsSessionFaulted", result.pattern)
      assert.are.equal("x", result.data.session_id)
      assert.are.equal("crash", result.data.reason)
    end)

    it("maps warmup_completed to SageFsWarmupCompleted", function()
      local result = events.build_autocmd_data("warmup_completed", { session_id = "y", project_count = 3 })
      assert.is_table(result)
      assert.are.equal("SageFsWarmupCompleted", result.pattern)
      assert.are.equal(3, result.data.project_count)
    end)

    it("maps file_reloaded to SageFsFileReloaded", function()
      local result = events.build_autocmd_data("file_reloaded", { file = "Domain.fs", elapsed_ms = 47 })
      assert.is_table(result)
      assert.are.equal("SageFsFileReloaded", result.pattern)
      assert.are.equal("Domain.fs", result.data.file)
      assert.are.equal(47, result.data.elapsed_ms)
    end)

    it("maps system_alarm to SageFsSystemAlarm", function()
      local result = events.build_autocmd_data("system_alarm", { phase = "eval", message = "kaboom" })
      assert.is_table(result)
      assert.are.equal("SageFsSystemAlarm", result.pattern)
      assert.are.equal("eval", result.data.phase)
      assert.are.equal("kaboom", result.data.message)
    end)

    it("EVENT_NAMES contains all 4 new Phase 7C names", function()
      local expected = {
        "SageFsSessionFaulted",
        "SageFsWarmupCompleted",
        "SageFsFileReloaded",
        "SageFsSystemAlarm",
      }
      for _, name in ipairs(expected) do
        local found = false
        for _, n in ipairs(events.EVENT_NAMES) do
          if n == name then found = true; break end
        end
        assert.is_true(found, "EVENT_NAMES missing: " .. name)
      end
    end)
  end)
end)

