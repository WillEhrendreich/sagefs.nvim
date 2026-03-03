-- sagefs/test_trace.lua — Pure test trace parsing and formatting
-- No vim APIs — fully testable under busted.
local M = {}

local json_decode = require("sagefs.util").json_decode

--- Parse a test trace response from SageFs
---@param raw string JSON string
---@return table|nil parsed trace data
function M.parse_trace(raw)
  local ok, data = json_decode(raw)
  if not ok or not data then return nil end
  return {
    enabled = data.enabled or false,
    running = data.running or false,
    providers = data.providers or {},
    run_policies = data.runPolicies or {},
    test_summary = data.testSummary or { total = 0, passed = 0, failed = 0, stale = 0, running = 0 },
  }
end

--- Format test trace for floating window display
---@param trace table parsed trace data
---@return string[] lines
function M.format_panel_content(trace)
  local lines = {}

  -- Status header
  if trace.enabled then
    if trace.running then
      table.insert(lines, "Test Cycle: ⏳ Running")
    else
      table.insert(lines, "Test Cycle: ✓ Enabled")
    end
  else
    table.insert(lines, "Test Cycle: ⊘ Disabled")
  end
  table.insert(lines, string.rep("─", 40))

  -- Providers
  if #trace.providers > 0 then
    table.insert(lines, "")
    table.insert(lines, "Providers:")
    for _, p in ipairs(trace.providers) do
      table.insert(lines, "  • " .. p)
    end
  end

  -- Run policies
  local policies = {}
  for k, v in pairs(trace.run_policies) do
    table.insert(policies, { category = k, policy = v })
  end
  if #policies > 0 then
    table.sort(policies, function(a, b) return a.category < b.category end)
    table.insert(lines, "")
    table.insert(lines, "Run Policies:")
    for _, p in ipairs(policies) do
      table.insert(lines, string.format("  %s: %s", p.category, p.policy))
    end
  end

  -- Test summary
  local s = trace.test_summary
  if s and s.total and s.total > 0 then
    table.insert(lines, "")
    table.insert(lines, "Test Summary:")
    table.insert(lines, string.format("  Total: %d  Passed: %d  Failed: %d  Stale: %d",
      s.total, s.passed or 0, s.failed or 0, s.stale or 0))
  end

  return lines
end

return M
