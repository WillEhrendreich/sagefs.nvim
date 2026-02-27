-- =============================================================================
-- Testing Module Tests — sagefs/testing.lua (RED → GREEN → REFACTOR)
-- =============================================================================
-- Live testing state model: test discovery, results, policies, summaries.
-- All pure Lua, no vim API dependencies. Tests define the acceptance criteria
-- for "live testing feature ready" in the Neovim plugin.
-- =============================================================================

local testing = require("sagefs.testing")

-- ─── new: create fresh testing state ─────────────────────────────────────────

describe("testing.new", function()
  it("creates state with enabled=false", function()
    local s = testing.new()
    assert.is_false(s.enabled)
  end)

  it("creates state with empty tests", function()
    local s = testing.new()
    assert.are.equal(0, testing.test_count(s))
  end)

  it("creates state with empty policies", function()
    local s = testing.new()
    assert.is_not_nil(s.policies)
    local count = 0
    for _ in pairs(s.policies) do count = count + 1 end
    assert.are.equal(0, count)
  end)

  it("creates state with zeroed summary", function()
    local s = testing.new()
    assert.are.equal(0, s.summary.total)
    assert.are.equal(0, s.summary.passed)
    assert.are.equal(0, s.summary.failed)
  end)
end)

-- ─── Validation: make illegal states unrepresentable ─────────────────────────

describe("testing.is_valid_status", function()
  it("accepts all 8 valid statuses", function()
    local valid = { "Detected", "Queued", "Running", "Passed", "Failed", "Skipped", "Stale", "PolicyDisabled" }
    for _, status in ipairs(valid) do
      assert.is_true(testing.is_valid_status(status), "should accept: " .. status)
    end
  end)

  it("rejects invalid statuses", function()
    assert.is_false(testing.is_valid_status("banana"))
    assert.is_false(testing.is_valid_status("passed")) -- case matters
    assert.is_false(testing.is_valid_status(""))
    assert.is_false(testing.is_valid_status(nil))
  end)
end)

describe("testing.is_valid_category", function()
  it("accepts all 6 valid categories", function()
    local valid = { "Unit", "Integration", "Browser", "Benchmark", "Architecture", "Property" }
    for _, cat in ipairs(valid) do
      assert.is_true(testing.is_valid_category(cat), "should accept: " .. cat)
    end
  end)

  it("rejects invalid categories", function()
    assert.is_false(testing.is_valid_category("unit")) -- case matters
    assert.is_false(testing.is_valid_category("e2e"))
    assert.is_false(testing.is_valid_category(nil))
  end)
end)

describe("testing.is_valid_policy", function()
  it("accepts all 4 valid policies", function()
    local valid = { "OnEveryChange", "OnSaveOnly", "OnDemand", "Disabled" }
    for _, pol in ipairs(valid) do
      assert.is_true(testing.is_valid_policy(pol), "should accept: " .. pol)
    end
  end)

  it("rejects invalid policies", function()
    assert.is_false(testing.is_valid_policy("every"))
    assert.is_false(testing.is_valid_policy("always"))
    assert.is_false(testing.is_valid_policy(nil))
  end)
end)

-- ─── set_enabled: enable/disable live testing ────────────────────────────────

describe("testing.set_enabled", function()
  it("enables live testing", function()
    local s = testing.new()
    s = testing.set_enabled(s, true)
    assert.is_true(s.enabled)
  end)

  it("disables live testing", function()
    local s = testing.new()
    s = testing.set_enabled(s, true)
    s = testing.set_enabled(s, false)
    assert.is_false(s.enabled)
  end)
end)

-- ─── update_test: store test discovery entries ───────────────────────────────

describe("testing.update_test", function()
  it("stores a test entry with all fields", function()
    local s = testing.new()
    local entry = {
      testId = "abc123",
      displayName = "my test",
      fullName = "Namespace.Module.my test",
      origin = { Case = "SourceMapped", Fields = { "C:\\src\\Tests.fs", 42 } },
      framework = "expecto",
      category = "Unit",
      currentPolicy = "OnEveryChange",
      status = "Detected",
    }
    s = testing.update_test(s, entry)
    assert.are.equal(1, testing.test_count(s))
    assert.are.equal("my test", s.tests["abc123"].displayName)
    assert.are.equal("C:\\src\\Tests.fs", s.tests["abc123"].file)
    assert.are.equal(42, s.tests["abc123"].line)
  end)

  it("extracts file and line from SourceMapped origin", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1",
      origin = { Case = "SourceMapped", Fields = { "/src/file.fs", 10 } },
      status = "Detected",
    })
    assert.are.equal("/src/file.fs", s.tests["t1"].file)
    assert.are.equal(10, s.tests["t1"].line)
  end)

  it("handles ReflectionOnly origin (no file/line)", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t2",
      origin = { Case = "ReflectionOnly" },
      status = "Detected",
    })
    assert.is_nil(s.tests["t2"].file)
    assert.is_nil(s.tests["t2"].line)
  end)

  it("rejects entry with missing testId", function()
    local s = testing.new()
    local _, err = testing.update_test(s, { status = "Detected" })
    assert.are.equal("missing testId", err)
    assert.are.equal(0, testing.test_count(s))
  end)

  it("rejects entry with invalid status", function()
    local s = testing.new()
    local _, err = testing.update_test(s, { testId = "t1", status = "banana" })
    assert.is_not_nil(err)
    assert.truthy(err:find("invalid status"))
  end)

  it("rejects entry with invalid category", function()
    local s = testing.new()
    local _, err = testing.update_test(s, { testId = "t1", category = "e2e", status = "Detected" })
    assert.is_not_nil(err)
    assert.truthy(err:find("invalid category"))
  end)

  it("rejects entry with invalid policy", function()
    local s = testing.new()
    local _, err = testing.update_test(s, { testId = "t1", currentPolicy = "always", status = "Detected" })
    assert.is_not_nil(err)
    assert.truthy(err:find("invalid policy"))
  end)

  it("overwrites existing test entry", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", displayName = "old", status = "Detected" })
    s = testing.update_test(s, { testId = "t1", displayName = "new", status = "Passed" })
    assert.are.equal(1, testing.test_count(s))
    assert.are.equal("new", s.tests["t1"].displayName)
    assert.are.equal("Passed", s.tests["t1"].status)
  end)
end)

-- ─── update_result: store test outcomes ──────────────────────────────────────

describe("testing.update_result", function()
  it("updates existing test to Passed", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", displayName = "test1", status = "Running" })
    s = testing.update_result(s, "t1", "Passed")
    assert.are.equal("Passed", s.tests["t1"].status)
  end)

  it("updates existing test to Failed with output", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", displayName = "test1", status = "Running" })
    s = testing.update_result(s, "t1", "Failed", "Expected 42 but got 7")
    assert.are.equal("Failed", s.tests["t1"].status)
    assert.are.equal("Expected 42 but got 7", s.tests["t1"].output)
  end)

  it("creates minimal entry for unknown testId", function()
    local s = testing.new()
    s = testing.update_result(s, "unknown", "Passed")
    assert.are.equal(1, testing.test_count(s))
    assert.are.equal("Passed", s.tests["unknown"].status)
  end)

  it("rejects nil testId", function()
    local s = testing.new()
    local _, err = testing.update_result(s, nil, "Passed")
    assert.are.equal("missing testId", err)
  end)

  it("rejects invalid status", function()
    local s = testing.new()
    local _, err = testing.update_result(s, "t1", "oops")
    assert.is_not_nil(err)
    assert.truthy(err:find("invalid status"))
  end)
end)

-- ─── mark_all_stale: code changes invalidate results ─────────────────────────

