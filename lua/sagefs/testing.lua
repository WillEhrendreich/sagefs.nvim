-- sagefs/testing.lua — Pure live testing state model
-- No vim API dependencies — fully testable with busted
--
-- Manages test discovery, results, run policies, and summary statistics
-- for SageFs's live testing cycle. All state transitions are explicit
-- and validated — invalid statuses are rejected.
local M = {}

-- ─── Result provenance ───────────────────────────────────────────────────────
--
-- Every test status entry the daemon sends carries a Provenance: what code
-- produced this row's verdict. On the wire it is one of
--
--   {"Case":"Compiled"}                            ran against a build's binaries
--   {"Case":"Evaluated"}                           ran against code the session evaluated
--   {"Case":"VerifiedByBuild"}                     evaluated, then a real build agreed
--   {"Case":"BuildDisagrees","Fields":[{"Case":"BuildFailed","Fields":["..."]}]}
--
-- (SageFs.Core/Features/LiveTestingTypes.fs, ResultProvenance.)
--
-- Evaluated is the NORMAL state of a live session: every keystroke's tests run
-- against evaluated code until a real build confirms them. Marking that would
-- mark almost every row and train the eye to ignore the mark. BuildDisagrees is
-- the one case where the plugin has EVIDENCE that the row did not come from this
-- build, and where a green row would be actively misleading: the eval said pass,
-- the compiler said otherwise. So exactly that one earns a mark.

--- The provenance cases the daemon can send, in its own spelling.
M.PROVENANCE = {
  Compiled = "Compiled",
  Evaluated = "Evaluated",
  VerifiedByBuild = "VerifiedByBuild",
  BuildDisagrees = "BuildDisagrees",
}

--- The one provenance that earns a mark, in either spelling of the wire value.
local MARKED = {
  BuildDisagrees = true,
  build_disagrees = true,
}

--- Does this provenance deserve a mark on its row? True for BuildDisagrees and
--- nothing else. nil (a daemon that sends no provenance) is never marked: absence
--- is not disagreement.
---@param provenance string|nil
---@return boolean
function M.marked_provenance(provenance)
  return type(provenance) == "string" and MARKED[provenance] == true
end

--- Read one provenance value off an entry, in whichever spelling it arrived.
---@param entry table
---@return string|nil case_name, string|nil reason
local function read_provenance(entry)
  local raw = entry.provenance or entry.Provenance
  if raw == nil then return nil, nil end
  -- A bare string: the wire value ("build_disagrees"), or a case name.
  if type(raw) == "string" then
    if raw == "" then return nil, nil end
    return raw, nil
  end
  if type(raw) ~= "table" then return nil, nil end
  local case = raw.Case or raw.case
  if type(case) ~= "string" or case == "" then return nil, nil end
  -- BuildDisagrees carries WHY in Fields: the case name of the disagreement.
  local fields = raw.Fields or raw.fields
  local reason
  if type(fields) == "table" then
    local first = fields[1]
    if type(first) == "table" then
      reason = first.Case or first.case
    elseif type(first) == "string" then
      reason = first
    end
  end
  return case, reason
end

