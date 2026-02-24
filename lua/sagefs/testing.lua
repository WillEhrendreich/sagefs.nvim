-- sagefs/testing.lua — Pure live testing state model
-- No vim API dependencies — fully testable with busted
--
-- Manages test discovery, results, run policies, and summary statistics
-- for SageFs's live testing pipeline. All state transitions are explicit
-- and validated — invalid statuses are rejected.
local M = {}

-- ─── Valid value sets (make illegal states unrepresentable) ──────────────────

M.VALID_TEST_STATUSES = {
  Detected = true,
  Queued = true,
  Running = true,
  Passed = true,
  Failed = true,
  Skipped = true,
  Stale = true,
  PolicyDisabled = true,
}

M.VALID_CATEGORIES = {
  Unit = true,
  Integration = true,
  Browser = true,
  Benchmark = true,
  Architecture = true,
  Property = true,
}

M.VALID_POLICIES = {
  OnEveryChange = true,
  OnSaveOnly = true,
  OnDemand = true,
  Disabled = true,
}

-- ─── JSON decode helper ──────────────────────────────────────────────────────

local function json_decode(s)
  if vim and vim.json and vim.json.decode then
    return pcall(vim.json.decode, s)
  elseif vim and vim.fn and vim.fn.json_decode then
    return pcall(vim.fn.json_decode, s)
  end
  return false, "no JSON decoder available"
end

-- ─── Validation ──────────────────────────────────────────────────────────────

function M.is_valid_status(status)
  return M.VALID_TEST_STATUSES[status] == true
end

function M.is_valid_category(category)
  return M.VALID_CATEGORIES[category] == true
end

function M.is_valid_policy(policy)
  return M.VALID_POLICIES[policy] == true
end

-- ─── State constructor ───────────────────────────────────────────────────────

--- Create a new empty live testing state
---@return table
function M.new()
  return {
    enabled = false,
    tests = {},    -- testId → {displayName, fullName, file, line, framework, category, policy, status, output}
    policies = {}, -- category → policy string
    summary = { total = 0, passed = 0, failed = 0, stale = 0, running = 0, disabled = 0 },
  }
end

-- ─── Toggle ──────────────────────────────────────────────────────────────────

--- Toggle live testing on or off
---@param state table
---@param enabled boolean
---@return table
function M.set_enabled(state, enabled)
  state.enabled = enabled
  return state
end

-- ─── Test entry management ───────────────────────────────────────────────────

--- Update or insert a test entry from a status response
--- Returns nil error on success, error string on validation failure
---@param state table
---@param entry table {testId, displayName, fullName, origin, framework, category, currentPolicy, status}
---@return table state, string|nil error
function M.update_test(state, entry)
  if not entry or not entry.testId then
    return state, "missing testId"
  end
  if entry.status and not M.is_valid_status(entry.status) then
    return state, "invalid status: " .. tostring(entry.status)
  end
  if entry.category and not M.is_valid_category(entry.category) then
    return state, "invalid category: " .. tostring(entry.category)
  end
  if entry.currentPolicy and not M.is_valid_policy(entry.currentPolicy) then
    return state, "invalid policy: " .. tostring(entry.currentPolicy)
  end

  -- Parse origin for file/line
  local file, line
  if entry.origin and entry.origin.Case == "SourceMapped" and entry.origin.Fields then
    file = entry.origin.Fields[1]
    line = entry.origin.Fields[2]
  end

  state.tests[entry.testId] = {
    displayName = entry.displayName or "",
    fullName = entry.fullName or "",
    file = file,
    line = line,
    framework = entry.framework or "",
    category = entry.category or "Unit",
    policy = entry.currentPolicy or "OnEveryChange",
    status = entry.status or "Detected",
    output = nil,
  }

  return state, nil
end

--- Update a test result (from a test_result event)
---@param state table
---@param testId string
---@param status string
---@param output string|nil
---@return table state, string|nil error
function M.update_result(state, testId, status, output)
  if not testId then
    return state, "missing testId"
  end
  if not M.is_valid_status(status) then
    return state, "invalid status: " .. tostring(status)
  end

  local existing = state.tests[testId]
  if existing then
    existing.status = status
    existing.output = output
  else
    -- Test appeared without discovery — create a minimal entry
    state.tests[testId] = {
      displayName = testId,
      fullName = testId,
      status = status,
      output = output,
      category = "Unit",
      policy = "OnEveryChange",
    }
  end

  return state, nil
end

-- ─── Staleness ───────────────────────────────────────────────────────────────

--- Mark all tests with terminal status (Passed/Failed/Skipped) as Stale
---@param state table
---@return table
function M.mark_all_stale(state)
  for _, test in pairs(state.tests) do
    if test.status == "Passed" or test.status == "Failed" or test.status == "Skipped" then
      test.status = "Stale"
    end
  end
  return state
end

--- Mark tests in a specific file as Stale
---@param state table
---@param file string
---@return table
function M.mark_file_stale(state, file)
  if not file then return state end
  for _, test in pairs(state.tests) do
    if test.file == file and (test.status == "Passed" or test.status == "Failed" or test.status == "Skipped") then
      test.status = "Stale"
    end
  end
  return state
end

-- ─── Run policies ────────────────────────────────────────────────────────────

