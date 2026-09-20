-- =============================================================================
-- test_trace Trace Tests — sagefs/test_trace.lua
-- =============================================================================
-- Pure parsing of the GET /api/live-testing/test-trace payload — real
-- shape verified live against a daemon (PascalCase, Policies as an array
-- of pre-formatted "Category: Policy" strings, not a map).

local test_trace = require("sagefs.test_trace")

describe("test_trace", function()

  describe("parse_trace", function()
    it("parses a basic trace response", function()
      local raw = '{"Enabled":true,"IsRunning":false,"Providers":["TreeSitter","FCS","TestRunner"],'
        .. '"Policies":["Unit: OnEveryChange","Integration: OnSaveOnly"],'
        .. '"Summary":{"Total":10,"Passed":8,"Failed":1,"Stale":1,"Running":0,"Disabled":0,"Enabled":true}}'
      local result = test_trace.parse_trace(raw)
      assert.is_table(result)
      assert.is_true(result.enabled)
      assert.is_false(result.running)
      assert.are.equal(3, #result.providers)
      assert.are.equal(2, #result.policies)
      assert.are.equal("Unit: OnEveryChange", result.policies[1])
      assert.are.equal(10, result.test_summary.total)
      assert.are.equal(8, result.test_summary.passed)
    end)

    it("returns nil for invalid JSON", function()
      local result = test_trace.parse_trace("not json")
      assert.is_nil(result)
    end)

    it("handles missing fields gracefully", function()
      local raw = '{"Enabled":false}'
      local result = test_trace.parse_trace(raw)
      assert.is_table(result)
      assert.is_false(result.enabled)
      assert.is_table(result.providers)
      assert.are.equal(0, #result.providers)
      assert.are.equal(0, result.test_summary.total)
    end)
  end)

  describe("format_panel_content", function()
    it("produces readable lines from trace data", function()
      local trace = {
        enabled = true,
        running = false,
        providers = { "TreeSitter", "FCS", "TestRunner" },
        policies = { "Unit: OnEveryChange", "Integration: OnSaveOnly" },
        test_summary = { total = 10, passed = 8, failed = 1, stale = 1, running = 0 },
      }
      local lines = test_trace.format_panel_content(trace)
      assert.is_table(lines)
      assert.truthy(#lines > 0)
      local text = table.concat(lines, "\n")
      assert.truthy(text:find("Enabled") or text:find("enabled"))
      assert.truthy(text:find("TreeSitter"))
      assert.truthy(text:find("Unit: OnEveryChange"))
    end)

    it("shows disabled state clearly", function()
      local trace = {
        enabled = false,
        running = false,
        providers = {},
        policies = {},
        test_summary = { total = 0, passed = 0, failed = 0, stale = 0, running = 0 },
      }
      local lines = test_trace.format_panel_content(trace)
      local text = table.concat(lines, "\n")
      assert.truthy(text:find("Disabled") or text:find("disabled") or text:find("OFF"))
    end)

    it("shows running state", function()
      local trace = {
        enabled = true,
        running = true,
        providers = { "TreeSitter" },
        policies = {},
        test_summary = { total = 5, passed = 3, failed = 0, stale = 2, running = 0 },
      }
      local lines = test_trace.format_panel_content(trace)
      local text = table.concat(lines, "\n")
      assert.truthy(text:find("Running") or text:find("running") or text:find("⏳"))
    end)
  end)
end)