describe("testing.mark_all_stale", function()
  it("marks Passed tests as Stale", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Passed" })
    s = testing.mark_all_stale(s)
    assert.are.equal("Stale", s.tests["t1"].status)
  end)

  it("marks Failed tests as Stale", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Failed" })
    s = testing.mark_all_stale(s)
    assert.are.equal("Stale", s.tests["t1"].status)
  end)

  it("marks Skipped tests as Stale", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Skipped" })
    s = testing.mark_all_stale(s)
    assert.are.equal("Stale", s.tests["t1"].status)
  end)

  it("does NOT mark Running tests as Stale", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Running" })
    s = testing.mark_all_stale(s)
    assert.are.equal("Running", s.tests["t1"].status)
  end)

  it("does NOT mark Detected tests as Stale", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Detected" })
    s = testing.mark_all_stale(s)
    assert.are.equal("Detected", s.tests["t1"].status)
  end)

  it("does NOT mark Queued tests as Stale", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Queued" })
    s = testing.mark_all_stale(s)
    assert.are.equal("Queued", s.tests["t1"].status)
  end)

  it("handles mixed states correctly", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Passed" })
    s = testing.update_test(s, { testId = "t2", status = "Failed" })
    s = testing.update_test(s, { testId = "t3", status = "Running" })
    s = testing.update_test(s, { testId = "t4", status = "Detected" })
    s = testing.mark_all_stale(s)
    assert.are.equal("Stale", s.tests["t1"].status)
    assert.are.equal("Stale", s.tests["t2"].status)
    assert.are.equal("Running", s.tests["t3"].status)
    assert.are.equal("Detected", s.tests["t4"].status)
  end)
end)

-- ─── mark_file_stale: targeted staleness ─────────────────────────────────────

describe("testing.mark_file_stale", function()
  it("marks only tests in the specified file as Stale", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1",
      origin = { Case = "SourceMapped", Fields = { "/a.fs", 1 } },
      status = "Passed",
    })
    s = testing.update_test(s, {
      testId = "t2",
      origin = { Case = "SourceMapped", Fields = { "/b.fs", 1 } },
      status = "Passed",
    })
    s = testing.mark_file_stale(s, "/a.fs")
    assert.are.equal("Stale", s.tests["t1"].status)
    assert.are.equal("Passed", s.tests["t2"].status)
  end)

  it("only marks terminal states (Passed/Failed/Skipped)", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1",
      origin = { Case = "SourceMapped", Fields = { "/a.fs", 1 } },
      status = "Running",
    })
    s = testing.mark_file_stale(s, "/a.fs")
    assert.are.equal("Running", s.tests["t1"].status)
  end)

  it("is a no-op for nil file", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Passed" })
    s = testing.mark_file_stale(s, nil)
    assert.are.equal("Passed", s.tests["t1"].status)
  end)
end)

-- ─── set_run_policy / get_run_policy ─────────────────────────────────────────

describe("testing.set_run_policy", function()
  it("sets policy for a valid category", function()
    local s = testing.new()
    s = testing.set_run_policy(s, "Unit", "OnDemand")
    assert.are.equal("OnDemand", testing.get_run_policy(s, "Unit"))
  end)

  it("rejects invalid category", function()
    local s = testing.new()
    local _, err = testing.set_run_policy(s, "e2e", "OnDemand")
    assert.is_not_nil(err)
    assert.truthy(err:find("invalid category"))
  end)

  it("rejects invalid policy", function()
    local s = testing.new()
    local _, err = testing.set_run_policy(s, "Unit", "always")
    assert.is_not_nil(err)
    assert.truthy(err:find("invalid policy"))
  end)
end)

describe("testing.get_run_policy", function()
  it("defaults to OnEveryChange for unset categories", function()
    local s = testing.new()
    assert.are.equal("OnEveryChange", testing.get_run_policy(s, "Unit"))
  end)

  it("returns the set policy", function()
    local s = testing.new()
    s = testing.set_run_policy(s, "Integration", "OnSaveOnly")
    assert.are.equal("OnSaveOnly", testing.get_run_policy(s, "Integration"))
  end)
end)

-- ─── compute_summary: aggregate test counts ──────────────────────────────────

describe("testing.compute_summary", function()
  it("returns zeroes for empty state", function()
    local s = testing.new()
    local sum = testing.compute_summary(s)
    assert.are.equal(0, sum.total)
    assert.are.equal(0, sum.passed)
    assert.are.equal(0, sum.failed)
  end)

  it("counts tests by status", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Passed" })
    s = testing.update_test(s, { testId = "t2", status = "Passed" })
    s = testing.update_test(s, { testId = "t3", status = "Failed" })
    s = testing.update_test(s, { testId = "t4", status = "Stale" })
    s = testing.update_test(s, { testId = "t5", status = "Running" })
    s = testing.update_test(s, { testId = "t6", status = "Queued" })
    s = testing.update_test(s, { testId = "t7", status = "PolicyDisabled" })
    local sum = testing.compute_summary(s)
    assert.are.equal(7, sum.total)
    assert.are.equal(2, sum.passed)
    assert.are.equal(1, sum.failed)
    assert.are.equal(1, sum.stale)
    assert.are.equal(2, sum.running) -- Running + Queued
    assert.are.equal(1, sum.disabled)
  end)

  it("counts Detected as neither running nor disabled", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Detected" })
    local sum = testing.compute_summary(s)
    assert.are.equal(1, sum.total)
    assert.are.equal(0, sum.passed)
    assert.are.equal(0, sum.failed)
    assert.are.equal(0, sum.stale)
    assert.are.equal(0, sum.running)
    assert.are.equal(0, sum.disabled)
  end)
end)

-- ─── filter_by_file: query tests for a file ──────────────────────────────────

describe("testing.filter_by_file", function()
  it("returns tests in the given file", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1", displayName = "test1",
      origin = { Case = "SourceMapped", Fields = { "/src/a.fs", 10 } },
      status = "Passed",
    })
    s = testing.update_test(s, {
      testId = "t2", displayName = "test2",
      origin = { Case = "SourceMapped", Fields = { "/src/b.fs", 20 } },
      status = "Failed",
    })
    local results = testing.filter_by_file(s, "/src/a.fs")
    assert.are.equal(1, #results)
    assert.are.equal("test1", results[1].displayName)
  end)

  it("returns empty for unknown file", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1",
      origin = { Case = "SourceMapped", Fields = { "/src/a.fs", 10 } },
      status = "Passed",
    })
    local results = testing.filter_by_file(s, "/src/nope.fs")
    assert.are.equal(0, #results)
  end)

  it("returns empty for nil file", function()
    local s = testing.new()
    assert.are.equal(0, #testing.filter_by_file(s, nil))
  end)
end)

-- ─── _file_index: O(1) file lookup (SoA-inspired) ──────────────────────────

describe("testing._file_index", function()
  it("is maintained when tests are added via update_test", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1", displayName = "test1",
      origin = { Case = "SourceMapped", Fields = { "/src/a.fs", 10 } },
      status = "Passed",
    })
    assert.is_not_nil(s._file_index["/src/a.fs"])
    assert.is_true(s._file_index["/src/a.fs"]["t1"])
  end)

  it("updates index when test file changes", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1",
      origin = { Case = "SourceMapped", Fields = { "/src/a.fs", 10 } },
      status = "Passed",
    })
    -- Re-add with different file
    s = testing.update_test(s, {
      testId = "t1",
      origin = { Case = "SourceMapped", Fields = { "/src/b.fs", 20 } },
      status = "Passed",
    })
    assert.is_nil(s._file_index["/src/a.fs"]["t1"])
    assert.is_true(s._file_index["/src/b.fs"]["t1"])
  end)

  it("handles tests with no file (nil origin)", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Passed" })
    -- No _file_index entry for nil file
    local count = 0
    for _ in pairs(s._file_index) do count = count + 1 end
    assert.are.equal(0, count)
  end)
end)

-- ─── _version: mutation counter (FDA short-circuit / Nu ViewVersion) ─────────

describe("testing._version", function()
  it("starts at 0", function()
    local s = testing.new()
    assert.are.equal(0, s._version)
  end)

  it("increments on update_test", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Passed" })
    assert.are.equal(1, s._version)
  end)

  it("increments on update_result", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Passed" })
    local v = s._version
    s = testing.update_result(s, "t1", "Failed", "some output")
    assert.are.equal(v + 1, s._version)
  end)

  it("increments on mark_all_stale", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Passed" })
    local v = s._version
    s = testing.mark_all_stale(s)
    assert.are.equal(v + 1, s._version)
  end)

  it("increments on handle_test_run_started", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Passed" })
    local v = s._version
    s = testing.handle_test_run_started(s, { testIds = { "t1" } })
    assert.are.equal(v + 1, s._version)
  end)
end)

-- ─── filter_by_status: query tests by state ──────────────────────────────────

