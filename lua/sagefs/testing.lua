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

-- ─── SSE Event Handlers ──────────────────────────────────────────────────────

--- Handle a TestResultsBatch event: update multiple test results at once
---@param state table
---@param data table {results: {testId, status, output?}[]}
---@return table state
function M.handle_results_batch(state, data)
  if not data or not data.results then return state end
  for _, r in ipairs(data.results) do
    M.update_result(state, r.testId, r.status, r.output)
  end
  return state
end

--- Handle a TestsDiscovered event: bulk-add discovered tests
---@param state table
---@param data table {tests: entry[]}
---@return table state
function M.handle_tests_discovered(state, data)
  if not data or not data.tests then return state end
  for _, entry in ipairs(data.tests) do
    M.update_test(state, entry)
  end
  return state
end

--- Handle a LiveTestingToggled event
---@param state table
---@param data table {enabled: boolean}
---@return table state
function M.handle_live_testing_toggled(state, data)
  if not data then return state end
  if data.enabled ~= nil then
    state.enabled = data.enabled
  end
  return state
end

--- Handle a RunPolicyChanged event
---@param state table
---@param data table {category: string, policy: string}
---@return table state
function M.handle_run_policy_changed(state, data)
  if not data or not data.category or not data.policy then return state end
  M.set_run_policy(state, data.category, data.policy)
  return state
end

--- Handle a TestRunStarted event: mark affected tests as Running
---@param state table
---@param data table {testIds: string[]?}
---@return table state
function M.handle_test_run_started(state, data)
  if not data then return state end
  if data.testIds and #data.testIds > 0 then
    for _, id in ipairs(data.testIds) do
      if state.tests[id] then
        state.tests[id].status = "Running"
      end
    end
  else
    for _, test in pairs(state.tests) do
      test.status = "Running"
    end
  end
  return state
end

-- ─── State Recovery ──────────────────────────────────────────────────────────

--- Build a request to recover full test status after SSE reconnect
---@return table
function M.build_recovery_request()
  return { tool = "get_live_test_status" }
end

--- Check if testing state needs recovery (after reconnect)
---@param state table
---@return boolean
function M.needs_recovery(state)
  if not state.enabled then return false end
  local count = 0
  for _ in pairs(state.tests) do count = count + 1 end
  if count == 0 then return true end
  for _, test in pairs(state.tests) do
    if test.status == "Stale" then return true end
  end
  return false
end

-- ─── Formatting: Test List ───────────────────────────────────────────────────

local STATUS_ORDER = {
  Failed = 1, Running = 2, Queued = 3, Stale = 4,
  Detected = 5, Passed = 6, Skipped = 7, PolicyDisabled = 8,
}

local STATUS_ICON = {
  Passed = "✓", Failed = "✖", Running = "⏳", Queued = "⏳",
  Stale = "~", Detected = "◦", Skipped = "⊘", PolicyDisabled = "⊘",
}

--- Format all tests as a flat list of display strings
---@param state table
---@return string[]
function M.format_test_list(state)
  local entries = {}
  for id, test in pairs(state.tests) do
    table.insert(entries, {
      testId = id,
      displayName = test.displayName or id,
      status = test.status or "Detected",
      file = test.file,
    })
  end
  table.sort(entries, function(a, b)
    local oa = STATUS_ORDER[a.status] or 99
    local ob = STATUS_ORDER[b.status] or 99
    if oa ~= ob then return oa < ob end
    return a.displayName < b.displayName
  end)
  local lines = {}
  for _, e in ipairs(entries) do
    local icon = STATUS_ICON[e.status] or "?"
    table.insert(lines, string.format("%s %s", icon, e.displayName))
  end
  return lines
end

--- Format tests grouped by source file
---@param state table
---@return table<string, table[]>
function M.format_test_list_by_file(state)
  local groups = {}
  for id, test in pairs(state.tests) do
    local file = test.file or "(unknown)"
    if not groups[file] then groups[file] = {} end
    table.insert(groups[file], {
      testId = id,
      displayName = test.displayName or id,
      status = test.status or "Detected",
      file = test.file,
      line = test.line,
    })
  end
  return groups
