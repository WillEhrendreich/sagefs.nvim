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
  "SageFsWarmupContext",
  "SageFsHotReloadSnapshot",
  "SageFsProvidersDetected",
  "SageFsAffectedTestsComputed",
  "SageFsTestCycleTimingRecorded",
  "SageFsRunTestsRequested",
  "SageFsTestSummary",
  "SageFsFileAnnotations",
  "SageFsBindingsSnapshot",
  "SageFsTestTrace",
  "SageFsReconnecting",
  "SageFsTestRecoveryNeeded",
  "SageFsEvalDiff",
  "SageFsCellDependencies",
  "SageFsBindingScopeMap",
  "SageFsEvalTimeline",
  "SageFsEvalResult",
  "SageFsWarmupProgress",
  -- Phase 7C: lifecycle events
  "SageFsSessionFaulted",
  "SageFsWarmupCompleted",
  "SageFsFileReloaded",
  "SageFsSystemAlarm",
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
  warmup_context = "SageFsWarmupContext",
  hotreload_snapshot = "SageFsHotReloadSnapshot",
  providers_detected = "SageFsProvidersDetected",
  affected_tests_computed = "SageFsAffectedTestsComputed",
  test_cycle_timing_recorded = "SageFsTestCycleTimingRecorded",
  run_tests_requested = "SageFsRunTestsRequested",
  test_summary = "SageFsTestSummary",
  file_annotations = "SageFsFileAnnotations",
  bindings_snapshot = "SageFsBindingsSnapshot",
  test_trace = "SageFsTestTrace",
  reconnecting = "SageFsReconnecting",
  test_recovery_needed = "SageFsTestRecoveryNeeded",
  eval_diff = "SageFsEvalDiff",
  cell_dependencies = "SageFsCellDependencies",
  binding_scope_map = "SageFsBindingScopeMap",
  eval_timeline = "SageFsEvalTimeline",
  eval_result = "SageFsEvalResult",
  failure_narratives = "SageFsFailureNarratives",
  warmup_progress = "SageFsWarmupProgress",
  -- Phase 7C: lifecycle events
  session_faulted = "SageFsSessionFaulted",
  warmup_completed = "SageFsWarmupCompleted",
  file_reloaded = "SageFsFileReloaded",
  system_alarm = "SageFsSystemAlarm",
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