M.read_provenance = read_provenance

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
    source_locations = {},  -- testName → {CellId, TestName, FilePath, StartLine, EndLine}
    providers = {},  -- [string]
    run_phase = "Idle",  -- "Idle" | "Running" | "RunningButEdited"
    generation = 0,      -- current RunGeneration int
    freshness = nil,     -- "Fresh" | "StaleCodeEdited" | "StaleWrongGeneration" | nil
    completion = nil,    -- "Complete" | "Partial" | "Superseded" | nil
    -- What the last finished run said about the build it ran against (the event's
    -- own `source`). nil until a run says one, which is what a daemon older than
    -- that field leaves forever: nil is "not said", never "in sync".
    run_source = nil,
    _file_index = {},    -- file → { testId → true } (O(1) file lookup, maintained incrementally)
    _version = 0,        -- mutation counter for render skip (FDA short-circuit / Nu ViewVersion)
    failure_narratives = {},  -- testId → {TestId, Summary, TimeSinceLastPass, CausalChanges}
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

  -- What code produced this row's verdict, in the daemon's own words. nil when
  -- the daemon sent none, which is every daemon older than the field: absent is
  -- "not said", never "confirmed" and never "disagreed".
  local provenance, provenance_reason = read_provenance(entry)

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
    -- Why the daemon skipped it ("pending (ptest)", "not focused"); only while Skipped.
    skip_reason = entry.status == "Skipped" and entry.skipReason or nil,
    -- What code produced this verdict, and (for BuildDisagrees) why the build
    -- disagreed. Rendered by gutter_sign, next to the status colour.
    provenance = provenance,
    provenanceReason = provenance_reason,
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
    existing.skip_reason = nil -- this legacy shape carries no reason
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
--- The reason the daemon gave for a Skipped status ({Case="Skipped", Fields={reason}}),
--- read before the status is unwrapped to its case name. nil when there is none.
local function skip_reason_of(status)
  if type(status) ~= "table" or status.Case ~= "Skipped" or type(status.Fields) ~= "table" then return nil end
  local reason = status.Fields[1]
  if type(reason) == "string" and reason ~= "" then return reason end
  return nil
end

function M.normalize_entry(entry)
  if not entry then return entry end
  local skip_reason = skip_reason_of(entry.status) or skip_reason_of(entry.Status)
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
    entry.skipReason = skip_reason
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
  -- Unwrap DU values for fields that should be plain strings. `provenance` is
  -- deliberately NOT in this list: `read_provenance` reads it where a row is
  -- built, and it needs the Fields that carry WHY the build disagreed.
  for _, f in ipairs({"status", "category", "currentPolicy", "previousStatus"}) do
    if type(out[f]) == "table" then
      out[f] = unwrap_du(out[f])
    end
  end
  -- The provenance is NOT unwrapped to its case name here: `read_provenance`
  -- reads it where a row is built, and it keeps the Fields that carry WHY the
  -- build disagreed. Unwrapping here would throw that away.
  out.skipReason = skip_reason
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

--- Normalize a TestSummary from PascalCase to lowercase keys.
---
--- roast §5.3 [HIGH]: this used to keep only the six counts and silently
--- drop DiscoveryGeneration, DiscoveryState, ActivityText (and Enabled,
--- NotYetRun, Activity, ActivityShort, LastDecision — see note below). The
--- server states the contract at SageFs.Core/SseWriter.fs:114-117,129-130:
---   "Discovery is REPLACEMENT state: clients must reject summaries whose
---   DiscoveryGeneration is older than the last one they applied, and
---   ReadyZeroTests/ready_zero_tests is how a completed discovery with zero
---   tests becomes observable" — distinct from "discovery hasn't run yet".
---   "The activity is the session's one state; clients render its words
---   instead of rebuilding a state from the counts."
--- discovery_generation is left nil (not defaulted to 0) when absent —
--- some callers only ever get the bare 7-field TestSummary record with no
--- discovery context at all (e.g. TestResultsBatchPayload.Summary,
--- SseWriter.fs:150-155), and defaulting to 0 there would make
--- should_accept_summary wrongly reject every later push as "older".
---@param summary table
---@return table normalized summary
function M.normalize_summary(summary)
  if not summary then return nil end
  -- If already lowercase, return as-is
  if summary.total ~= nil then return summary end
  local discovery_state = summary.DiscoveryState or summary.discoveryState
  return {
    total = summary.Total or 0,
    passed = summary.Passed or 0,
    failed = summary.Failed or 0,
    stale = summary.Stale or 0,
    running = summary.Running or 0,
    disabled = summary.Disabled or 0,
    discovery_generation = summary.DiscoveryGeneration or summary.discoveryGeneration,
    discovery_state = discovery_state,
    -- "ready_zero_tests" is not its own wire field — it's one of
    -- DiscoveryState's four values (LiveTestingTypes.fs:1500-1511:
    -- Disabled | Discovering | ReadyZeroTests | ReadyWithTests) — derived
    -- here so callers get a plain boolean for the one case they actually
    -- care to distinguish.
    ready_zero_tests = discovery_state == "ready_zero_tests",
    activity_text = summary.ActivityText or summary.activityText,
  }
