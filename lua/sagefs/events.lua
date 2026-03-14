-- sagefs/events.lua — Pure User autocmd event definitions
-- Defines event names and payload construction for vim User autocmds
-- Zero vim dependencies

local M = {}

local EVENT_CATALOG = {
  { "eval_completed", "SageFsEvalCompleted" },
  { "test_passed", "SageFsTestPassed" },
  { "test_failed", "SageFsTestFailed" },
  { "test_results_batch", "SageFsTestResultsBatch" },
  { "test_run_started", "SageFsTestRunStarted" },
  { "test_run_completed", "SageFsTestRunCompleted" },
  { "test_state", "SageFsTestState" },
  { "tests_discovered", "SageFsTestsDiscovered" },
  { "test_source_locations", "SageFsTestSourceLocations" },
  { "connected", "SageFsConnected" },
  { "disconnected", "SageFsDisconnected" },
  { "coverage_updated", "SageFsCoverageUpdated" },
  { "hot_reload_triggered", "SageFsHotReloadTriggered" },
  { "warmup_context", "SageFsWarmupContext" },
  { "hotreload_snapshot", "SageFsHotReloadSnapshot" },
  { "providers_detected", "SageFsProvidersDetected" },
  { "affected_tests_computed", "SageFsAffectedTestsComputed" },
  { "test_cycle_timing_recorded", "SageFsTestCycleTimingRecorded" },
  { "run_tests_requested", "SageFsRunTestsRequested" },
  { "test_summary", "SageFsTestSummary" },
  { "file_annotations", "SageFsFileAnnotations" },
  { "bindings_snapshot", "SageFsBindingsSnapshot" },
  { "test_trace", "SageFsTestTrace" },
  { "reconnecting", "SageFsReconnecting" },
  { "test_recovery_needed", "SageFsTestRecoveryNeeded" },
  { "eval_diff", "SageFsEvalDiff" },
  { "cell_dependencies", "SageFsCellDependencies" },
  { "binding_scope_map", "SageFsBindingScopeMap" },
  { "eval_timeline", "SageFsEvalTimeline" },
  { "eval_result", "SageFsEvalResult" },
  { "failure_narratives", "SageFsFailureNarratives" },
  { "warmup_progress", "SageFsWarmupProgress" },
  { "session_faulted", "SageFsSessionFaulted" },
  { "warmup_completed", "SageFsWarmupCompleted" },
  { "file_reloaded", "SageFsFileReloaded" },
  { "system_alarm", "SageFsSystemAlarm" },
}

-- ─── Event Names ──────────────────────────────────────────────────────────────

M.EVENT_NAMES = {}

-- ─── Event Type → Pattern Mapping ─────────────────────────────────────────────

local EVENT_MAP = {}

for _, entry in ipairs(EVENT_CATALOG) do
  local event_type = entry[1]
  local pattern = entry[2]
  EVENT_MAP[event_type] = pattern
  table.insert(M.EVENT_NAMES, pattern)
end

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