describe("testing.filter_by_status", function()
  it("returns only tests with matching status", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Failed" })
    s = testing.update_test(s, { testId = "t2", status = "Passed" })
    s = testing.update_test(s, { testId = "t3", status = "Failed" })
    local failed = testing.filter_by_status(s, "Failed")
    assert.are.equal(2, #failed)
  end)

  it("returns empty when no tests match", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Passed" })
    assert.are.equal(0, #testing.filter_by_status(s, "Failed"))
  end)
end)

-- ─── parse_status_response: parse get_live_test_status JSON ──────────────────

describe("testing.parse_status_response", function()
  it("parses valid JSON", function()
    local json = vim.fn.json_encode({
      enabled = true,
      summary = { total = 5, passed = 3, failed = 1, stale = 1, running = 0, disabled = 0 },
      tests = {},
    })
    local data, err = testing.parse_status_response(json)
    assert.is_nil(err)
    assert.is_true(data.enabled)
    assert.are.equal(5, data.summary.total)
  end)

  it("returns error for empty input", function()
    local _, err = testing.parse_status_response("")
    assert.are.equal("empty response", err)
  end)

  it("returns error for nil input", function()
    local _, err = testing.parse_status_response(nil)
    assert.are.equal("empty response", err)
  end)

  it("returns error for invalid JSON", function()
    local _, err = testing.parse_status_response("not json {{{")
    assert.are.equal("invalid JSON", err)
  end)
end)

-- ─── parse_pipeline_response: parse get_pipeline_trace JSON ──────────────────

describe("testing.parse_pipeline_response", function()
  it("parses valid pipeline trace", function()
    local json = vim.fn.json_encode({
      enabled = true,
      isRunning = false,
      history = "PreviousRun",
      summary = { total = 10, passed = 8, failed = 2, stale = 0, running = 0, disabled = 0 },
      providers = { "Expecto" },
      policies = { "Unit: OnEveryChange", "Integration: OnDemand" },
    })
    local data, err = testing.parse_pipeline_response(json)
    assert.is_nil(err)
    assert.is_true(data.enabled)
    assert.is_false(data.isRunning)
    assert.are.equal(10, data.summary.total)
  end)

  it("returns error for empty input", function()
    local _, err = testing.parse_pipeline_response("")
    assert.are.equal("empty response", err)
  end)
end)

-- ─── apply_status_response: bulk state update ────────────────────────────────

describe("testing.apply_status_response", function()
  it("updates enabled flag from response", function()
    local s = testing.new()
    s = testing.apply_status_response(s, { enabled = true })
    assert.is_true(s.enabled)
  end)

  it("updates summary from response", function()
    local s = testing.new()
    local sum = { total = 5, passed = 3, failed = 2, stale = 0, running = 0, disabled = 0 }
    s = testing.apply_status_response(s, { summary = sum })
    assert.are.equal(5, s.summary.total)
    assert.are.equal(3, s.summary.passed)
  end)

  it("ingests test entries from response", function()
    local s = testing.new()
    s = testing.apply_status_response(s, {
      tests = {
        {
          testId = "abc",
          displayName = "my test",
          fullName = "Ns.Mod.my test",
          origin = { Case = "SourceMapped", Fields = { "/test.fs", 5 } },
          framework = "expecto",
          category = "Unit",
          currentPolicy = "OnEveryChange",
          status = "Passed",
        },
      },
    })
    assert.are.equal(1, testing.test_count(s))
    assert.are.equal("Passed", s.tests["abc"].status)
  end)

  it("handles nil data gracefully", function()
    local s = testing.new()
    s = testing.apply_status_response(s, nil)
    assert.are.equal(0, testing.test_count(s))
  end)
end)

-- ─── format_summary: human-readable test summary ─────────────────────────────

describe("testing.format_summary", function()
  it("shows 'No tests' for empty summary", function()
    assert.are.equal("No tests", testing.format_summary({ total = 0, passed = 0, failed = 0, stale = 0, running = 0 }))
  end)

  it("shows 'No tests' for nil summary", function()
    assert.are.equal("No tests", testing.format_summary(nil))
  end)

  it("formats mixed results", function()
    local result = testing.format_summary({ total = 10, passed = 7, failed = 2, stale = 1, running = 0 })
    assert.truthy(result:find("10 tests"))
    assert.truthy(result:find("7 ✓"))
    assert.truthy(result:find("2 ✖"))
    assert.truthy(result:find("1 ~"))
  end)

  it("omits zero-count categories", function()
    local result = testing.format_summary({ total = 5, passed = 5, failed = 0, stale = 0, running = 0 })
    assert.truthy(result:find("5 ✓"))
    assert.is_nil(result:find("✖"))
    assert.is_nil(result:find("~"))
    assert.is_nil(result:find("⏳"))
  end)
end)

-- ─── gutter_sign: test status → sign ─────────────────────────────────────────

describe("testing.gutter_sign", function()
  it("returns ✓ for Passed", function()
    local sign = testing.gutter_sign("Passed")
    assert.are.equal("✓", sign.text)
    assert.are.equal("SageFsTestPassed", sign.hl)
  end)

  it("returns ✖ for Failed", function()
    local sign = testing.gutter_sign("Failed")
    assert.are.equal("✖", sign.text)
    assert.are.equal("SageFsTestFailed", sign.hl)
  end)

  it("returns ⏳ for Running", function()
    local sign = testing.gutter_sign("Running")
    assert.are.equal("⏳", sign.text)
    assert.are.equal("SageFsTestRunning", sign.hl)
  end)

  it("returns ⏳ for Queued", function()
    local sign = testing.gutter_sign("Queued")
    assert.are.equal("⏳", sign.text)
    assert.are.equal("SageFsTestRunning", sign.hl)
  end)

  it("returns ~ for Stale", function()
    local sign = testing.gutter_sign("Stale")
    assert.are.equal("~", sign.text)
    assert.are.equal("SageFsTestStale", sign.hl)
  end)

  it("returns ⊘ for PolicyDisabled", function()
    local sign = testing.gutter_sign("PolicyDisabled")
    assert.are.equal("⊘", sign.text)
    assert.are.equal("SageFsTestDisabled", sign.hl)
  end)

  it("returns ⊘ for Skipped", function()
    local sign = testing.gutter_sign("Skipped")
    assert.are.equal("⊘", sign.text)
    assert.are.equal("SageFsTestSkipped", sign.hl)
  end)

  it("returns ◦ for Detected", function()
    local sign = testing.gutter_sign("Detected")
    assert.are.equal("◦", sign.text)
    assert.are.equal("SageFsTestDetected", sign.hl)
  end)

  it("returns space for unknown status", function()
    local sign = testing.gutter_sign("garbage")
    assert.are.equal(" ", sign.text)
    assert.are.equal("Normal", sign.hl)
  end)
end)

-- ─── format_failure_detail: failure message for virtual text ─────────────────

describe("testing.format_failure_detail", function()
  it("returns first line of multi-line output", function()
    local result = testing.format_failure_detail("Expected 42\nbut got 7\nstack trace...")
    assert.are.equal("Expected 42", result)
  end)

  it("truncates long first lines", function()
    local long = string.rep("x", 200)
    local result = testing.format_failure_detail(long)
    assert.is_true(#result <= 120)
    assert.truthy(result:find("%.%.%.$"))
  end)

  it("returns '(no details)' for nil", function()
    assert.are.equal("(no details)", testing.format_failure_detail(nil))
  end)

  it("returns '(no details)' for empty string", function()
    assert.are.equal("(no details)", testing.format_failure_detail(""))
  end)

  it("returns short messages unchanged", function()
    assert.are.equal("assertion failed", testing.format_failure_detail("assertion failed"))
  end)
end)

-- =============================================================================
-- Round-trip tests: JSON → parse → apply → compute_summary
-- =============================================================================

describe("testing [round-trip]", function()
  it("server response → state → correct summary", function()
    local payload = {
      enabled = true,
      summary = { total = 5, passed = 3, failed = 1, stale = 1, running = 0, disabled = 0 },
      tests = {
        { testId = "t1", displayName = "test1", status = "Passed", category = "Unit", currentPolicy = "OnEveryChange",
          origin = { Case = "SourceMapped", Fields = { "/src/a.fs", 10 } }, framework = "expecto", fullName = "Ns.test1" },
        { testId = "t2", displayName = "test2", status = "Passed", category = "Unit", currentPolicy = "OnEveryChange",
          origin = { Case = "SourceMapped", Fields = { "/src/a.fs", 20 } }, framework = "expecto", fullName = "Ns.test2" },
        { testId = "t3", displayName = "test3", status = "Passed", category = "Integration", currentPolicy = "OnDemand",
          origin = { Case = "SourceMapped", Fields = { "/src/b.fs", 5 } }, framework = "expecto", fullName = "Ns.test3" },
        { testId = "t4", displayName = "test4", status = "Failed", category = "Unit", currentPolicy = "OnEveryChange",
          origin = { Case = "SourceMapped", Fields = { "/src/a.fs", 30 } }, framework = "expecto", fullName = "Ns.test4" },
        { testId = "t5", displayName = "test5", status = "Stale", category = "Unit", currentPolicy = "OnEveryChange",
          origin = { Case = "ReflectionOnly" }, framework = "expecto", fullName = "Ns.test5" },
      },
    }

    local json = vim.fn.json_encode(payload)
    local data, parse_err = testing.parse_status_response(json)
    assert.is_nil(parse_err)

    local s = testing.new()
    s = testing.apply_status_response(s, data)

    -- Verify state
    assert.is_true(s.enabled)
    assert.are.equal(5, testing.test_count(s))

    -- Verify computed summary matches
    local sum = testing.compute_summary(s)
    assert.are.equal(5, sum.total)
    assert.are.equal(3, sum.passed)
    assert.are.equal(1, sum.failed)
    assert.are.equal(1, sum.stale)

    -- Verify file filter
    local a_tests = testing.filter_by_file(s, "/src/a.fs")
    assert.are.equal(3, #a_tests)

    local b_tests = testing.filter_by_file(s, "/src/b.fs")
    assert.are.equal(1, #b_tests)

    -- Verify format_summary produces sane output
    local summary_text = testing.format_summary(sum)
    assert.truthy(summary_text:find("5 tests"))
    assert.truthy(summary_text:find("3 ✓"))
    assert.truthy(summary_text:find("1 ✖"))
  end)

  it("pipeline trace → parse → verify structure", function()
    local payload = {
      enabled = true,
      isRunning = false,
      history = "PreviousRun",
      summary = { total = 10, passed = 9, failed = 1, stale = 0, running = 0, disabled = 0 },
      providers = { "Expecto" },
      policies = { "Unit: OnEveryChange", "Integration: OnDemand" },
    }
    local json = vim.fn.json_encode(payload)
    local data, err = testing.parse_pipeline_response(json)
    assert.is_nil(err)
    assert.is_true(data.enabled)
    assert.is_false(data.isRunning)
    assert.are.equal(10, data.summary.total)
    assert.are.equal(1, #data.providers)
    assert.are.equal("Expecto", data.providers[1])
  end)
end)

-- =============================================================================
-- Composition tests: realistic multi-step workflows
-- =============================================================================

describe("testing [composition]", function()
  it("discover → run → some pass, some fail → mark stale → re-run", function()
    local s = testing.new()
    s = testing.set_enabled(s, true)

    -- Discovery phase
    s = testing.update_test(s, { testId = "t1", displayName = "add works", status = "Detected", category = "Unit" })
    s = testing.update_test(s, { testId = "t2", displayName = "sub works", status = "Detected", category = "Unit" })
    s = testing.update_test(s, { testId = "t3", displayName = "integration", status = "Detected", category = "Integration" })
    assert.are.equal(3, testing.test_count(s))

    -- First run: 2 pass, 1 fail
    s = testing.update_result(s, "t1", "Passed")
    s = testing.update_result(s, "t2", "Failed", "Expected 5 but got 3")
    s = testing.update_result(s, "t3", "Passed")

    local sum1 = testing.compute_summary(s)
    assert.are.equal(2, sum1.passed)
    assert.are.equal(1, sum1.failed)

    -- Code change → mark stale
    s = testing.mark_all_stale(s)
    local sum2 = testing.compute_summary(s)
    assert.are.equal(0, sum2.passed)
    assert.are.equal(0, sum2.failed)
    assert.are.equal(3, sum2.stale)

    -- Re-run: all pass now
    s = testing.update_result(s, "t1", "Passed")
    s = testing.update_result(s, "t2", "Passed")
    s = testing.update_result(s, "t3", "Passed")

    local sum3 = testing.compute_summary(s)
    assert.are.equal(3, sum3.passed)
    assert.are.equal(0, sum3.failed)
    assert.are.equal(0, sum3.stale)
  end)

  it("file-targeted stale only affects that file's tests", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1", status = "Passed",
      origin = { Case = "SourceMapped", Fields = { "/src/math.fs", 10 } },
    })
    s = testing.update_test(s, {
      testId = "t2", status = "Passed",
      origin = { Case = "SourceMapped", Fields = { "/src/string.fs", 10 } },
    })
    s = testing.update_test(s, {
      testId = "t3", status = "Failed",
      origin = { Case = "SourceMapped", Fields = { "/src/math.fs", 20 } },
    })

    -- Edit math.fs → only math tests go stale
    s = testing.mark_file_stale(s, "/src/math.fs")

    assert.are.equal("Stale", s.tests["t1"].status)
    assert.are.equal("Passed", s.tests["t2"].status) -- untouched
    assert.are.equal("Stale", s.tests["t3"].status)

    local sum = testing.compute_summary(s)
    assert.are.equal(1, sum.passed)
    assert.are.equal(2, sum.stale)
  end)

  it("policy changes don't affect existing test states", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Passed", category = "Unit", currentPolicy = "OnEveryChange" })
    s = testing.set_run_policy(s, "Unit", "Disabled")

    -- The test is still Passed — policy change doesn't retroactively alter status
    assert.are.equal("Passed", s.tests["t1"].status)
    -- But the category policy IS updated
    assert.are.equal("Disabled", testing.get_run_policy(s, "Unit"))
  end)
end)

-- =============================================================================
-- Idempotency tests: applying the same operation twice = once
-- =============================================================================

describe("testing [idempotency]", function()
  it("mark_all_stale is idempotent", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Passed" })
    s = testing.update_test(s, { testId = "t2", status = "Failed" })
    s = testing.mark_all_stale(s)
    local sum1 = testing.compute_summary(s)

    s = testing.mark_all_stale(s) -- second time
    local sum2 = testing.compute_summary(s)

    assert.are.equal(sum1.stale, sum2.stale)
    assert.are.equal(sum1.total, sum2.total)
    assert.are.equal("Stale", s.tests["t1"].status)
  end)

  it("apply_status_response is idempotent", function()
    local data = {
      enabled = true,
      tests = {
        { testId = "t1", displayName = "test", status = "Passed", category = "Unit" },
      },
    }
    local s = testing.new()
    s = testing.apply_status_response(s, data)
    local count1 = testing.test_count(s)

    s = testing.apply_status_response(s, data) -- second time
    local count2 = testing.test_count(s)

    assert.are.equal(count1, count2) -- no duplicate entries
    assert.are.equal(1, count2)
  end)

  it("set_run_policy with same value is idempotent", function()
    local s = testing.new()
    s = testing.set_run_policy(s, "Unit", "OnDemand")
    s = testing.set_run_policy(s, "Unit", "OnDemand")
    assert.are.equal("OnDemand", testing.get_run_policy(s, "Unit"))
  end)
end)

-- =============================================================================
-- Ordering tests: does operation order matter when it should/shouldn't?
-- =============================================================================

describe("testing [ordering]", function()
  it("mark_all_stale then update_result: result wins", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Passed" })
    s = testing.mark_all_stale(s)
    assert.are.equal("Stale", s.tests["t1"].status)
    s = testing.update_result(s, "t1", "Passed")
    assert.are.equal("Passed", s.tests["t1"].status)
  end)

  it("update_result then mark_all_stale: stale wins", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Detected" })
    s = testing.update_result(s, "t1", "Passed")
    assert.are.equal("Passed", s.tests["t1"].status)
    s = testing.mark_all_stale(s)
    assert.are.equal("Stale", s.tests["t1"].status)
  end)

  it("Running tests survive mark_all_stale regardless of order", function()
    local s = testing.new()
    s = testing.update_test(s, { testId = "t1", status = "Running" })
    s = testing.mark_all_stale(s)
    assert.are.equal("Running", s.tests["t1"].status)
  end)

  it("two apply_status_response calls: second overwrites first", function()
    local s = testing.new()
    s = testing.apply_status_response(s, {
      tests = { { testId = "t1", displayName = "v1", status = "Failed", category = "Unit" } },
    })
    assert.are.equal("Failed", s.tests["t1"].status)

    s = testing.apply_status_response(s, {
      tests = { { testId = "t1", displayName = "v2", status = "Passed", category = "Unit" } },
    })
    assert.are.equal("Passed", s.tests["t1"].status)
    assert.are.equal("v2", s.tests["t1"].displayName)
  end)
end)

-- =============================================================================
-- Model validation: cell model status validation tests
-- =============================================================================

describe("testing.gutter_sign [property]", function()
  it("every valid status produces a non-space sign", function()
    for status, _ in pairs(testing.VALID_TEST_STATUSES) do
      local sign = testing.gutter_sign(status)
      if status ~= "Detected" then
        -- Detected gets ◦ which is non-space, all others are non-space
        assert.is_true(sign.text ~= " ",
          "status '" .. status .. "' should produce a visible sign")
      end
    end
  end)

  it("every valid status produces a SageFs highlight group", function()
    for status, _ in pairs(testing.VALID_TEST_STATUSES) do
      local sign = testing.gutter_sign(status)
      assert.truthy(sign.hl:find("^SageFs"),
        "status '" .. status .. "' should use SageFs highlight, got: " .. sign.hl)
    end
  end)
end)

-- ─── to_diagnostics: convert failed tests to vim.diagnostic shape ────────────

describe("testing.to_diagnostics", function()
  local function make_origin(file, line)
    return { Case = "SourceMapped", Fields = { file, line } }
  end

  it("returns empty for state with no failures", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1", displayName = "passes",
      status = "Passed", origin = make_origin("/src/app.fs", 10),
    })
    local diags = testing.to_diagnostics(s, "/src/app.fs")
    assert.are.equal(0, #diags)
  end)

  it("returns diagnostic for a failed test with file and line", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1", displayName = "addition fails",
      status = "Failed", origin = make_origin("/src/math.fs", 15),
    })
    s = testing.update_result(s, "t1", "Failed", "Expected 4 but got 5")
    local diags = testing.to_diagnostics(s, "/src/math.fs")
    assert.are.equal(1, #diags)
    assert.are.equal(14, diags[1].lnum)  -- 0-indexed
    assert.are.equal(0, diags[1].col)
    assert.are.equal(1, diags[1].severity)  -- ERROR
    assert.truthy(diags[1].message:find("addition fails"))
    assert.are.equal("sagefs_tests", diags[1].source)
  end)

  it("includes output in message when available", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1", displayName = "math test",
      status = "Failed", origin = make_origin("/src/a.fs", 5),
    })
    s = testing.update_result(s, "t1", "Failed", "Expected 1 got 2")
    local diags = testing.to_diagnostics(s, "/src/a.fs")
    assert.truthy(diags[1].message:find("Expected 1 got 2"))
  end)

  it("filters to only the requested file", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1", displayName = "fail a",
      status = "Failed", origin = make_origin("/src/a.fs", 1),
    })
    s = testing.update_test(s, {
      testId = "t2", displayName = "fail b",
      status = "Failed", origin = make_origin("/src/b.fs", 2),
    })
    local diags_a = testing.to_diagnostics(s, "/src/a.fs")
    assert.are.equal(1, #diags_a)
    local diags_b = testing.to_diagnostics(s, "/src/b.fs")
    assert.are.equal(1, #diags_b)
  end)

  it("ignores tests without a file", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1", displayName = "orphan",
      status = "Failed",
    })
    local diags = testing.to_diagnostics(s, "/src/a.fs")
    assert.are.equal(0, #diags)
  end)

  it("returns empty for nil file argument", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1", displayName = "fail",
      status = "Failed", origin = make_origin("/src/a.fs", 1),
    })
    local diags = testing.to_diagnostics(s, nil)
    assert.are.equal(0, #diags)
  end)

  it("defaults line to 0 when test has no line", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1", displayName = "no line",
      status = "Failed", origin = make_origin("/src/a.fs", 1),
    })
    -- Remove line to test the default
    s.tests["t1"].line = nil
    local diags = testing.to_diagnostics(s, "/src/a.fs")
    assert.are.equal(1, #diags)
    assert.are.equal(0, diags[1].lnum)
  end)

  it("returns all_files diagnostics when no file specified", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1", displayName = "fail a",
      status = "Failed", origin = make_origin("/src/a.fs", 1),
    })
    s = testing.update_test(s, {
      testId = "t2", displayName = "fail b",
      status = "Failed", origin = make_origin("/src/b.fs", 2),
    })
    local grouped = testing.to_diagnostics_grouped(s)
    assert.are.equal(1, #grouped["/src/a.fs"])
    assert.are.equal(1, #grouped["/src/b.fs"])
  end)
end)

