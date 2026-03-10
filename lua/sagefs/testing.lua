-- sagefs/testing.lua — Pure live testing state model
-- No vim API dependencies — fully testable with busted
--
-- Manages test discovery, results, run policies, and summary statistics
-- for SageFs's live testing cycle. All state transitions are explicit
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

local json_decode = require("sagefs.util").json_decode

-- ─── Session Scoping ─────────────────────────────────────────────────────────

--- Three-way session filter (Wlaschin pattern):
--- 1. nil data → reject
--- 2. No SessionId in data → accept (backward compat with older daemon)
--- 3. No active_session → accept (show everything)
--- 4. Both present → strict match
function M.session_matches(data, active_session)
  if not data then return false end
  local sid = data.SessionId
  if sid == nil then return true end
  if active_session == nil then return true end
  return sid == active_session.id
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
    tests = {},      -- testId → {displayName, fullName, file, line, framework, category, policy, status, output}
    policies = {},   -- category → policy string
    summary = { total = 0, passed = 0, failed = 0, stale = 0, running = 0, disabled = 0 },
    locations = {},  -- file → [{testId, file, line}]
    providers = {},  -- [string]
    run_phase = "Idle",  -- "Idle" | "Running" | "RunningButEdited"
    generation = 0,      -- current RunGeneration int
    freshness = nil,     -- "Fresh" | "StaleCodeEdited" | "StaleWrongGeneration" | nil
    completion = nil,    -- "Complete" | "Partial" | "Superseded" | nil
    _file_index = {},    -- file → { testId → true } (O(1) file lookup, maintained incrementally)
    _version = 0,        -- mutation counter for render skip (FDA short-circuit / Nu ViewVersion)
  }
end

--- Normalize file path separators: try original, then flipped slashes.
--- Handles Windows daemon (forward slashes) vs Neovim buffer names (backslashes)
---@param file_index table the _file_index map
---@param file string the file path to look up
---@return table|nil the id_set if found
local function resolve_file_index(file_index, file)
  if not file_index or not file then return nil end
  local id_set = file_index[file]
  if id_set then return id_set end
  local alt = file:gsub("\\", "/")
  if alt == file then alt = file:gsub("/", "\\") end
  return file_index[alt]
end

-- ─── Toggle ──────────────────────────────────────────────────────────────────

--- Set live testing enabled or disabled
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

  -- Remove old file index entry if file changed
  local old = state.tests[entry.testId]
  if old and old.file and old.file ~= file then
    local old_set = state._file_index[old.file]
    if old_set then old_set[entry.testId] = nil end
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

  -- Maintain file index (SoA-inspired O(1) file lookup)
  if file then
    if not state._file_index[file] then state._file_index[file] = {} end
    state._file_index[file][entry.testId] = true
  end
  state._version = state._version + 1

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
  state._version = state._version + 1

  return state, nil
end