end

--- Whether a newly-received TestSummary should replace the current one.
--- Discovery is REPLACEMENT state (SseWriter.fs:114-117): the server states
--- clients MUST reject a summary whose DiscoveryGeneration is older than
--- the last one they applied. A summary with no discovery_generation
--- (older daemon builds, or a call site whose payload never carries
--- discovery context — see normalize_summary) carries nothing to compare
--- against, so it is always accepted; this guard only fires when both
--- sides know their generation.
---@param state table current live-testing state
---@param normalized table|nil a normalize_summary(...) result
---@return boolean
function M.should_accept_summary(state, normalized)
  if not normalized then return false end
  local incoming = normalized.discovery_generation
  if incoming == nil then return true end
  local current = state.summary and state.summary.discovery_generation
  if current == nil then return true end
  return incoming >= current
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
    local normalized = M.normalize_summary(summary)
    -- GET /api/live-testing/status (Mcp.fs:2200-2202) nests DiscoveryState
    -- as a SIBLING of Summary, not embedded inside it the way the
    -- incremental test_summary SSE event does (SseWriter.fs:130-143) — the
    -- bare TestSummary record has no discovery fields at all. Merge it in
    -- here so every consumer of state.summary sees one shape regardless of
    -- which endpoint it came from. This is a full authoritative snapshot
    -- (not an incremental push), so it always applies — no generation guard.
    local discovery_state = data.DiscoveryState or data.discoveryState
    if discovery_state then
      normalized.discovery_state = discovery_state
      normalized.ready_zero_tests = discovery_state == "ready_zero_tests"
    end
    state.summary = normalized
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

--- The mark itself, the words for it, and why it is one glyph rather than a word.
-- A row is one gutter sign wide, so the mark has to be a glyph. The words live on
-- the row itself (row_mark_text) and in the tooltip (to_diagnostics / the picker
-- preview), so the sign only has to be loud, not legible.
local MARK_TEXT = "▲"   -- ▲ the build disagreed with this row
local MARK_HL = "SageFsTestUnconfirmed"

--- The glyph shown on a row whose provenance is BuildDisagrees, or nil.
---@param provenance string|nil
---@return string|nil
function M.provenance_glyph(provenance)
  if not M.marked_provenance(provenance) then return nil end
  return MARK_TEXT
end

--- One sentence saying why a row is marked, or nil when it is not marked.
---@param provenance string|nil
---@param reason string|nil the BuildDisagreement case the daemon sent
---@return string|nil

--- What the daemon says the build did, per BuildDisagreement case
--- (SageFs.Core/Features/LiveTestingTypes.fs).
local DISAGREEMENT_WORDS = {
  BuildFailed = "the real build failed, so this result is not confirmed",
  ResultDiffers = "the real build disagreed with the result the session produced",
  BuildUnanswered = "the real build did not answer, so this result is not confirmed",
}

function M.provenance_words(provenance, reason)
  if not M.marked_provenance(provenance) then return nil end
  local why = DISAGREEMENT_WORDS[reason]
  if why then return why end
  -- A daemon whose BuildDisagreement grew a case the plugin has not heard of
  -- still gets a mark, just not a reason this build can name.
  return "the real build disagreed with this result, so it is not confirmed"
end

--- The mark a row carries, if any: a glyph plus the words, or nil for a row
--- whose verdict this build agrees with (including Evaluated, which is normal).
---@param test table a row from state.tests
---@return { glyph: string, hl: string, words: string, reason: string|nil }|nil
function M.provenance_mark(test)
  if type(test) ~= "table" then return nil end
  if not M.marked_provenance(test.provenance) then return nil end
  return {
    glyph = MARK_TEXT,
    hl = MARK_HL,
    words = M.provenance_words(test.provenance, test.provenanceReason),
    reason = test.provenanceReason,
  }
