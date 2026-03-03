-- =============================================================================
-- test_trace Trace Tests — sagefs/test_trace.lua
-- =============================================================================
-- Pure parsing of test_trace trace data from SageFs get_test_trace_trace.

local test_trace = require("sagefs.test_trace")

describe("test_trace", function()

  describe("parse_trace", function()
    it("parses a basic trace response", function()
      local raw = '{"enabled":true,"running":false,"providers":["TreeSitter","FCS","TestRunner"],"runPolicies":{"Unit":"OnEveryChange","Integration":"OnSaveOnly"},"testSummary":{"total":10,"passed":8,"failed":1,"stale":1}}'
      local result = test_trace.parse_trace(raw)
      assert.is_table(result)
      assert.is_true(result.enabled)
      assert.is_false(result.running)
      assert.are.equal(3, #result.providers)
      assert.are.equal("OnEveryChange", result.run_policies.Unit)
      assert.are.equal(10, result.test_summary.total)
    end)

    it("returns nil for invalid JSON", function()
      local result = test_trace.parse_trace("not json")
      assert.is_nil(result)
    end)

    it("handles missing fields gracefully", function()
      local raw = '{"enabled":false}'
      local result = test_trace.parse_trace(raw)
      assert.is_table(result)
      assert.is_false(result.enabled)
      assert.is_table(result.providers)
      assert.are.equal(0, #result.providers)
    end)
  end)

  describe("format_panel_content", function()
    it("produces readable lines from trace data", function()
      local trace = {
        enabled = true,
        running = false,
        providers = { "TreeSitter", "FCS", "TestRunner" },
        run_policies = { Unit = "OnEveryChange", Integration = "OnSaveOnly" },
        test_summary = { total = 10, passed = 8, failed = 1, stale = 1, running = 0 },
      }
      local lines = test_trace.format_panel_content(trace)
      assert.is_table(lines)
      assert.truthy(#lines > 0)
      local text = table.concat(lines, "\n")
      assert.truthy(text:find("Enabled") or text:find("enabled"))
      assert.truthy(text:find("TreeSitter"))
      assert.truthy(text:find("Unit"))
    end)

    it("shows disabled state clearly", function()
      local trace = {
        enabled = false,
        running = false,
        providers = {},
        run_policies = {},
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
        run_policies = {},
        test_summary = { total = 5, passed = 3, failed = 0, stale = 2, running = 0 },
      }
      local lines = test_trace.format_panel_content(trace)
      local text = table.concat(lines, "\n")
      assert.truthy(text:find("Running") or text:find("running") or text:find("⏳"))
    end)
  end)
end)
