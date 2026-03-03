-- RED tests for Tier 2: Live Testing UI
-- Tests format_test_list, format_test_list_by_file, filter_by_category,
-- format_picker_items, build_run_request, format_test_trace, format_statusline.
-- These extend the existing red_testing_spec.lua with more thorough coverage
-- and add new tests for features that weren't in the original RED specs.

require("spec.helper")
local testing = require("sagefs.testing")

-- =============================================================================
-- format_test_list: Panel display (extends red_testing_spec.lua)
-- =============================================================================

describe("testing.format_test_list [RED T2]", function()
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

  it("returns a list of strings", function()
    assert.is_function(testing.format_test_list)
    local lines = testing.format_test_list(state)
    assert.is_table(lines)
    for _, l in ipairs(lines) do assert.is_string(l) end
  end)

  it("includes running indicator for running tests", function()
    local lines = testing.format_test_list(state)
    local found = false
    for _, line in ipairs(lines) do
      if line:find("should connect") and line:find("⏳") then
        found = true
      end
    end
    assert.is_true(found, "expected running indicator for 'should connect'")
  end)

  it("sorts failures before passes", function()
    local lines = testing.format_test_list(state)
    local fail_idx, pass_idx
    for i, line in ipairs(lines) do
      if line:find("should subtract") then fail_idx = i end
      if line:find("should add") then pass_idx = i end
    end
    -- Failures should appear before passes
    if fail_idx and pass_idx then
      assert.is_true(fail_idx < pass_idx, "failures should sort before passes")
    end
  end)
end)

-- =============================================================================
-- format_test_list_by_file: Grouped panel display
-- =============================================================================

describe("testing.format_test_list_by_file [RED T2]", function()
  local state

  before_each(function()
    state = testing.new()
    testing.update_test(state, {
      testId = "a1", displayName = "test A", fullName = "F1.test A",
      origin = { Case = "SourceMapped", Fields = { "src/File1.fs", 10 } },
      category = "Unit", currentPolicy = "OnEveryChange", status = "Passed",
    })
    testing.update_test(state, {
      testId = "a2", displayName = "test B", fullName = "F1.test B",
      origin = { Case = "SourceMapped", Fields = { "src/File1.fs", 20 } },
      category = "Unit", currentPolicy = "OnEveryChange", status = "Failed",
    })
    testing.update_test(state, {
      testId = "b1", displayName = "test C", fullName = "F2.test C",
      origin = { Case = "SourceMapped", Fields = { "src/File2.fs", 5 } },
      category = "Unit", currentPolicy = "OnEveryChange", status = "Passed",
    })
  end)

  it("returns a table keyed by file path", function()
    assert.is_function(testing.format_test_list_by_file)
    local grouped = testing.format_test_list_by_file(state)
    assert.is_table(grouped)
    assert.is_not_nil(grouped["src/File1.fs"])
    assert.is_not_nil(grouped["src/File2.fs"])
  end)

  it("each group contains formatted test lines", function()
    local grouped = testing.format_test_list_by_file(state)
    for _, tests in pairs(grouped) do
      assert.is_table(tests)
      for _, t in ipairs(tests) do
        assert.is_table(t)
        assert.is_string(t.displayName)
        assert.is_string(t.status)
      end
    end
  end)
end)

-- =============================================================================
-- filter_by_category
-- =============================================================================

describe("testing.filter_by_category [RED T2]", function()
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
    assert.is_function(testing.filter_by_category)
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

  it("includes testId on each result", function()
    local units = testing.filter_by_category(state, "Unit")
    for _, t in ipairs(units) do
      assert.is_string(t.testId)
    end
  end)
end)

-- =============================================================================
-- format_picker_items: vim.ui.select integration for policy picker
-- =============================================================================