-- ─── format_panel_content: test panel buffer content ─────────────────────────

describe("testing.format_panel_content", function()
  it("returns header line with summary", function()
    local s = testing.new()
    s.tests["t1"] = { displayName = "test one", status = "Passed", category = "Unit" }
    s.tests["t2"] = { displayName = "test two", status = "Failed", category = "Unit" }
    local lines = testing.format_panel_content(s)
    assert.is_table(lines)
    assert.truthy(#lines > 0)
    -- First line should contain summary info
    assert.truthy(lines[1]:find("1 ✓") or lines[1]:find("tests"))
  end)

  it("includes separator after header", function()
    local s = testing.new()
    s.tests["t1"] = { displayName = "test one", status = "Passed", category = "Unit" }
    local lines = testing.format_panel_content(s)
    -- Should have a separator line (dashes or empty)
    local found_sep = false
    for i = 1, math.min(3, #lines) do
      if lines[i]:match("^%-%-") or lines[i] == "" then
        found_sep = true
      end
    end
    assert.is_true(found_sep, "expected separator line near top")
  end)

  it("lists all tests with status icons", function()
    local s = testing.new()
    s.tests["t1"] = { displayName = "alpha", status = "Passed", category = "Unit" }
    s.tests["t2"] = { displayName = "beta", status = "Failed", category = "Unit" }
    s.tests["t3"] = { displayName = "gamma", status = "Running", category = "Unit" }
    local lines = testing.format_panel_content(s)
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("alpha"))
    assert.truthy(text:find("beta"))
    assert.truthy(text:find("gamma"))
    -- Status icons should appear
    assert.truthy(text:find("✓") or text:find("✖") or text:find("⏳"))
  end)

  it("returns meaningful content for empty state", function()
    local s = testing.new()
    local lines = testing.format_panel_content(s)
    assert.is_table(lines)
    assert.truthy(#lines > 0)
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("No tests") or text:find("no tests") or text:find("0"))
  end)

  it("sorts failed tests first", function()
    local s = testing.new()
    s.tests["t1"] = { displayName = "aaa passing", status = "Passed", category = "Unit" }
    s.tests["t2"] = { displayName = "zzz failing", status = "Failed", category = "Unit" }
    local lines = testing.format_panel_content(s)
    -- Find positions of the test names
    local fail_pos, pass_pos
    for i, l in ipairs(lines) do
      if not fail_pos and l:find("zzz failing") then fail_pos = i end
      if not pass_pos and l:find("aaa passing") then pass_pos = i end
    end
    assert.is_not_nil(fail_pos, "failed test should appear")
    assert.is_not_nil(pass_pos, "passed test should appear")
    assert.is_true(fail_pos < pass_pos, "failed tests should sort before passed")
  end)

  it("includes output for failed tests", function()
    local s = testing.new()
    s.tests["t1"] = { displayName = "broken test", status = "Failed", category = "Unit", output = "Expected 42 but got 0" }
    local lines = testing.format_panel_content(s)
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("Expected 42 but got 0"), "should include failure output")
  end)
end)