-- ─── PascalCase normalization (F# JsonFSharpConverter output) ────────────────

--- Map of PascalCase keys to camelCase for TestStatusEntry
local pascal_to_camel = {
  TestId = "testId",
  DisplayName = "displayName",
  FullName = "fullName",
  Origin = "origin",
  Framework = "framework",
  Category = "category",
  CurrentPolicy = "currentPolicy",
  Status = "status",
  PreviousStatus = "previousStatus",
}

--- Unwrap an F# Discriminated Union JSON value: {Case = "X"} → "X"
---@param v any
---@return any
local function unwrap_du(v)
  if type(v) == "table" and v.Case and type(v.Case) == "string" then
    return v.Case
  end
  return v
end

--- Normalize a TestStatusEntry from PascalCase (F#) to camelCase (Lua convention)
--- Also unwraps F# DU values (e.g. Status = {Case="Stale"} → status = "Stale")
---@param entry table
---@return table normalized entry
function M.normalize_entry(entry)
  if not entry then return entry end
  -- Fields that are F# DUs and need unwrapping
  local du_fields = { "status", "category", "currentPolicy", "previousStatus",
                      "Status", "Category", "CurrentPolicy", "PreviousStatus" }
  if entry.testId then
    -- Already camelCase but DU fields might still be tables
    for _, f in ipairs(du_fields) do
      if type(entry[f]) == "table" then
        entry[f] = unwrap_du(entry[f])
      end
    end
    return entry
  end
  local out = {}
  for k, v in pairs(entry) do
    local mapped = pascal_to_camel[k]
    if mapped then
      out[mapped] = v
    else
      out[k] = v
    end
  end
  -- Unwrap DU values for fields that should be plain strings
  for _, f in ipairs({"status", "category", "currentPolicy", "previousStatus"}) do
    if type(out[f]) == "table" then
      out[f] = unwrap_du(out[f])
    end
  end
  return out
end

--- Parse a RunGeneration DU value to a plain int
---@param gen any RunGeneration DU table, number, or nil
---@return number
function M.parse_generation(gen)
  if gen == nil then return 0 end
  if type(gen) == "number" then return gen end
  if type(gen) == "table" and gen.Case == "RunGeneration" and gen.Fields then
    return gen.Fields[1] or 0
  end
  return 0
end

--- Parse a BatchCompletion DU value to a string
---@param comp any BatchCompletion DU table, string, or nil
---@return string|nil
function M.parse_completion(comp)
  if comp == nil then return nil end
  if type(comp) == "string" then return comp end
  if type(comp) == "table" and comp.Case then
    return comp.Case
  end
  return nil
end

--- Parse a ResultFreshness value (simple string DU)
---@param fresh any
---@return string|nil
function M.parse_freshness(fresh)
  if type(fresh) == "string" then return fresh end
  if type(fresh) == "table" and fresh.Case then return fresh.Case end
  return nil
end

--- Normalize a TestSummary from PascalCase to lowercase keys
---@param summary table
---@return table normalized summary
function M.normalize_summary(summary)
  if not summary then return nil end
  -- If already lowercase, return as-is
  if summary.total ~= nil then return summary end
  return {
    total = summary.Total or 0,
    passed = summary.Passed or 0,
    failed = summary.Failed or 0,
    stale = summary.Stale or 0,
    running = summary.Running or 0,
    disabled = summary.Disabled or 0,
  }
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
  state._version = state._version + 1
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
  state._version = state._version + 1
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

--- Filter tests by file path (uses _file_index for O(k) lookup instead of O(n))
---@param state table
---@param file string
---@return table[] list of test entries
function M.filter_by_file(state, file)
  local results = {}
  if not file then return results end
  local id_set = resolve_file_index(state._file_index, file)
  if not id_set then return results end
  for id in pairs(id_set) do
    local test = state.tests[id]
    if test then
      local entry = {}
      for k, v in pairs(test) do entry[k] = v end
      entry.testId = id
      table.insert(results, entry)
    end
  end
  return results
end

--- Filter tests that cover a given production file.
--- Uses CoveringTestIds from coverage annotations to find tests that exercise the file.
---@param state table testing state
---@param annotations_state table annotations state (from annotations module)
---@param file string production file path
---@return table[] list of test entries that cover this file
function M.filter_by_covering_file(state, annotations_state, file)
  local results = {}
  if not file or not annotations_state then return results end

  local annotations = require("sagefs.annotations")
  local file_ann = annotations.get_file(annotations_state, file)
  if not file_ann then return results end

  local cov_anns = file_ann.CoverageAnnotations or file_ann.coverageAnnotations
  if not cov_anns then return results end

  -- Collect unique test IDs from all coverage annotations
  local test_ids = {}
  for _, cov in ipairs(cov_anns) do
    local ids = cov.CoveringTestIds or cov.coveringTestIds
    if ids then
      for _, tid in ipairs(ids) do
        test_ids[tid] = true
      end
    end
  end

  -- Look up each test by ID
  for id in pairs(test_ids) do
    local test = state.tests[id]
    if test then
      local entry = {}
      for k, v in pairs(test) do entry[k] = v end
      entry.testId = id
      table.insert(results, entry)
    end
  end
  return results
end

--- Get all tests as a flat list
---@param state table
---@return table[] list of test entries
function M.all_tests(state)
  local results = {}
  for id, test in pairs(state.tests) do
    local entry = {}
    for k, v in pairs(test) do entry[k] = v end
    entry.testId = id
    table.insert(results, entry)
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

--- Parse the response from get_test_trace MCP tool
---@param json_str string
---@return table|nil parsed, string|nil error
function M.parse_test_trace_response(json_str)
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
  -- Handle both camelCase and PascalCase (from F# JsonFSharpConverter)
  local enabled = data.enabled
  if enabled == nil then enabled = data.Enabled end
  if enabled ~= nil then
    state.enabled = enabled
  end
  local summary = data.summary or data.Summary
  if summary then
    state.summary = M.normalize_summary(summary)
  end
  local tests = data.tests or data.Tests
  if tests then
    for _, entry in ipairs(tests) do
      M.update_test(state, M.normalize_entry(entry))
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
    first = first:sub(1, 117) .. "…"
  end
  return first or output
end

-- ─── Test Failures → vim.diagnostic ──────────────────────────────────────────

--- Convert failed tests for a single file to vim.diagnostic-shaped tables
--- Uses _file_index for O(k) lookup instead of O(n) full scan
---@param state table
---@param file string|nil
---@return table[] diagnostics (0-indexed lnum/col)
function M.to_diagnostics(state, file)
  if not file then return {} end
  local diags = {}
  local id_set = resolve_file_index(state._file_index, file)
  if not id_set then return diags end
  for id in pairs(id_set) do
    local test = state.tests[id]
    if test and test.status == "Failed" then
      local msg = test.displayName or "test failed"
      if test.output and test.output ~= "" then
        msg = msg .. ": " .. M.format_failure_detail(test.output)
      end
      table.insert(diags, {
        lnum = (test.line or 1) - 1,
        col = 0,
        severity = 1,
        message = msg,
        source = "sagefs_tests",
      })
    end
  end
  return diags
end

--- Convert all failed tests to diagnostics grouped by file
---@param state table
---@return table<string, table[]>
function M.to_diagnostics_grouped(state)
  local files = {}
  for _, test in pairs(state.tests) do
    if test.status == "Failed" and test.file then
      if not files[test.file] then files[test.file] = true end
    end
  end
  local result = {}
  for file in pairs(files) do
    result[file] = M.to_diagnostics(state, file)
  end
  return result
end

-- ─── SSE Event Handlers ──────────────────────────────────────────────────────

--- Handle a TestResultsBatch event: update multiple test results at once
---@param state table
---@param data table TestResultsBatchPayload (enriched) or legacy {results: []}
---@return table state
function M.handle_results_batch(state, data)
  if not data then return state end

  -- Receiving test results implies live testing is active
  state.enabled = true

  -- Enriched payload: Entries/entries (PascalCase or camelCase)
  local entries = data.Entries or data.entries
  if entries then
    for _, entry in ipairs(entries) do
      M.update_test(state, M.normalize_entry(entry))
    end
    local summary = data.Summary or data.summary
    if summary then
      state.summary = M.normalize_summary(summary)
    end
    state.generation = M.parse_generation(data.Generation or data.generation) or state.generation
    state.freshness = M.parse_freshness(data.Freshness or data.freshness)
    state.completion = M.parse_completion(data.Completion or data.completion)
    -- Bump version so schedule_render() version-skip check fires the render.
    -- update_test already bumps per-entry but an empty batch with summary-only
    -- changes (e.g. freshness snapshot) would otherwise be silently dropped.
    state._version = state._version + 1
    return state
  end

  -- Legacy format: results array with {testId, status, output}
  if data.results then
    for _, r in ipairs(data.results) do
      M.update_result(state, r.testId, r.status, r.output)
    end
  end
  return state
end

--- Handle a TestsDiscovered event: bulk-add discovered tests
---@param state table
---@param data table {tests: entry[]}
---@return table state
function M.handle_tests_discovered(state, data)
  if not data or not data.tests then return state end
  state.enabled = true
  for _, entry in ipairs(data.tests) do
    M.update_test(state, entry)
  end
  return state
end

--- Handle a LiveTestingEnabled SSE event
---@param state table
---@return table state
function M.handle_live_testing_enabled(state)
  state.enabled = true
  state._version = state._version + 1
  return state
end

--- Handle a LiveTestingDisabled SSE event
---@param state table
---@return table state
function M.handle_live_testing_disabled(state)
  state.enabled = false
  state._version = state._version + 1
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
  state._version = state._version + 1
  return state
end

--- Handle a TestRunCompleted event: update summary
---@param state table
---@param data table|nil {summary: {total, passed, failed, stale, running}}
---@return table state
function M.handle_test_run_completed(state, data)
  if not data then return state end
  if data.summary then
    state.summary = data.summary
  end
  state._version = state._version + 1
  return state
end

-- ─── New handlers for enriched SageFs events ─────────────────────────────────

--- Handle test locations detected: store source-mapped test locations by file
---@param state table
---@param data table {locations: [{testId, file, line}]}
---@return table state
function M.handle_test_locations(state, data)
  if not data or not data.locations then return state end
  local by_file = {}
  for _, loc in ipairs(data.locations) do
    local file = loc.file
    if file then
      if not by_file[file] then by_file[file] = {} end
      table.insert(by_file[file], { testId = loc.testId, file = file, line = loc.line })
    end
  end
  state.locations = by_file
  return state
end

--- Handle providers detected: store list of framework names
---@param state table
---@param data table {providers: [string]}
---@return table state
function M.handle_providers_detected(state, data)
  if not data or not data.providers then return state end
  state.providers = data.providers
  return state
end

--- Handle run phase changes (Idle/Running/RunningButEdited)
---@param state table
---@param data table {phase: string, generation: number?}
---@return table state
function M.handle_run_phase_changed(state, data)
  if not data or not data.phase then return state end
  state.run_phase = data.phase
  if data.generation then
    state.generation = data.generation
  end
  return state
end

--- Handle a test_summary SSE event (new typed event from SageFs)
--- Updates the summary and auto-enables testing when tests exist
---@param state table
---@param data table TestSummary (PascalCase or camelCase)
---@return table state
function M.handle_test_summary(state, data)
  if not data then return state end
  state.summary = M.normalize_summary(data)
  return state
end

-- ─── Annotations (gutter signs for test status) ──────────────────────────────

--- Map test status to GutterIcon name (mirrors SageFs GutterIcon DU)
local status_to_icon = {
  Detected = "TestDiscovered",
  Queued = "TestDiscovered",
  Running = "TestRunning",
  Passed = "TestPassed",
  Failed = "TestFailed",
  Skipped = "TestSkipped",
  Stale = "TestDiscovered",
  PolicyDisabled = "TestSkipped",
}

--- Generate line annotations for tests in a specific file (uses _file_index)
---@param state table testing state
---@param file string file path to filter by
---@return table[] annotations [{line, icon, tooltip}]
function M.annotations_for_file(state, file)
  local anns = {}
  local id_set = resolve_file_index(state._file_index, file)
  if not id_set then return anns end
  for id in pairs(id_set) do
    local test = state.tests[id]
    if test then
      table.insert(anns, {
        line = test.line or 1,
        icon = status_to_icon[test.status] or "TestDiscovered",
        tooltip = string.format("%s: %s", test.status or "Unknown", test.displayName or ""),
      })
    end
  end
  table.sort(anns, function(a, b) return a.line < b.line end)
  return anns
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

--- Format test trace data for display
---@param data table|nil
---@return string[]
function M.format_test_trace(data)
  if not data then
    return { "No test trace data available" }
  end
  local lines = {}
  if data.enabled then
    table.insert(lines, "Test Cycle: Enabled")
  else
    table.insert(lines, "Test Cycle: Disabled")
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

--- Format compact test trace for statusline
---@param trace table|nil
---@return string
function M.format_test_trace_statusline(trace)
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

--- Format full panel content for persistent test split buffer
---@param state table
---@return string[] lines suitable for a scratch buffer
function M.format_panel_content(state)
  local lines = {}
  local summary = M.compute_summary(state)
  table.insert(lines, M.format_summary(summary))
  table.insert(lines, string.rep("─", 40))
  table.insert(lines, "")

  local test_lines = M.format_test_list(state)
  for _, l in ipairs(test_lines) do
    table.insert(lines, l)
  end

  -- Append output for failed tests
  local failed = M.filter_by_status(state, "Failed")
  if #failed > 0 then
    table.insert(lines, "")
    table.insert(lines, string.rep("─", 40))
    table.insert(lines, "Failures:")
    table.insert(lines, "")
    for _, t in ipairs(failed) do
      table.insert(lines, "✖ " .. (t.displayName or t.testId))
      if t.output and t.output ~= "" then
        for out_line in t.output:gmatch("[^\n]+") do
          table.insert(lines, "  " .. out_line)
        end
      end
      table.insert(lines, "")
    end
  end

  return lines
end

--- Returns structured entries with text + navigation metadata for the test panel.
--- Each entry has: { text = "icon name", file = path|nil, line = num|nil }
---@param state table
---@return table[]
function M.format_panel_entries(state)
  local raw = {}
  for id, test in pairs(state.tests) do
    table.insert(raw, {
      testId = id,
      displayName = test.displayName or id,
      status = test.status or "Detected",
      file = test.file,
      line = test.line,
    })
  end
  table.sort(raw, function(a, b)
    local oa = STATUS_ORDER[a.status] or 99
    local ob = STATUS_ORDER[b.status] or 99
    if oa ~= ob then return oa < ob end
    return a.displayName < b.displayName
  end)
  local entries = {}
  -- Header lines (no navigation)
  local summary = M.compute_summary(state)
  table.insert(entries, { text = M.format_summary(summary) })
  table.insert(entries, { text = string.rep("─", 40) })
  table.insert(entries, { text = "" })
  -- Test lines (with navigation metadata)
  for _, e in ipairs(raw) do
    local icon = STATUS_ICON[e.status] or "?"
    table.insert(entries, {
      text = string.format("%s %s", icon, e.displayName),
      file = e.file,
      line = e.line,
    })
  end
  return entries
end

--- Format test panel content filtered to a specific source file.
---@param state table
---@param filepath string
---@return string[]
function M.format_file_panel_content(state, filepath)
  local filtered = {}
  for id, test in pairs(state.tests) do
    if test.file == filepath then
      filtered[id] = test
    end
  end
  -- Check if any tests matched
  local has_tests = false
  for _ in pairs(filtered) do has_tests = true; break end
  if not has_tests then
    return { "No tests found for " .. filepath }
  end
  local proxy = M.new()
  proxy.tests = filtered
  return M.format_panel_content(proxy)
end

-- ─── Filter Scopes ──────────────────────────────────────────────────────────

M.VALID_SCOPES = { file = true, module = true, all = true }

--- Check if a scope kind is valid
---@param kind string|nil
---@return boolean
function M.is_valid_scope(kind)
  return M.VALID_SCOPES[kind] == true
end

--- Cycle to the next scope kind: file → module → all → file
---@param current string|nil
---@return string
function M.next_scope(current)
  if current == "binding" then return "file" end
  if current == "file" then return "module" end
  if current == "module" then return "all" end
  return "binding"
end

--- Human-readable label for a scope
---@param scope table {kind, path?, prefix?}
---@return string
function M.scope_label(scope)
  if scope.kind == "file" then
    if not scope.path then return "file: (none)" end
    return "file: " .. scope.path:match("[/\\]?([^/\\]+)$")
  elseif scope.kind == "module" then
    if not scope.prefix then return "module: (none)" end
    -- Show last segment: "SageFs.Tests.EditorTests" → "EditorTests"
    return "module: " .. scope.prefix:match("([^%.]+)$")
  elseif scope.kind == "binding" then
    if not scope.name then return "binding: (none)" end
    return "binding: " .. scope.name
  elseif scope.kind == "all" then
    return "all"
  end
  return scope.kind
end

--- Filter tests by scope. Pure function — no vim API.
---@param state table testing state
---@param scope table {kind="file"|"module"|"all", path?, prefix?}
---@return table[] list of test entries with testId, displayName, fullName, status, file, line
function M.filter_by_scope(state, scope, annotations_state)
  if scope.kind == "all" then
    return M.all_tests(state)
  elseif scope.kind == "file" then
    local results = M.filter_by_file(state, scope.path)
    -- Fallback: if no source-mapped tests, try covering tests from annotations
    if #results == 0 and annotations_state then
      results = M.filter_by_covering_file(state, annotations_state, scope.path)
    end
    return results
  elseif scope.kind == "module" then
    if not scope.prefix then return {} end
    local results = {}
    for id, test in pairs(state.tests) do
      local fn = test.fullName or ""
      if fn:sub(1, #scope.prefix) == scope.prefix then
        local entry = {}
        for k, v in pairs(test) do entry[k] = v end
        entry.testId = id
        table.insert(results, entry)
      end
    end
    return results
  elseif scope.kind == "binding" then
    if not scope.name then return {} end
    local file_tests = M.filter_by_file(state, scope.path)
    local results = {}
    for _, t in ipairs(file_tests) do
      local fn = t.fullName or ""
      if fn:find(scope.name, 1, true) then
        table.insert(results, t)
      end
    end
    return results
  else
    error("unknown scope kind: " .. tostring(scope.kind))
  end
end

--- Format panel entries with scope-aware header + keybinding hints.
--- Returns structured entries: {text, file?, line?}
---@param state table testing state
---@param scope table {kind, path?, prefix?}
---@return table[]
function M.format_scoped_panel_entries(state, scope, annotations_state)
  local filtered = M.filter_by_scope(state, scope, annotations_state)

  -- Build a proxy state for summary computation
  local proxy = M.new()
  for _, entry in ipairs(filtered) do
    proxy.tests[entry.testId] = entry
  end
  local summary = M.compute_summary(proxy)

  local entries = {}
  -- Header: scope + summary counts
  local label = M.scope_label(scope)
  table.insert(entries, {
    text = string.format("═══ Tests (%s) — %d✓ %d✗ ═══",
      label, summary.passed, summary.failed),
  })
  -- Keybinding hints
  local current = scope.kind
  local hints = {}
  for _, s in ipairs({ "b", "f", "m", "a" }) do
    local full = ({ b = "binding", f = "file", m = "module", a = "all" })[s]
    if full == current then
      table.insert(hints, string.format("[%s]%s", s, full:sub(2)))
    else
      table.insert(hints, string.format(" %s:%s", s, full))
    end
  end
  table.insert(entries, { text = table.concat(hints, "  ") })
  -- Separator
  table.insert(entries, { text = string.rep("─", 40) })

  if #filtered == 0 then
    table.insert(entries, { text = "No tests match current scope" })
    return entries
  end

  -- Sort: failures first, then alphabetical
  table.sort(filtered, function(a, b)
    local oa = STATUS_ORDER[a.status] or 99
    local ob = STATUS_ORDER[b.status] or 99
    if oa ~= ob then return oa < ob end
    return (a.displayName or "") < (b.displayName or "")
  end)

  -- Test lines with navigation metadata
  for _, t in ipairs(filtered) do
    local icon = STATUS_ICON[t.status] or "?"
    table.insert(entries, {
      text = string.format("%s %s", icon, t.displayName or t.testId),
      file = t.file,
      line = t.line,
    })
  end

  return entries
end

return M
