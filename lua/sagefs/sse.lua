-- sagefs/sse.lua — SSE message parser
-- Pure parsing logic, no vim API dependencies — fully testable with busted
local M = {}

--- Parse a chunk of SSE text into events and unconsumed remainder
--- Events are delimited by blank lines (\n\n)
--- Each event can have: event: <type>, data: <payload>, : <comment>
---@param chunk string
---@return {type: string?, data: string?}[], string remainder
function M.parse_chunk(chunk)
  local events = {}
  local remainder = ""

  if not chunk or chunk == "" then
    return events, ""
  end

  -- Split on double-newline (event boundary)
  -- Handle both \n\n and \r\n\r\n
  local normalized = chunk:gsub("\r\n", "\n")

  -- Find all complete events (terminated by \n\n)
  local pos = 1
  while true do
    local boundary = normalized:find("\n\n", pos, true)
    if not boundary then
      -- No more complete events; rest is remainder
      remainder = normalized:sub(pos)
      break
    end

    local event_text = normalized:sub(pos, boundary - 1)
    pos = boundary + 2

    -- Parse the event lines
    local event_type = nil
    local data_parts = {}

    for line in (event_text .. "\n"):gmatch("([^\n]*)\n") do
      if line:match("^:") then
        -- Comment, ignore
      elseif line:match("^event: ") then
        event_type = line:match("^event: (.+)")
      elseif line:match("^data: ") then
        table.insert(data_parts, line:match("^data: (.+)"))
      elseif line:match("^data:$") then
        table.insert(data_parts, "")
      end
    end

    local data = nil
    if #data_parts > 0 then
      data = table.concat(data_parts, "\n")
    end

    table.insert(events, { type = event_type, data = data })
  end

  return events, remainder
end

--- Calculate reconnection delay with exponential backoff and ±20% jitter
---@param attempt number Attempt number (1-based)
---@return number Delay in milliseconds
function M.reconnect_delay(attempt)
  local base = 1000 * (2 ^ (attempt - 1))
  if base > 32000 then base = 32000 end
  local jitter = 0.8 + math.random() * 0.4  -- ±20%
  return math.floor(base * jitter)
end

--- Map reconnect attempt number to a connection status string.
--- 0 = connected (successful), 1-4 = reconnecting, 5+ = disconnected.
---@param attempt number Current attempt (0 = connected)
---@return string "connected"|"reconnecting"|"disconnected"
function M.connection_status(attempt)
  if attempt <= 0 then return "connected" end
  if attempt < 5 then return "reconnecting" end
  return "disconnected"
end

--- Classify an SSE event into an action type
---@param event {type: string?, data: string?}|nil
---@return {action: string, data: string?}|nil
function M.classify_event(event)
  if not event then return nil end

  local type_to_action = {
    -- Eval & session
    EvalCompleted = "eval_completed",
    SessionCreated = "session_created",
    SessionStopped = "session_stopped",
    DiagnosticsUpdated = "diagnostics_updated",
    state = "state_update",
    -- Testing cycle (PascalCase — internal Elm events)
    TestLocationsDetected = "test_locations_detected",
    TestsDiscovered = "tests_discovered",
    TestRunStarted = "test_run_started",
    TestRunCompleted = "test_run_completed",
    TestResultsBatch = "test_results_batch",
    LiveTestingEnabled = "live_testing_enabled",
    LiveTestingDisabled = "live_testing_disabled",
    AffectedTestsComputed = "affected_tests_computed",
    RunPolicyChanged = "run_policy_changed",
    ProvidersDetected = "providers_detected",
    TestCycleTimingRecorded = "test_cycle_timing_recorded",
    RunTestsRequested = "run_tests_requested",
    -- Testing cycle (snake_case — typed SSE events from SageFs)
    test_results_batch = "test_results_batch",
    test_summary = "test_summary",
    test_run_started = "test_run_started",
    test_run_completed = "test_run_completed",
    tests_discovered = "tests_discovered",
    live_testing_enabled = "live_testing_enabled",
    live_testing_disabled = "live_testing_disabled",
    providers_detected = "providers_detected",
    test_cycle_timing_recorded = "test_cycle_timing_recorded",
    -- Source locations (daemon-resolved test → file mapping)
    test_source_locations = "test_source_locations",
    TestSourceLocations = "test_source_locations",
    -- Coverage
    CoverageUpdated = "coverage_updated",
    CoverageCleared = "coverage_cleared",
    -- File annotations (inline feedback: CodeLens, failures, coverage detail)
    file_annotations = "file_annotations",
    FileAnnotationsUpdated = "file_annotations",
    -- File watching
    HotReloadTriggered = "hot_reload_triggered",
    FileChanged = "file_changed",
    -- Session events (typed envelope from SageFs daemon)
    session = "session_event",
    -- CQRS: server-pushed bindings and test trace state
    bindings_snapshot = "bindings_snapshot",
    test_trace = "test_trace",
    -- Feature hooks (server-computed, push-only)
    eval_diff = "eval_diff",
    cell_dependencies = "cell_dependencies",
    binding_scope_map = "binding_scope_map",
    eval_timeline = "eval_timeline",
    -- Inline eval result decorations (Sprint 7+ daemon)
    eval_result = "eval_result",
    -- Failure narrative context for tests that transitioned Passed→Failed
    failure_narratives = "failure_narratives",
    FailureNarratives = "failure_narratives",
    -- Warmup progress (phase-by-phase status during session startup)
    warmup_progress = "warmup_progress",
    -- Phase 7C: lifecycle events
    SessionFaulted = "session_faulted",
    session_faulted = "session_faulted",
    WarmupCompleted = "warmup_completed",
    warmup_completed = "warmup_completed",
    FileReloaded = "file_reloaded",
    file_reloaded = "file_reloaded",
    SystemAlarm = "system_alarm",
    system_alarm = "system_alarm",
  }

  local action = type_to_action[event.type] or "unknown"
  return { action = action, data = event.data }
end

--- Build a dispatch table from a handlers map
---@param handlers table<string, function> action string → handler function
---@return table<string, function>
function M.build_dispatch_table(handlers)
  local dt = {}
  for action, fn in pairs(handlers) do
    dt[action] = fn
  end
  return dt
end

--- Dispatch a classified event through the dispatch table
---@param dt table dispatch table from build_dispatch_table
---@param classified {action: string, data: string?}|nil
function M.dispatch(dt, classified)
  if not classified then return end
  local handler = dt[classified.action]
  if handler then
    handler(classified.data)
  end
end

--- Dispatch a batch of classified events with error isolation.
--- Each handler is wrapped in pcall so a throwing handler doesn't
--- prevent subsequent events from being processed.
---@param dt table dispatch table from build_dispatch_table
---@param classified_events table[] list of { action, data? }
---@return table[] errors list of { action, err } for failed handlers
function M.safe_dispatch_batch(dt, classified_events)
  local errors = {}
  for _, classified in ipairs(classified_events) do
    if classified then
      local handler = dt[classified.action]
      if handler then
        local ok, err = pcall(handler, classified.data)
        if not ok then
          table.insert(errors, { action = classified.action, err = err })
        end
      end
    end
  end
  return errors
end

return M