-- ─── format_panel_entries: structured metadata for navigation ─────────────────

describe("testing.format_panel_entries", function()
  it("returns entries with file and line metadata", function()
    local s = testing.new()
    s.tests["t1"] = {
      displayName = "adds numbers",
      status = "Passed",
      category = "Unit",
      file = "/src/math.fs",
      line = 42,
    }
    local entries = testing.format_panel_entries(s)
    local found = false
    for _, e in ipairs(entries) do
      if e.text:find("adds numbers") then
        found = true
        assert.are.equal("/src/math.fs", e.file)
        assert.are.equal(42, e.line)
        break
      end
    end
    assert.is_true(found, "should find entry for the test")
  end)

  it("includes nil file/line for tests without location", function()
    local s = testing.new()
    s.tests["t1"] = { displayName = "no location", status = "Failed", category = "Unit" }
    local entries = testing.format_panel_entries(s)
    local found = false
    for _, e in ipairs(entries) do
      if e.text:find("no location") then
        found = true
        assert.is_nil(e.file)
        assert.is_nil(e.line)
        break
      end
    end
    assert.is_true(found, "should find entry without location")
  end)

  it("sorts failed entries before passed", function()
    local s = testing.new()
    s.tests["t1"] = { displayName = "pass", status = "Passed", category = "Unit" }
    s.tests["t2"] = { displayName = "fail", status = "Failed", category = "Unit" }
    local entries = testing.format_panel_entries(s)
    local fail_idx, pass_idx
    for i, e in ipairs(entries) do
      if not fail_idx and e.text:find("fail") then fail_idx = i end
      if not pass_idx and e.text:find("pass") then pass_idx = i end
    end
    assert.is_not_nil(fail_idx)
    assert.is_not_nil(pass_idx)
    assert.is_true(fail_idx < pass_idx)
  end)
end)