end

--- The status a row shows WITH its provenance mark folded in, as words. This is
--- where status and provenance are decided together, so no consumer has to grow a
--- second, parallel notion of "does this row look trustworthy".
---@param status string|nil
---@param provenance string|nil
---@return { text: string, hl: string, marked: boolean, words: string|nil }
function M.row_mark(status, provenance)
  local sign = M.gutter_sign(status)
  local words = M.provenance_words(provenance)
  if not words then
    return { text = sign.text, hl = sign.hl, marked = false }
  end
  -- The glyph rides in front of the status glyph so it reads as a qualifier on
  -- it: "▲✓" is a pass that no build confirmed, not a new status of its own.
  return {
    text = MARK_TEXT .. sign.text,
    hl = MARK_HL,
    marked = true,
    words = words,
  }
end

--- Get gutter sign for a test status
---
--- `provenance` is what code produced this row's verdict. Only BuildDisagrees
--- changes anything: the row keeps saying what the test did and gains a loud
--- mark, because a green row no build agreed with is the one green that misleads.
---@param status string
---@param provenance string|nil
---@return {text: string, hl: string, status: string|nil, marked: boolean|nil, words: string|nil}
function M.gutter_sign(status, provenance)
  local base
  if status == "Passed" then
    base = { text = "✓", hl = "SageFsTestPassed" }
  elseif status == "Failed" then
    base = { text = "✖", hl = "SageFsTestFailed" }
  elseif status == "Running" or status == "Queued" then
    base = { text = "⏳", hl = "SageFsTestRunning" }
  elseif status == "Stale" then
    base = { text = "~", hl = "SageFsTestStale" }
  elseif status == "PolicyDisabled" then
    base = { text = "⊘", hl = "SageFsTestDisabled" }
  elseif status == "Skipped" then
    base = { text = "⊘", hl = "SageFsTestSkipped" }
  elseif status == "Detected" then
    base = { text = "◦", hl = "SageFsTestDetected" }
  else
    base = { text = " ", hl = "Normal" }
  end
  -- `status` travels with the sign so a consumer that renders the row in words
  -- (the picker preview, a diagnostic) can still say "Passed" on a marked row
  -- instead of only showing the mark.
  base.status = status
  base.marked = false
  local words = M.provenance_words(provenance)
  if not words then return base end
  -- A row whose build disagreed is loud in the build's colour, not the status's:
  -- the status glyph is still in the text, and `status` is still in the table.
  return {
    text = MARK_TEXT .. base.text,
    hl = MARK_HL,
    status = status,
    marked = true,
    words = words,
  }
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
      local normalized = M.normalize_summary(summary)
      if M.should_accept_summary(state, normalized) then
        state.summary = normalized
      end
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
---
--- `source` is what THIS run says about the build it ran against: a green test
--- over a stale build is not a green test, and the daemon that can say so should.
--- A daemon older than the field sends none, which leaves `run_source` as it was
--- and leaves `run_source_is_authoritative` false, so the caller keeps asking
--- the session list exactly as it did before. Absence is never read as "in sync".
---
--- A run from an OLDER generation than the one already applied is dropped
--- whole: its results and its verdict belong to a run the newer one replaced.
---
---@param state table
---@param data table|nil {summary: {total, passed, failed, stale, running}, generation: integer?, source: table?}
---@return table state
function M.handle_test_run_completed(state, data)
  if not data then return state end
  local gen = tonumber(data.Generation or data.generation)
  if gen and tonumber(state.generation or 0) and gen < tonumber(state.generation) then
    return state
  end
  if gen then state.generation = gen end
  if data.summary then
    state.summary = data.summary
  end
  -- Only a JSON object with a state string is a verdict. Anything else (absent, a
  -- bare string, a number) is not one, so what was last known stands.
  local src = data.source or data.Source
  if type(src) == "table" and type(src.state) == "string" then
    state.run_source = src
  end
  state._version = state._version + 1
  return state
end

