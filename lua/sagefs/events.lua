-- sagefs/events.lua — Pure User autocmd event definitions
-- Defines event names and payload construction for vim User autocmds
-- Zero vim dependencies

local M = {}

-- ─── Event Names ──────────────────────────────────────────────────────────────

M.EVENT_NAMES = {
  "SageFsEvalCompleted",
  "SageFsTestPassed",
  "SageFsTestFailed",
  "SageFsTestResultsBatch",
  "SageFsTestRunStarted",
  "SageFsTestRunCompleted",
  "SageFsTestState",
  "SageFsTestsDiscovered",
  "SageFsConnected",
  "SageFsDisconnected",
  "SageFsCoverageUpdated",
  "SageFsHotReloadTriggered",
}

-- ─── Event Type → Pattern Mapping ─────────────────────────────────────────────

local EVENT_MAP = {
  eval_completed = "SageFsEvalCompleted",
  test_passed = "SageFsTestPassed",
  test_failed = "SageFsTestFailed",
  test_results_batch = "SageFsTestResultsBatch",
  test_run_started = "SageFsTestRunStarted",
  test_run_completed = "SageFsTestRunCompleted",
  test_state = "SageFsTestState",
  tests_discovered = "SageFsTestsDiscovered",
  connected = "SageFsConnected",
  disconnected = "SageFsDisconnected",
  coverage_updated = "SageFsCoverageUpdated",
  hot_reload_triggered = "SageFsHotReloadTriggered",
}

-- ─── Build Autocmd Data ───────────────────────────────────────────────────────

function M.build_autocmd_data(event_type, payload)
  local pattern = EVENT_MAP[event_type]
  if not pattern then return nil end
  return {
    pattern = pattern,
    data = payload or {},
  }
end

return M