-- ─── format_file_panel_content: per-file test summary ────────────────────────

describe("testing.format_file_panel_content", function()
  it("filters tests to the given file", function()
    local s = testing.new()
    s.tests["t1"] = { displayName = "in file", status = "Passed", category = "Unit", file = "/src/a.fs" }
    s.tests["t2"] = { displayName = "other file", status = "Passed", category = "Unit", file = "/src/b.fs" }
    local lines = testing.format_file_panel_content(s, "/src/a.fs")
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("in file"), "should include tests from target file")
    assert.falsy(text:find("other file"), "should not include tests from other files")
  end)

  it("shows meaningful message when no tests for file", function()
    local s = testing.new()
    s.tests["t1"] = { displayName = "other", status = "Passed", category = "Unit", file = "/src/b.fs" }
    local lines = testing.format_file_panel_content(s, "/src/a.fs")
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("[Nn]o tests") or text:find("empty"), "should show no-tests message")
  end)
end)

-- ─── Enriched batch payload (TestResultsBatchPayload from SageFs) ────────────

-- Helper for building Origin DU values in tests
local function make_origin(file, line)
  return { Case = "SourceMapped", Fields = { file, line } }
end

describe("testing.handle_results_batch enriched payload", function()
  it("accepts Entries (PascalCase) from JsonFSharpConverter", function()
    local s = testing.new()
    s = testing.handle_results_batch(s, {
      Entries = {
        { TestId = "t1", DisplayName = "Test One", FullName = "Ns.Test One",
          Origin = { Case = "SourceMapped", Fields = { "/src/a.fs", 10 } },
          Framework = "Expecto", Category = "Unit", CurrentPolicy = "OnEveryChange",
          Status = "Passed", PreviousStatus = "Detected" },
      },
      Summary = { Total = 1, Passed = 1, Failed = 0, Stale = 0, Running = 0, Disabled = 0 },
      Generation = { Case = "RunGeneration", Fields = { 1 } },
      Freshness = "Fresh",
      Completion = { Case = "Complete", Fields = { 1, 1 } },
    })
    assert.are.equal(1, testing.test_count(s))
    assert.are.equal("Passed", s.tests["t1"].status)
  end)

  it("accepts entries (camelCase) from camelCase serializer", function()
    local s = testing.new()
    s = testing.handle_results_batch(s, {
      entries = {
        { testId = "t2", displayName = "Test Two", fullName = "Ns.Test Two",
          origin = { Case = "SourceMapped", Fields = { "/src/b.fs", 20 } },
          framework = "Expecto", category = "Unit", currentPolicy = "OnEveryChange",
          status = "Failed", previousStatus = "Detected" },
      },
      summary = { total = 1, passed = 0, failed = 1, stale = 0, running = 0, disabled = 0 },
    })
    assert.are.equal(1, testing.test_count(s))
    assert.are.equal("Failed", s.tests["t2"].status)
  end)

  it("updates summary from enriched payload", function()
    local s = testing.new()
    s = testing.handle_results_batch(s, {
      Entries = {
        { TestId = "t1", DisplayName = "A", Status = "Passed",
          Origin = { Case = "ReflectionOnly" },
          Category = "Unit", CurrentPolicy = "OnEveryChange" },
      },
      Summary = { Total = 5, Passed = 3, Failed = 1, Stale = 1, Running = 0, Disabled = 0 },
    })
    assert.are.equal(5, s.summary.total)
    assert.are.equal(3, s.summary.passed)
    assert.are.equal(1, s.summary.failed)
  end)

  it("stores generation and freshness metadata", function()
    local s = testing.new()
    s = testing.handle_results_batch(s, {
      Entries = {},
      Summary = { Total = 0, Passed = 0, Failed = 0, Stale = 0, Running = 0, Disabled = 0 },
      Generation = { Case = "RunGeneration", Fields = { 3 } },
      Freshness = "StaleCodeEdited",
      Completion = { Case = "Superseded" },
    })
    assert.are.equal(3, s.generation)
    assert.are.equal("StaleCodeEdited", s.freshness)
    assert.are.equal("Superseded", s.completion)
  end)

  it("still handles legacy results format", function()
    local s = testing.new()
    s = testing.handle_results_batch(s, {
      results = {
        { testId = "t1", status = "Passed", output = "ok" },
      },
    })
    assert.are.equal(1, testing.test_count(s))
    assert.are.equal("Passed", s.tests["t1"].status)
  end)
end)

-- ─── apply_status_response PascalCase (MCP tool response) ────────────────────

describe("testing.apply_status_response PascalCase", function()
  it("handles Enabled (PascalCase) from MCP tool", function()
    local s = testing.new()
    s = testing.apply_status_response(s, {
      Enabled = true,
      Summary = { Total = 10, Passed = 8, Failed = 2, Stale = 0, Running = 0, Disabled = 0 },
    })
    assert.is_true(s.enabled)
    assert.are.equal(10, s.summary.total)
  end)

  it("handles Tests array (PascalCase entries)", function()
    local s = testing.new()
    s = testing.apply_status_response(s, {
      Enabled = true,
      Summary = { Total = 1, Passed = 1, Failed = 0, Stale = 0, Running = 0, Disabled = 0 },
      Tests = {
        { TestId = "t1", DisplayName = "Test", FullName = "Ns.Test",
          Origin = { Case = "SourceMapped", Fields = { "/src/a.fs", 5 } },
          Framework = "Expecto", Category = "Unit", CurrentPolicy = "OnEveryChange",
          Status = "Passed", PreviousStatus = "Detected" },
      },
    })
    assert.are.equal(1, testing.test_count(s))
    assert.are.equal("Passed", s.tests["t1"].status)
    assert.are.equal("/src/a.fs", s.tests["t1"].file)
  end)
end)

-- ─── New state atoms ─────────────────────────────────────────────────────────

describe("testing.new extended state", function()
  it("includes locations table", function()
    local s = testing.new()
    assert.is_not_nil(s.locations)
    assert.are.same({}, s.locations)
  end)

  it("includes providers list", function()
    local s = testing.new()
    assert.is_not_nil(s.providers)
    assert.are.same({}, s.providers)
  end)

  it("includes run_phase as Idle", function()
    local s = testing.new()
    assert.are.equal("Idle", s.run_phase)
  end)

  it("includes generation as 0", function()
    local s = testing.new()
    assert.are.equal(0, s.generation)
  end)

  it("includes freshness as nil", function()
    local s = testing.new()
    assert.is_nil(s.freshness)
  end)

  it("includes completion as nil", function()
    local s = testing.new()
    assert.is_nil(s.completion)
  end)
end)

-- ─── handle_test_locations ───────────────────────────────────────────────────