--- Whether the last finished run said which build it ran against.
--- True means the session list does NOT need re-reading for the source verdict:
--- the run's own event already carried it. False (a nil source, including
--- against a daemon older than the field) means the list is still the answer.
---@param state table
---@return boolean
function M.run_source_is_authoritative(state)
  if type(state) ~= "table" then return false end
  local src = state.run_source
  return type(src) == "table" and type(src.state) == "string"
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

--- Handle test_source_locations SSE event (daemon-resolved source locations).
--- Caches by TestName for telescope lookup and by FilePath for panel/gutter.
---@param state table
---@param data table {Locations: [{CellId: int, TestName: string, FilePath: string, StartLine: int, EndLine: int}]}
---@return table
function M.handle_source_locations(state, data)
  if not data then return state end
  local locations = data.Locations or data.locations
  if not locations then return state end
  local by_name = {}
  local by_file = {}
  for _, loc in ipairs(locations) do
    local name = loc.TestName or loc.testName
    local file = loc.FilePath or loc.filePath
    if name then by_name[name] = loc end
    if file then
      if not by_file[file] then by_file[file] = {} end
      table.insert(by_file[file], loc)
    end
  end
  state.source_locations = by_name
  state.locations = by_file
  state._version = state._version + 1
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
  local normalized = M.normalize_summary(data)
  if M.should_accept_summary(state, normalized) then
    state.summary = normalized
  end
  return state
end

--- Handle failure_narratives SSE event.
--- Caches enriched failure context keyed by TestId for display in test panel.
---@param state table
---@param data table[] array of {TestId, Summary, TimeSinceLastPass, CausalChanges}
---@return table state
function M.handle_failure_narratives(state, data)
  if not data then return state end
  local items = type(data) == "table" and data or {}
  local by_id = state.failure_narratives or {}
  for _, narrative in ipairs(items) do
    local id = narrative.TestId or narrative.testId
    if id then by_id[id] = narrative end
  end
  state.failure_narratives = by_id
  state._version = (state._version or 0) + 1
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

--- The text after a test's name: why the daemon skipped it, when it said.
---@param status string
---@param reason string|nil
---@return string
local function skip_suffix(status, reason)
  if status == "Skipped" and type(reason) == "string" and reason ~= "" then
    return string.format(" (skipped: %s)", reason)
  end
  return ""
end

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
      skip_reason = test.skip_reason,
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
    table.insert(lines, string.format("%s %s%s", icon, e.displayName, skip_suffix(e.status, e.skip_reason)))
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
---@param opts {pattern?: string, category?: string, session_id?: string}
---@return table|nil request, string|nil error
function M.build_run_request(opts)
  opts = opts or {}
  if opts.category and opts.category ~= "" and not M.is_valid_category(opts.category) then
    return nil, "invalid category: " .. tostring(opts.category)
  end
  local req = {
    pattern = opts.pattern or "",
    category = opts.category or "",
  }
  -- The daemon refuses a run that names no session once there are several.
  if type(opts.session_id) == "string" and opts.session_id ~= "" then req.sessionId = opts.session_id end
  return req, nil
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
  if s.total == 0 then
    -- roast §5.3: "Tests: 0" rendered identically whether discovery hadn't
    -- run yet or genuinely found nothing — the client-side twin of the
    -- server's own zero-test-suppression defect. discovery_state (when the
    -- server sent one) tells them apart; unknown falls back to the old text.
    local discovery_state = state.summary and state.summary.discovery_state
    if discovery_state == "discovering" then
      return "Tests: discovering…"
    elseif discovery_state == "ready_zero_tests" then
      return "Tests: none found"
    end
    return "Tests: 0"
  end
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
      skip_reason = test.skip_reason,
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
      text = string.format("%s %s%s", icon, e.displayName, skip_suffix(e.status, e.skip_reason)),
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
      text = string.format("%s %s%s", icon, t.displayName or t.testId, skip_suffix(t.status, t.skip_reason)),
      file = t.file,
      line = t.line,
    })
  end

  return entries
end

return M