end

--- Filter tests by category
---@param state table
---@param category string
---@return table[]
function M.filter_by_category(state, category)
  local results = {}
  for id, test in pairs(state.tests) do
    if test.category == category then
      local entry = {}
      for k, v in pairs(test) do entry[k] = v end
      entry.testId = id
      table.insert(results, entry)
    end
  end
  return results
end

--- Format picker items for policy selection (all 6 categories)
---@param state table
---@return table[]
function M.format_picker_items(state)
  local items = {}
  local categories = { "Unit", "Integration", "Browser", "Benchmark", "Architecture", "Property" }
  for _, cat in ipairs(categories) do
    local policy = M.get_run_policy(state, cat)
    table.insert(items, {
      label = string.format("%s [%s]", cat, policy),
      category = cat,
      policy = policy,
    })
  end
  return items
end

--- Format policy options for a specific category
---@param category string
---@param current_policy string
---@return table[]
function M.format_policy_options(category, current_policy)
  local options = {}
  local policies = { "OnEveryChange", "OnSaveOnly", "OnDemand", "Disabled" }
  for _, p in ipairs(policies) do
    local label = p
    if p == current_policy then
      label = p .. " (current)"
    end
    table.insert(options, { label = label, policy = p })
  end
  return options
end

--- Build a run_tests MCP request
---@param opts {pattern?: string, category?: string}
---@return table|nil request, string|nil error
function M.build_run_request(opts)
  opts = opts or {}
  if opts.category and opts.category ~= "" and not M.is_valid_category(opts.category) then
    return nil, "invalid category: " .. tostring(opts.category)
  end
  return {
    pattern = opts.pattern or "",
    category = opts.category or "",
  }, nil
end

--- Format pipeline trace data for display
---@param data table|nil
---@return string[]
function M.format_pipeline_trace(data)
  if not data then
    return { "No pipeline trace data available" }
  end
  local lines = {}
  if data.enabled then
    table.insert(lines, "Pipeline: Enabled")
  else
    table.insert(lines, "Pipeline: Disabled")
  end
  if data.running then
    table.insert(lines, "Status: Running")
  elseif data.enabled then
    table.insert(lines, "Status: Idle")
  end
  if data.providers and #data.providers > 0 then
    table.insert(lines, "Providers: " .. table.concat(data.providers, ", "))
  end
  if data.runPolicies then
    table.insert(lines, "")
    table.insert(lines, "Run Policies:")
    for _, rp in ipairs(data.runPolicies) do
      table.insert(lines, string.format("  %s: %s", rp.category or "?", rp.policy or "?"))
    end
  end
  if data.summary then
    table.insert(lines, "")
    table.insert(lines, M.format_summary(data.summary))
  end
  return lines
end

--- Format compact statusline for live testing
---@param state table
---@return string
function M.format_statusline(state)
  if not state.enabled then return "" end
  local s = M.compute_summary(state)
  if s.total == 0 then return "Tests: 0" end
  local parts = {}
  if s.passed > 0 then table.insert(parts, s.passed .. " ✓") end
  if s.failed > 0 then table.insert(parts, s.failed .. " ✖") end
  if s.running > 0 then table.insert(parts, s.running .. " ⏳") end
  if s.stale > 0 then table.insert(parts, s.stale .. " ~") end
  return table.concat(parts, " ")
end

--- Format compact pipeline trace for statusline
---@param trace table|nil
---@return string
function M.format_pipeline_statusline(trace)
  if not trace or not trace.enabled then return "" end
  local parts = {}
  if trace.running then
    table.insert(parts, "⏳")
  end
  if trace.summary then
    if trace.summary.passed then
      table.insert(parts, trace.summary.passed .. "✓")
    end
    if trace.summary.failed and trace.summary.failed > 0 then
      table.insert(parts, trace.summary.failed .. "✖")
    end
  end
  if #parts == 0 then
    return "Tests"
  end
  return table.concat(parts, " ")
end

return M