describe("testing.handle_test_locations", function()
  it("stores source-mapped test locations by file", function()
    local s = testing.new()
    s = testing.handle_test_locations(s, {
      locations = {
        { testId = "t1", file = "/src/a.fs", line = 10 },
        { testId = "t2", file = "/src/a.fs", line = 20 },
        { testId = "t3", file = "/src/b.fs", line = 5 },
      },
    })
    assert.are.equal(2, #s.locations["/src/a.fs"])
    assert.are.equal(1, #s.locations["/src/b.fs"])
  end)

  it("replaces previous locations on update", function()
    local s = testing.new()
    s = testing.handle_test_locations(s, {
      locations = {
        { testId = "t1", file = "/src/a.fs", line = 10 },
      },
    })
    s = testing.handle_test_locations(s, {
      locations = {
        { testId = "t2", file = "/src/a.fs", line = 20 },
      },
    })
    assert.are.equal(1, #s.locations["/src/a.fs"])
    assert.are.equal("t2", s.locations["/src/a.fs"][1].testId)
  end)

  it("is a no-op for nil data", function()
    local s = testing.new()
    local s2 = testing.handle_test_locations(s, nil)
    assert.are.same({}, s2.locations)
  end)
end)

-- ─── handle_providers_detected ───────────────────────────────────────────────

describe("testing.handle_providers_detected", function()
  it("stores provider names", function()
    local s = testing.new()
    s = testing.handle_providers_detected(s, {
      providers = { "Expecto", "xUnit", "NUnit" },
    })
    assert.are.equal(3, #s.providers)
    assert.are.equal("Expecto", s.providers[1])
  end)

  it("replaces existing providers", function()
    local s = testing.new()
    s = testing.handle_providers_detected(s, { providers = { "Expecto" } })
    s = testing.handle_providers_detected(s, { providers = { "xUnit" } })
    assert.are.equal(1, #s.providers)
    assert.are.equal("xUnit", s.providers[1])
  end)

  it("is a no-op for nil data", function()
    local s = testing.new()
    local s2 = testing.handle_providers_detected(s, nil)
    assert.are.same({}, s2.providers)
  end)
end)

-- ─── handle_run_phase_changed ────────────────────────────────────────────────

describe("testing.handle_run_phase_changed", function()
  it("transitions to Running with generation", function()
    local s = testing.new()
    s = testing.handle_run_phase_changed(s, { phase = "Running", generation = 2 })
    assert.are.equal("Running", s.run_phase)
    assert.are.equal(2, s.generation)
  end)

  it("transitions to Idle", function()
    local s = testing.new()
    s.run_phase = "Running"
    s = testing.handle_run_phase_changed(s, { phase = "Idle" })
    assert.are.equal("Idle", s.run_phase)
  end)

  it("transitions to RunningButEdited", function()
    local s = testing.new()
    s = testing.handle_run_phase_changed(s, { phase = "RunningButEdited", generation = 1 })
    assert.are.equal("RunningButEdited", s.run_phase)
  end)

  it("is a no-op for nil data", function()
    local s = testing.new()
    local s2 = testing.handle_run_phase_changed(s, nil)
    assert.are.equal("Idle", s2.run_phase)
  end)
end)

-- ─── annotations_for_file ────────────────────────────────────────────────────

describe("testing.annotations_for_file", function()
  it("returns annotations for tests in a specific file", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1", displayName = "passing test",
      status = "Passed", origin = make_origin("/src/a.fs", 10),
    })
    s = testing.update_test(s, {
      testId = "t2", displayName = "failing test",
      status = "Failed", origin = make_origin("/src/a.fs", 20),
    })
    s = testing.update_test(s, {
      testId = "t3", displayName = "other file",
      status = "Passed", origin = make_origin("/src/b.fs", 5),
    })
    local anns = testing.annotations_for_file(s, "/src/a.fs")
    assert.are.equal(2, #anns)
  end)

  it("includes line, icon, and tooltip in each annotation", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1", displayName = "my test",
      status = "Passed", origin = make_origin("/src/a.fs", 15),
    })
    local anns = testing.annotations_for_file(s, "/src/a.fs")
    assert.are.equal(1, #anns)
    assert.are.equal(15, anns[1].line)
    assert.are.equal("TestPassed", anns[1].icon)
    assert.truthy(anns[1].tooltip:find("my test"))
  end)

  it("maps all statuses to correct icons", function()
    local status_to_icon = {
      Detected = "TestDiscovered",
      Running = "TestRunning",
      Passed = "TestPassed",
      Failed = "TestFailed",
      Skipped = "TestSkipped",
      Stale = "TestDiscovered",
    }
    for status, expected_icon in pairs(status_to_icon) do
      local s = testing.new()
      s = testing.update_test(s, {
        testId = "t1", displayName = "test",
        status = status, origin = make_origin("/src/a.fs", 1),
      })
      local anns = testing.annotations_for_file(s, "/src/a.fs")
      assert.are.equal(expected_icon, anns[1].icon, "status " .. status .. " should map to " .. expected_icon)
    end
  end)

  it("returns empty for file with no tests", function()
    local s = testing.new()
    local anns = testing.annotations_for_file(s, "/src/nonexistent.fs")
    assert.are.equal(0, #anns)
  end)

  it("sorts annotations by line number", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1", displayName = "later",
      status = "Passed", origin = make_origin("/src/a.fs", 50),
    })
    s = testing.update_test(s, {
      testId = "t2", displayName = "earlier",
      status = "Failed", origin = make_origin("/src/a.fs", 10),
    })
    local anns = testing.annotations_for_file(s, "/src/a.fs")
    assert.are.equal(10, anns[1].line)
    assert.are.equal(50, anns[2].line)
  end)
end)

-- ─── normalize_entry (PascalCase → camelCase) ────────────────────────────────

describe("testing.normalize_entry", function()
  it("converts PascalCase keys to camelCase", function()
    local entry = testing.normalize_entry({
      TestId = "t1", DisplayName = "Test", FullName = "Ns.Test",
      Origin = { Case = "SourceMapped", Fields = { "/a.fs", 1 } },
      Framework = "Expecto", Category = "Unit",
      CurrentPolicy = "OnEveryChange", Status = "Passed",
    })
    assert.are.equal("t1", entry.testId)
    assert.are.equal("Test", entry.displayName)
    assert.are.equal("Ns.Test", entry.fullName)
    assert.are.equal("Expecto", entry.framework)
    assert.are.equal("Unit", entry.category)
    assert.are.equal("OnEveryChange", entry.currentPolicy)
    assert.are.equal("Passed", entry.status)
  end)

  it("passes through already-camelCase entries", function()
    local entry = testing.normalize_entry({
      testId = "t1", displayName = "Test", status = "Passed",
    })
    assert.are.equal("t1", entry.testId)
    assert.are.equal("Test", entry.displayName)
    assert.are.equal("Passed", entry.status)
  end)

  it("preserves origin as-is", function()
    local origin = { Case = "SourceMapped", Fields = { "/a.fs", 5 } }
    local entry = testing.normalize_entry({
      TestId = "t1", Origin = origin, Status = "Passed",
    })
    assert.are.same(origin, entry.origin)
  end)

  it("unwraps DU-wrapped Status from PascalCase entry", function()
    local entry = testing.normalize_entry({
      TestId = "t1", DisplayName = "Test", Status = { Case = "Stale" },
    })
    assert.are.equal("Stale", entry.status)
  end)

  it("unwraps DU-wrapped status from camelCase entry", function()
    local entry = testing.normalize_entry({
      testId = "t1", displayName = "Test", status = { Case = "Passed" },
    })
    assert.are.equal("Passed", entry.status)
  end)

  it("unwraps DU-wrapped Category and CurrentPolicy", function()
    local entry = testing.normalize_entry({
      TestId = "t1", DisplayName = "Test", Status = { Case = "Detected" },
      Category = { Case = "Unit" }, CurrentPolicy = { Case = "OnEveryChange" },
    })
    assert.are.equal("Unit", entry.category)
    assert.are.equal("OnEveryChange", entry.currentPolicy)
    assert.are.equal("Detected", entry.status)
  end)

  it("handles all DU status variants", function()
    for _, s in ipairs({"Detected", "Queued", "Running", "Passed", "Failed", "Skipped", "Stale", "PolicyDisabled"}) do
      local entry = testing.normalize_entry({ TestId = "t1", Status = { Case = s } })
      assert.are.equal(s, entry.status, "failed for " .. s)
    end
  end)

  it("unwraps PreviousStatus DU", function()
    local entry = testing.normalize_entry({
      TestId = "t1", Status = { Case = "Passed" }, PreviousStatus = { Case = "Stale" },
    })
    assert.are.equal("Stale", entry.previousStatus)
  end)
end)

-- ─── handle_results_batch with DU-wrapped entries ────────────────────────────

describe("testing.handle_results_batch with DU entries", function()
  it("populates tests from entries with all DU-wrapped fields", function()
    local state = testing.new()
    state = testing.handle_results_batch(state, {
      Entries = {
        { TestId = "abc", DisplayName = "test one", FullName = "Suite/test one",
          Origin = { Case = "ReflectionOnly" }, Status = { Case = "Stale" },
          Category = { Case = "Unit" }, CurrentPolicy = { Case = "OnEveryChange" },
          Framework = "expecto" },
        { TestId = "def", DisplayName = "test two", FullName = "Suite/test two",
          Origin = { Case = "SourceMapped", Fields = { "/a.fs", 10 } }, Status = { Case = "Passed" },
          Category = { Case = "Integration" }, CurrentPolicy = { Case = "OnSaveOnly" },
          Framework = "expecto" },
      },
      Generation = 0,
      Freshness = { Case = "Fresh" },
      Completion = { Case = "Complete", Fields = { 2, 2 } },
    })
    assert.are.equal(2, testing.test_count(state))
    assert.are.equal("Stale", state.tests["abc"].status)
    assert.are.equal("Unit", state.tests["abc"].category)
    assert.are.equal("OnEveryChange", state.tests["abc"].policy)
    assert.are.equal("Passed", state.tests["def"].status)
    assert.are.equal("Integration", state.tests["def"].category)
    assert.are.equal("/a.fs", state.tests["def"].file)
    assert.are.equal(10, state.tests["def"].line)
  end)

  it("populates tests from 50-entry batch (real SageFs shape)", function()
    local entries = {}
    for i = 1, 50 do
      table.insert(entries, {
        TestId = string.format("T%04d", i),
        DisplayName = "test " .. i,
        FullName = "Suite/test " .. i,
        Origin = { Case = "ReflectionOnly" },
        Status = { Case = "Stale" },
        Category = { Case = "Unit" },
        CurrentPolicy = { Case = "OnEveryChange" },
        Framework = "expecto",
      })
    end
    local state = testing.new()
    state = testing.handle_results_batch(state, {
      Entries = entries,
      Generation = 0,
      Freshness = { Case = "Fresh" },
      Completion = { Case = "Complete", Fields = { 50, 50 } },
    })
    assert.are.equal(50, testing.test_count(state))
  end)
end)

-- ─── parse_generation (RunGeneration DU from F#) ─────────────────────────────

describe("testing.parse_generation", function()
  it("extracts int from RunGeneration DU", function()
    assert.are.equal(3, testing.parse_generation({ Case = "RunGeneration", Fields = { 3 } }))
  end)

  it("extracts int from plain number", function()
    assert.are.equal(5, testing.parse_generation(5))
  end)

  it("returns 0 for nil", function()
    assert.are.equal(0, testing.parse_generation(nil))
  end)

  it("returns 0 for unrecognized shape", function()
    assert.are.equal(0, testing.parse_generation("invalid"))
  end)
end)

-- ─── parse_completion (BatchCompletion DU from F#) ───────────────────────────

describe("testing.parse_completion", function()
  it("parses Complete DU", function()
    assert.are.equal("Complete", testing.parse_completion({ Case = "Complete", Fields = { 10, 10 } }))
  end)

  it("parses Partial DU", function()
    assert.are.equal("Partial", testing.parse_completion({ Case = "Partial", Fields = { 10, 5 } }))
  end)

  it("parses Superseded DU", function()
    assert.are.equal("Superseded", testing.parse_completion({ Case = "Superseded" }))
  end)

  it("parses plain string", function()
    assert.are.equal("Complete", testing.parse_completion("Complete"))
  end)

  it("returns nil for nil input", function()
    assert.is_nil(testing.parse_completion(nil))
  end)
end)

-- ─── handle_test_summary (new SSE event from SageFs) ─────────────────────────

describe("testing.handle_test_summary", function()
  it("updates summary from PascalCase TestSummary", function()
    local s = testing.new()
    s = testing.handle_test_summary(s, {
      Total = 10, Passed = 7, Failed = 2, Stale = 1, Running = 0, Disabled = 0,
    })
    assert.are.equal(10, s.summary.total)
    assert.are.equal(7, s.summary.passed)
    assert.are.equal(2, s.summary.failed)
    assert.are.equal(1, s.summary.stale)
  end)

  it("updates summary from camelCase", function()
    local s = testing.new()
    s = testing.handle_test_summary(s, {
      total = 5, passed = 5, failed = 0, stale = 0, running = 0, disabled = 0,
    })
    assert.are.equal(5, s.summary.total)
    assert.are.equal(5, s.summary.passed)
  end)

  it("does not override enabled state", function()
    local s = testing.new()
    assert.is_false(s.enabled)
    s = testing.handle_test_summary(s, {
      Total = 3, Passed = 3, Failed = 0, Stale = 0, Running = 0, Disabled = 0,
    })
    assert.is_false(s.enabled)  -- enabled is set by set_enabled, not by summary
  end)

  it("is a no-op for nil data", function()
    local s = testing.new()
    s.summary.total = 42
    s = testing.handle_test_summary(s, nil)
    assert.are.equal(42, s.summary.total)
  end)
end)

-- ─── filter_by_covering_file: tests via coverage annotations ─────────────────

describe("testing.filter_by_covering_file", function()
  local annotations = require("sagefs.annotations")

  it("returns tests that cover a production file", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1", displayName = "pong test 1",
      status = "Passed", origin = { Case = "SourceMapped", Fields = { "/tests/PongTests.fs", 10 } },
    })
    s = testing.update_test(s, {
      testId = "t2", displayName = "pong test 2",
      status = "Failed", origin = { Case = "SourceMapped", Fields = { "/tests/PongTests.fs", 20 } },
    })
    -- annotations state with CoveringTestIds pointing back to t1, t2
    local ann_state = annotations.new()
    ann_state = annotations.handle_file_annotations(ann_state, {
      FilePath = "/src/Pong.fs",
      CoverageAnnotations = {
        { Line = 5, Detail = "Covered", CoveringTestIds = { "t1" } },
        { Line = 10, Detail = "Covered", CoveringTestIds = { "t1", "t2" } },
        { Line = 15, Detail = "NotCovered", CoveringTestIds = {} },
      },
    })

    local results = testing.filter_by_covering_file(s, ann_state, "/src/Pong.fs")
    assert.are.equal(2, #results)
    local ids = {}
    for _, r in ipairs(results) do ids[r.testId] = true end
    assert.is_true(ids["t1"])
    assert.is_true(ids["t2"])
  end)

  it("returns empty when no coverage annotations exist", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1", displayName = "some test",
      status = "Passed", origin = { Case = "SourceMapped", Fields = { "/tests/Tests.fs", 1 } },
    })
    local ann_state = annotations.new()
    local results = testing.filter_by_covering_file(s, ann_state, "/src/Unknown.fs")
    assert.are.equal(0, #results)
  end)

  it("returns empty when annotations_state is nil", function()
    local s = testing.new()
    local results = testing.filter_by_covering_file(s, nil, "/src/Foo.fs")
    assert.are.equal(0, #results)
  end)

  it("deduplicates test ids across coverage lines", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "t1", displayName = "test 1",
      status = "Passed", origin = { Case = "SourceMapped", Fields = { "/tests/T.fs", 1 } },
    })
    local ann_state = annotations.new()
    ann_state = annotations.handle_file_annotations(ann_state, {
      FilePath = "/src/Prod.fs",
      CoverageAnnotations = {
        { Line = 1, Detail = "Covered", CoveringTestIds = { "t1" } },
        { Line = 2, Detail = "Covered", CoveringTestIds = { "t1" } },
        { Line = 3, Detail = "Covered", CoveringTestIds = { "t1" } },
      },
    })
    local results = testing.filter_by_covering_file(s, ann_state, "/src/Prod.fs")
    assert.are.equal(1, #results)
    assert.are.equal("t1", results[1].testId)
  end)
end)