--- Set the run policy for a category
---@param state table
---@param category string
---@param policy string
---@return table state, string|nil error
function M.set_run_policy(state, category, policy)
  if not M.is_valid_category(category) then
    return state, "invalid category: " .. tostring(category)
  end
  if not M.is_valid_policy(policy) then
    return state, "invalid policy: " .. tostring(policy)
  end
  state.policies[category] = policy
  return state, nil
end

--- Get the run policy for a category (defaults to OnEveryChange)
---@param state table
---@param category string
---@return string
function M.get_run_policy(state, category)
  return state.policies[category] or "OnEveryChange"
end

-- ─── Queries ─────────────────────────────────────────────────────────────────

--- Count tests
---@param state table
---@return number
function M.test_count(state)
  local count = 0
  for _ in pairs(state.tests) do count = count + 1 end
  return count
end

--- Compute summary from current test states
---@param state table
---@return table {total, passed, failed, stale, running, disabled}
function M.compute_summary(state)
  local s = { total = 0, passed = 0, failed = 0, stale = 0, running = 0, disabled = 0 }
  for _, test in pairs(state.tests) do
    s.total = s.total + 1
    if test.status == "Passed" then s.passed = s.passed + 1
    elseif test.status == "Failed" then s.failed = s.failed + 1
    elseif test.status == "Stale" then s.stale = s.stale + 1
    elseif test.status == "Running" or test.status == "Queued" then s.running = s.running + 1
    elseif test.status == "PolicyDisabled" then s.disabled = s.disabled + 1
    end
  end
  return s
end

--- Filter tests by file path
---@param state table
---@param file string
---@return table[] list of test entries
function M.filter_by_file(state, file)
  local results = {}
  if not file then return results end
  for id, test in pairs(state.tests) do
    if test.file == file then
      local entry = {}
      for k, v in pairs(test) do entry[k] = v end
      entry.testId = id
      table.insert(results, entry)
    end
  end
  return results
end

--- Filter tests by status
---@param state table
---@param status string
---@return table[] list of test entries
function M.filter_by_status(state, status)
  local results = {}
  for id, test in pairs(state.tests) do
    if test.status == status then
      local entry = {}
      for k, v in pairs(test) do entry[k] = v end
      entry.testId = id
      table.insert(results, entry)
    end
  end
  return results
end

-- ─── Parse server responses ──────────────────────────────────────────────────

--- Parse the response from get_live_test_status MCP tool
---@param json_str string
---@return table|nil parsed, string|nil error
function M.parse_status_response(json_str)
  if not json_str or json_str == "" then
    return nil, "empty response"
  end
  local ok, data = json_decode(json_str)
  if not ok or type(data) ~= "table" then
    return nil, "invalid JSON"
  end
  return data, nil
end

--- Parse the response from get_pipeline_trace MCP tool
---@param json_str string
---@return table|nil parsed, string|nil error
function M.parse_pipeline_response(json_str)
  if not json_str or json_str == "" then
    return nil, "empty response"
  end
  local ok, data = json_decode(json_str)
  if not ok or type(data) ~= "table" then
    return nil, "invalid JSON"
  end
  return data, nil
end

--- Apply a full status response to state (bulk update from server)
---@param state table
---@param data table parsed status response
---@return table state
function M.apply_status_response(state, data)
  if not data then return state end
  if data.enabled ~= nil then
    state.enabled = data.enabled
  end
  if data.summary then
    state.summary = data.summary
  end
  if data.tests then
    for _, entry in ipairs(data.tests) do
      M.update_test(state, entry)
    end
  end
  return state
end

-- ─── Formatting ──────────────────────────────────────────────────────────────

--- Format a summary line for statusline or floating window
---@param summary table {total, passed, failed, stale, running}
---@return string
function M.format_summary(summary)
  if not summary or summary.total == 0 then
    return "No tests"
  end
  local parts = {}
  if summary.passed > 0 then table.insert(parts, summary.passed .. " ✓") end
  if summary.failed > 0 then table.insert(parts, summary.failed .. " ✖") end
  if summary.stale > 0 then table.insert(parts, summary.stale .. " ~") end
  if summary.running > 0 then table.insert(parts, summary.running .. " ⏳") end
  return string.format("%d tests: %s", summary.total, table.concat(parts, ", "))
end

--- Get gutter sign for a test status
---@param status string
---@return {text: string, hl: string}
function M.gutter_sign(status)
  if status == "Passed" then
    return { text = "✓", hl = "SageFsTestPassed" }
  elseif status == "Failed" then
    return { text = "✖", hl = "SageFsTestFailed" }
  elseif status == "Running" or status == "Queued" then
    return { text = "⏳", hl = "SageFsTestRunning" }
  elseif status == "Stale" then
    return { text = "~", hl = "SageFsTestStale" }
  elseif status == "PolicyDisabled" then
    return { text = "⊘", hl = "SageFsTestDisabled" }
  elseif status == "Skipped" then
    return { text = "⊘", hl = "SageFsTestSkipped" }
  elseif status == "Detected" then
    return { text = "◦", hl = "SageFsTestDetected" }
  else
    return { text = " ", hl = "Normal" }
  end
end

--- Format failure detail for virtual text display
---@param output string|nil
---@return string
function M.format_failure_detail(output)
  if not output or output == "" then
    return "(no details)"
  end
  -- Take first line only
  local first = output:match("^([^\n]*)")
  if first and #first > 120 then
    first = first:sub(1, 117) .. "..."
  end
  return first or output
end

return M
