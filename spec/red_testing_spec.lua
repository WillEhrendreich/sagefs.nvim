-- RED tests for planned live testing features
-- These tests define the API contract for functions that DON'T EXIST YET.
-- Every test here should FAIL until the feature is implemented.

require("spec.helper")
local testing = require("sagefs.testing")

-- ─── format_test_list: panel display ─────────────────────────────────────────
-- Needed for: Live test status panel (floating window / quickfix)

describe("testing.format_test_list [RED]", function()
  local state

  before_each(function()
    state = testing.new()
    state = testing.set_enabled(state, true)
    testing.update_test(state, {
      testId = "aaa", displayName = "should add", fullName = "Math.should add",
      origin = { Case = "SourceMapped", Fields = { "src/Math.fs", 10 } },
      framework = "Expecto", category = "Unit", currentPolicy = "OnEveryChange",
      status = "Passed",
    })
    testing.update_test(state, {
      testId = "bbb", displayName = "should subtract", fullName = "Math.should subtract",
      origin = { Case = "SourceMapped", Fields = { "src/Math.fs", 20 } },
      framework = "Expecto", category = "Unit", currentPolicy = "OnEveryChange",
      status = "Failed",
    })
    testing.update_test(state, {
      testId = "ccc", displayName = "should connect", fullName = "Net.should connect",
      origin = { Case = "SourceMapped", Fields = { "src/Net.fs", 5 } },
      framework = "Expecto", category = "Integration", currentPolicy = "OnSaveOnly",
      status = "Running",
    })
  end)

  it("returns a list of formatted lines", function()
    local lines = testing.format_test_list(state)
    assert.is_table(lines)
    assert.is_true(#lines >= 3)
  end)

  it("each line contains display name and status indicator", function()
    local lines = testing.format_test_list(state)
    local found_add = false
    for _, line in ipairs(lines) do
      if line:find("should add") and line:find("✓") then
        found_add = true
      end
    end
    assert.is_true(found_add, "expected line with 'should add' and '✓'")
  end)

  it("shows failure indicator for failed tests", function()
    local lines = testing.format_test_list(state)
    local found = false
    for _, line in ipairs(lines) do
      if line:find("should subtract") and line:find("✖") then
        found = true
      end
    end
    assert.is_true(found, "expected line with 'should subtract' and '✖'")
  end)

  it("returns empty list for empty state", function()
    local empty = testing.new()
    local lines = testing.format_test_list(empty)
    assert.is_table(lines)
    assert.are.equal(0, #lines)
  end)
end)

-- ─── format_test_list_by_file: grouped panel display ─────────────────────────
-- Needed for: Live test status panel grouped by source file

describe("testing.format_test_list_by_file [RED]", function()
  local state

  before_each(function()
    state = testing.new()
    testing.update_test(state, {
      testId = "aaa", displayName = "test A", fullName = "File1.test A",
      origin = { Case = "SourceMapped", Fields = { "src/File1.fs", 10 } },
      category = "Unit", currentPolicy = "OnEveryChange", status = "Passed",
    })
    testing.update_test(state, {
      testId = "bbb", displayName = "test B", fullName = "File1.test B",
      origin = { Case = "SourceMapped", Fields = { "src/File1.fs", 20 } },
      category = "Unit", currentPolicy = "OnEveryChange", status = "Failed",
    })
    testing.update_test(state, {
      testId = "ccc", displayName = "test C", fullName = "File2.test C",
      origin = { Case = "SourceMapped", Fields = { "src/File2.fs", 5 } },
      category = "Unit", currentPolicy = "OnEveryChange", status = "Passed",
    })
  end)

  it("returns a table keyed by file path", function()
    local grouped = testing.format_test_list_by_file(state)
    assert.is_table(grouped)
    assert.is_not_nil(grouped["src/File1.fs"])
    assert.is_not_nil(grouped["src/File2.fs"])
  end)

  it("groups correct tests under each file", function()
    local grouped = testing.format_test_list_by_file(state)
    assert.are.equal(2, #grouped["src/File1.fs"])
    assert.are.equal(1, #grouped["src/File2.fs"])
  end)

  it("tests without file go under a nil/unknown key", function()
    testing.update_test(state, {
      testId = "ddd", displayName = "orphan", fullName = "orphan",
      origin = { Case = "ReflectionOnly" },
      category = "Unit", currentPolicy = "OnEveryChange", status = "Detected",
    })
    local grouped = testing.format_test_list_by_file(state)
    -- Should have a key for tests with no file mapping
    local orphan_count = 0
    for key, tests in pairs(grouped) do
      for _, t in ipairs(tests) do
        if t.testId == "ddd" then orphan_count = orphan_count + 1 end
      end
    end
    assert.are.equal(1, orphan_count)
  end)
end)

-- ─── filter_by_category ──────────────────────────────────────────────────────
-- Needed for: filtering tests before display or running

describe("testing.filter_by_category [RED]", function()
  local state

  before_each(function()
    state = testing.new()
    testing.update_test(state, {
      testId = "u1", displayName = "unit 1", fullName = "u1",
      category = "Unit", currentPolicy = "OnEveryChange", status = "Passed",
    })
    testing.update_test(state, {
      testId = "i1", displayName = "integ 1", fullName = "i1",
      category = "Integration", currentPolicy = "OnSaveOnly", status = "Failed",
    })
    testing.update_test(state, {
      testId = "u2", displayName = "unit 2", fullName = "u2",
      category = "Unit", currentPolicy = "OnEveryChange", status = "Running",
    })
  end)

  it("returns only tests matching the category", function()
    local units = testing.filter_by_category(state, "Unit")
    assert.are.equal(2, #units)
    for _, t in ipairs(units) do
      assert.are.equal("Unit", t.category)
    end
  end)

  it("returns empty for category with no tests", function()
    local browsers = testing.filter_by_category(state, "Browser")
    assert.are.equal(0, #browsers)
  end)

  it("rejects invalid category", function()
    local result = testing.filter_by_category(state, "Bogus")
    -- Should return empty or error — not crash
    assert.is_table(result)
    assert.are.equal(0, #result)
  end)
end)

-- ─── format_picker_items: vim.ui.select integration ──────────────────────────
-- Needed for: Run policy controls picker

describe("testing.format_picker_items [RED]", function()
  it("formats categories with current policies for picker", function()
    local state = testing.new()
    testing.set_run_policy(state, "Unit", "OnEveryChange")
    testing.set_run_policy(state, "Integration", "OnSaveOnly")
    testing.set_run_policy(state, "Browser", "Disabled")

    local items = testing.format_picker_items(state)
    assert.is_table(items)
    assert.is_true(#items >= 3)

    -- Each item should have a label and a value
    for _, item in ipairs(items) do
      assert.is_string(item.label)
      assert.is_string(item.category)
      assert.is_string(item.policy)
    end
  end)

  it("shows all 6 categories even without explicit policy (defaults)", function()
    local state = testing.new()
    local items = testing.format_picker_items(state)
    assert.are.equal(6, #items)
  end)

  it("labels include both category name and policy", function()
    local state = testing.new()
    testing.set_run_policy(state, "Unit", "OnDemand")
    local items = testing.format_picker_items(state)
    local found = false
    for _, item in ipairs(items) do
      if item.category == "Unit" then
        assert.is_truthy(item.label:find("Unit"))
        assert.is_truthy(item.label:find("OnDemand") or item.label:find("demand"))
        found = true
      end
    end
    assert.is_true(found)
  end)
end)

-- ─── build_run_request: MCP tool params ──────────────────────────────────────
-- Needed for: Explicit test runner command

describe("testing.build_run_request [RED]", function()
  it("builds request with no filters", function()
    local req = testing.build_run_request({})
    assert.is_table(req)
    assert.are.equal("", req.pattern or "")
    assert.are.equal("", req.category or "")
  end)

  it("builds request with pattern filter", function()
    local req = testing.build_run_request({ pattern = "should add" })
    assert.are.equal("should add", req.pattern)
  end)

  it("builds request with category filter", function()
    local req = testing.build_run_request({ category = "Unit" })
    assert.are.equal("Unit", req.category)
  end)

  it("builds request with both filters", function()
    local req = testing.build_run_request({ pattern = "math", category = "Property" })
    assert.are.equal("math", req.pattern)
    assert.are.equal("Property", req.category)
  end)

  it("rejects invalid category in request", function()
    local req, err = testing.build_run_request({ category = "Bogus" })
    assert.is_not_nil(err)
  end)
end)

-- ─── format_pipeline_trace: debug display ────────────────────────────────────
-- Needed for: Pipeline trace command (debugging the three-speed pipeline)

describe("testing.format_pipeline_trace [RED]", function()
  it("formats a pipeline trace response into readable lines", function()
    local trace_data = {
      enabled = true,
      running = false,
      providers = { "Expecto", "xUnit" },
      runPolicies = {
        { category = "Unit", policy = "OnEveryChange" },
        { category = "Integration", policy = "OnSaveOnly" },
      },
      summary = { total = 42, passed = 40, failed = 2, stale = 0, running = 0 },
    }
    local lines = testing.format_pipeline_trace(trace_data)
    assert.is_table(lines)
    assert.is_true(#lines >= 3)
  end)

  it("includes enabled/disabled status", function()
    local lines = testing.format_pipeline_trace({ enabled = false })
    local found = false
    for _, line in ipairs(lines) do
      if line:find("[Dd]isabled") then found = true end
    end
    assert.is_true(found, "should mention disabled status")
  end)

  it("lists providers", function()
    local lines = testing.format_pipeline_trace({
      enabled = true,
      providers = { "Expecto", "xUnit", "NUnit" },
    })
    local found_expecto = false
    for _, line in ipairs(lines) do
      if line:find("Expecto") then found_expecto = true end
    end
    assert.is_true(found_expecto)
  end)

  it("returns informative message for nil data", function()
    local lines = testing.format_pipeline_trace(nil)
    assert.is_table(lines)
    assert.is_true(#lines >= 1)
  end)
end)

-- ─── format_statusline: testing statusline component ─────────────────────────
-- Needed for: Statusline integration showing test summary

describe("testing.format_statusline [RED]", function()
  it("returns empty string when disabled", function()
    local state = testing.new()
    assert.are.equal("", testing.format_statusline(state))
  end)

  it("shows compact summary when enabled with tests", function()
    local state = testing.new()
    state = testing.set_enabled(state, true)
    testing.update_test(state, {
      testId = "a", displayName = "a", fullName = "a",
      category = "Unit", currentPolicy = "OnEveryChange", status = "Passed",
    })
    testing.update_test(state, {
      testId = "b", displayName = "b", fullName = "b",
      category = "Unit", currentPolicy = "OnEveryChange", status = "Failed",
    })
    local line = testing.format_statusline(state)
    assert.is_string(line)
    assert.is_truthy(line:find("1") and line:find("✓"))
    assert.is_truthy(line:find("1") and line:find("✖"))
  end)

  it("shows all-pass indicator when everything passes", function()
    local state = testing.new()
    state = testing.set_enabled(state, true)
    for i = 1, 5 do
      testing.update_test(state, {
        testId = "t" .. i, displayName = "t" .. i, fullName = "t" .. i,
        category = "Unit", currentPolicy = "OnEveryChange", status = "Passed",
      })
    end
    local line = testing.format_statusline(state)
    assert.is_truthy(line:find("5"))
    assert.is_truthy(line:find("✓"))
    -- Should NOT contain failure indicator
    assert.is_falsy(line:find("✖"))
  end)
end)