describe("testing.format_picker_items [RED T2]", function()
  it("formats categories with current policies for picker", function()
    assert.is_function(testing.format_picker_items)
    local state = testing.new()
    testing.set_run_policy(state, "Unit", "OnEveryChange")
    testing.set_run_policy(state, "Integration", "OnSaveOnly")
    testing.set_run_policy(state, "Browser", "Disabled")

    local items = testing.format_picker_items(state)
    assert.is_table(items)
    assert.is_true(#items >= 3)
  end)

  it("each item has label, category, and policy fields", function()
    local state = testing.new()
    testing.set_run_policy(state, "Unit", "OnEveryChange")
    local items = testing.format_picker_items(state)
    for _, item in ipairs(items) do
      assert.is_string(item.label)
      assert.is_string(item.category)
      assert.is_string(item.policy)
    end
  end)

  it("shows all 6 categories even with defaults", function()
    local state = testing.new()
    local items = testing.format_picker_items(state)
    assert.are.equal(6, #items)
  end)

  it("labels include category name and policy", function()
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

-- =============================================================================
-- build_run_request: MCP tool params for :SageFsRunTests
-- =============================================================================

describe("testing.build_run_request [RED T2]", function()
  it("builds request with no filters", function()
    assert.is_function(testing.build_run_request)
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

  it("rejects invalid category", function()
    local req, err = testing.build_run_request({ category = "Bogus" })
    assert.is_not_nil(err)
  end)
end)

-- =============================================================================
-- format_test_trace: test trace display
-- =============================================================================

describe("testing.format_test_trace [RED T2]", function()
  it("formats a full test trace response", function()
    assert.is_function(testing.format_test_trace)
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
    local lines = testing.format_test_trace(trace_data)
    assert.is_table(lines)
    assert.is_true(#lines >= 3)
    -- Should contain string content
    for _, l in ipairs(lines) do assert.is_string(l) end
  end)

  it("includes enabled status", function()
    local lines = testing.format_test_trace({ enabled = true })
    local found = false
    for _, line in ipairs(lines) do
      if line:find("[Ee]nabled") then found = true end
    end
    assert.is_true(found)
  end)

  it("includes disabled status", function()
    local lines = testing.format_test_trace({ enabled = false })
    local found = false
    for _, line in ipairs(lines) do
      if line:find("[Dd]isabled") then found = true end
    end
    assert.is_true(found)
  end)

  it("lists providers", function()
    local lines = testing.format_test_trace({
      enabled = true,
      providers = { "Expecto", "xUnit", "NUnit" },
    })
    local found = false
    for _, line in ipairs(lines) do
      if line:find("Expecto") then found = true end
    end
    assert.is_true(found)
  end)

  it("handles nil data gracefully", function()
    local lines = testing.format_test_trace(nil)
    assert.is_table(lines)
    assert.is_true(#lines >= 1)
  end)
end)

-- =============================================================================
-- format_statusline: compact statusline component
-- =============================================================================

describe("testing.format_statusline [RED T2]", function()
  it("returns empty string when disabled", function()
    assert.is_function(testing.format_statusline)
    local state = testing.new()
    assert.are.equal("", testing.format_statusline(state))
  end)

  it("shows pass/fail counts when enabled", function()
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
    assert.is_truthy(line:find("✓"))
    assert.is_truthy(line:find("✖"))
  end)

  it("shows only pass indicator when all pass", function()
    local state = testing.new()
    state = testing.set_enabled(state, true)
    for i = 1, 5 do
      testing.update_test(state, {
        testId = "t" .. i, displayName = "t" .. i, fullName = "t" .. i,
        category = "Unit", currentPolicy = "OnEveryChange", status = "Passed",
      })
    end
    local line = testing.format_statusline(state)
    assert.is_truthy(line:find("✓"))
    assert.is_falsy(line:find("✖"))
  end)

  it("shows running indicator", function()
    local state = testing.new()
    state = testing.set_enabled(state, true)
    testing.update_test(state, {
      testId = "t1", displayName = "t1", fullName = "t1",
      category = "Unit", currentPolicy = "OnEveryChange", status = "Running",
    })
    local line = testing.format_statusline(state)
    assert.is_truthy(line:find("⏳"))
  end)

  it("returns non-empty string when enabled with zero tests", function()
    local state = testing.new()
    state = testing.set_enabled(state, true)
    local line = testing.format_statusline(state)
    -- Should show something like "Tests: 0" or "No tests" — not empty
    assert.is_string(line)
    assert.is_true(#line > 0)
  end)
end)

-- =============================================================================
-- format_policy_options: cycle options for a category
-- =============================================================================

describe("testing.format_policy_options [RED T2]", function()
  it("returns all valid policies as selectable options", function()
    assert.is_function(testing.format_policy_options)
    local options = testing.format_policy_options("Unit", "OnEveryChange")
    assert.is_table(options)
    -- Should have all 4 policies
    assert.are.equal(4, #options)
  end)

  it("marks current policy in the label", function()
    local options = testing.format_policy_options("Unit", "OnEveryChange")
    local found = false
    for _, opt in ipairs(options) do
      if opt.policy == "OnEveryChange" and opt.label:find("current") then
        found = true
      end
    end
    assert.is_true(found, "current policy should be marked")
  end)

  it("each option has label and policy fields", function()
    local options = testing.format_policy_options("Integration", "OnSaveOnly")
    for _, opt in ipairs(options) do
      assert.is_string(opt.label)
      assert.is_string(opt.policy)
    end
  end)
end)
