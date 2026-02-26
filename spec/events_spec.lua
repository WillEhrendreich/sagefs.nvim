require("spec.helper")
local events = require("sagefs.events")

describe("events", function()
  -- ─── EVENT_NAMES ─────────────────────────────────────────────────────────
  describe("EVENT_NAMES", function()
    it("is a non-empty table", function()
      assert.is_table(events.EVENT_NAMES)
      assert.is_true(#events.EVENT_NAMES > 0)
    end)

    it("contains 12 event names", function()
      assert.are.equal(12, #events.EVENT_NAMES)
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

    it("maps all 10 event types correctly", function()
      local mappings = {
        { "eval_completed", "SageFsEvalCompleted" },
        { "test_passed", "SageFsTestPassed" },
        { "test_failed", "SageFsTestFailed" },
        { "test_results_batch", "SageFsTestResultsBatch" },
        { "test_run_started", "SageFsTestRunStarted" },
        { "test_run_completed", "SageFsTestRunCompleted" },
        { "connected", "SageFsConnected" },
        { "disconnected", "SageFsDisconnected" },
        { "coverage_updated", "SageFsCoverageUpdated" },
        { "hot_reload_triggered", "SageFsHotReloadTriggered" },
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
  end)
end)
