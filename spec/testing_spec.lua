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

-- ─── set_enabled: toggle live testing ────────────────────────────────────────

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
