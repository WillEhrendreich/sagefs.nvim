-- sagefs/test_trace.lua — Pure test trace parsing and formatting
-- No vim APIs — fully testable under busted.
--
-- Parses the payload of GET /api/live-testing/test-trace (McpServer.fs,
-- backed by Mcp.fs's getTestTrace). Field names are the F# record's own
-- PascalCase (no camelCase naming policy is applied when this route
-- serializes it), and `Policies` arrives pre-formatted as an array of
-- "Category: Policy" strings (`state.RunPolicies |> Map.toList |> List.map
-- (fun (c, p) -> sprintf "%A: %A" c p)`), not a map — verified live against
-- a real daemon:
--   {"Enabled":false,"IsRunning":false,"Providers":[],
--    "Policies":["Unit: OnEveryChange", ...],
--    "Summary":{"Total":0,"Passed":0,"Failed":0,"Stale":0,"Running":0,
--               "Disabled":0,"Enabled":false}, ...}
local M = {}

local json_decode = require("sagefs.util").json_decode

--- Parse a test trace response from SageFs
---@param raw string JSON string
---@return table|nil parsed trace data
function M.parse_trace(raw)
  local ok, data = json_decode(raw)
  if not ok or not data then return nil end
  local summary = data.Summary or {}
  return {
    enabled = data.Enabled or false,
    running = data.IsRunning or false,
    providers = data.Providers or {},
    -- Already-formatted "Category: Policy" strings from the server, not a
    -- category → policy map.
    policies = data.Policies or {},
    test_summary = {
      total = summary.Total or 0,
      passed = summary.Passed or 0,
      failed = summary.Failed or 0,
      stale = summary.Stale or 0,
      running = summary.Running or 0,
      disabled = summary.Disabled or 0,
    },
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

  -- Run policies (already-formatted "Category: Policy" strings)
  if #trace.policies > 0 then
    table.insert(lines, "")
    table.insert(lines, "Run Policies:")
    for _, p in ipairs(trace.policies) do
      table.insert(lines, "  " .. p)
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
