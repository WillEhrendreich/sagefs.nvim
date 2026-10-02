-- sagefs/init.lua — Thin coordinator for SageFs Neovim plugin
-- Wires pure modules to transport, render, and commands layers.

local cells = require("sagefs.cells")
local format = require("sagefs.format")
local model = require("sagefs.model")
local sessions = require("sagefs.sessions")
local sse_parser = require("sagefs.sse")
local hotreload = require("sagefs.hotreload")
local diagnostics = require("sagefs.diagnostics")
local testing = require("sagefs.testing")
local coverage = require("sagefs.coverage")
local annotations = require("sagefs.annotations")
local events = require("sagefs.events")
local completions = require("sagefs.completions")
local daemon = require("sagefs.daemon")
local compat = require("sagefs.compat")
local discovery = require("sagefs.daemon_discovery")
local transport = require("sagefs.transport")
local render = require("sagefs.render")
local commands = require("sagefs.commands")
local project_config = require("sagefs.config")
local density = require("sagefs.density")
local cell_highlight = require("sagefs.cell_highlight")
local util = require("sagefs.util")
local wire_runtime = require("sagefs.wire_runtime")
local reload_ui = require("sagefs.reload_ui")

local M = {}

M.version = require("sagefs.version")

-- ─── Configuration ───────────────────────────────────────────────────────────

M.config = {
  port = 37749,
  dashboard_port = 37750,
  auto_connect = true,
  check_on_save = false,
  -- The sagefs binary :SageFsStart spawns. A bare name is looked up on PATH;
  -- set a full path when sagefs is installed somewhere PATH does not see.
  sagefs_path = "sagefs",
  -- Daemon lifecycle events that ask for a fresh /api/sessions answer (a
  -- session turning Ready) are coalesced: at most one GET per this many ms.
  session_refresh_debounce_ms = 250,
  -- Say so (vim.notify) when a save needs attention: the new body never ran, a
  -- restart is needed, the file did not compile. The statusline shows the state
  -- either way.
  notify_reload = true,
  -- Override for the one-time-welcome marker file (mainly for tests).
  -- Defaults to stdpath("data") .. "/sagefs_welcomed" when nil.
  welcome_marker_path = nil,
  -- One-time hint of the three most useful commands on the first F# buffer.
  -- `hint = false` turns it off; `hint_marker_path` overrides the marker file
  -- (defaults to stdpath("data") .. "/sagefs_hint_seen").
  hint = true,
  hint_marker_path = nil,
  highlight = {
    success = { fg = "#a6e3a1", italic = true },
    error = { fg = "#f38ba8", italic = true },
    output = { fg = "#a6adc8", italic = true },
    running = { fg = "#f9e2af" },
    stale = { fg = "#6c7086", italic = true },
  },
  cell_highlight = {
    style = "normal", -- "off" | "minimal" | "normal" | "full"
  },
}

-- ─── State ───────────────────────────────────────────────────────────────────

M.state = model.new()
M.testing_state = testing.new()
M.coverage_state = coverage.new()
M.annotations_state = annotations.new()
M.density_state = density.new()
M.daemon_state = daemon.new()
M.active_session = nil
M.warmup_context = nil
M.hotreload_files = {}
M.session_list = {}
M.binding_tracker = format.new_binding_tracker()
M.test_trace = nil
M.timeline_state = require("sagefs.timeline").new()
M.timeline_stats = nil  -- Latest server-pushed eval_timeline stats (for statusline)
M.warmup_phase = nil    -- Current warmup phase (for statusline)
M.warmup_step = 0       -- Current warmup step number
M.warmup_total = 0      -- Total warmup steps
M.warmup_message = ""   -- Current warmup detail message
M.warmup_progress = 0   -- Normalized progress (0.0-1.0)
M.time_travel_state = require("sagefs.time_travel").new()

-- Phase 7C: lifecycle state
M.system_alarm = nil       -- Latest SystemAlarm payload (for statusline ⚠ indicator)
M.last_reload_file = nil   -- Last file reloaded by hot reload (path string)
M.last_reload_ms = nil     -- Elapsed ms for last file reload
M.workflow_label = nil     -- Current workflow label (e.g. "REPL", "Live")
M.app_run_state = nil      -- Latest AppRunState from run-app/stop-app (for statusline)

-- Eval watchdog: monotonic ID tracks which eval is in flight.
-- 0 = idle; >0 = eval in flight (generation counter).
-- Prevents phantom "evaluation interrupted" notifications when a new eval
-- starts within the 5-second watchdog window of a previous eval.
local eval_id = 0
local eval_watchdog_timer = nil

-- SSE connection handle (managed by transport.lua)
local events_sse = nil

-- Wire-compat startup warning: shown at most once per distinct daemon
-- apiVersion (not on every probe/reconnect), and only for a real
-- incompatibility (sagefs/compat.lua), never for a version-number difference.
local compat_warned = {}

-- Pre-allocated namespaces (created once, reused everywhere)
local ns = {
  fsi_diagnostics = vim.api.nvim_create_namespace("sagefs_fsi_diagnostics"),
  shadow_warnings = vim.api.nvim_create_namespace("sagefs_shadow_warnings"),
}
local diag_ns = nil

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function base_url()
  return "http://localhost:" .. M.config.port
end

local function dashboard_url()
  return "http://localhost:" .. M.config.dashboard_port
end

local function notify(msg, level)
  vim.notify("[SageFs] " .. msg, level or vim.log.levels.INFO)
end

-- ─── SSE Dispatch ─────────────────────────────────────────────────────────────

local function decode_event_data(raw)
  local json_str = type(raw) == "string" and raw or (raw and raw.data)
  if not json_str then return nil end
  local ok, data = pcall(vim.json.decode, json_str)
  -- Every handler reads fields off the payload: a JSON null (vim.NIL), number
  -- or string is not one, so it is no event.
  if not ok or type(data) ~= "table" then return nil end
  return data
end

--- Three-way session filter (Wlaschin pattern):
--- 1. No SessionId in data → accept (backward compat with older daemon)
--- 2. No active_session → accept (show everything)
--- 3. Both present → strict match
local function session_matches(data)
  return testing.session_matches(data, M.active_session)
end

--- Did we just ask for a session, so its warmup events are the ones to show?
local function expecting_warmup()
  return M.warmup_expected_until ~= nil and (vim.uv.hrtime() / 1e6) < M.warmup_expected_until
end

--- Is a lifecycle event for session `sid` about the session this editor uses
--- (or is waiting on, right after creating one)?
local function session_is_ours(sid)
  return sessions.warmup_event_is_ours({ sessionId = sid ~= "?" and sid or nil }, M.active_session, expecting_warmup())
end

--- Our session is up: drop the warmup text (the statusline returns early while
--- a phase is set, so "Ready!" stuck forever) and re-read the session list, so
--- the session label stops saying "(Starting)".
local function reset_warmup_text()
  M.warmup_phase = nil
  M.warmup_step = 0
  M.warmup_total = 0
  M.warmup_message = ""
  M.warmup_progress = 0
  M.warmup_expected_until = nil
end

local function clear_warmup_state()
  reset_warmup_text()
  vim.schedule(function() M.list_sessions() end)
end

local function fire_user_event(event_type, payload)
  local evt = events.build_autocmd_data(event_type, payload)
  if evt then
    vim.schedule(function()
      pcall(vim.api.nvim_exec_autocmds, "User", { pattern = evt.pattern, data = evt.data })
    end)
  end
end

-- The daemon's hot reload and REPL-freshness wire, folded and surfaced
-- (wire_runtime.lua has the logic; this only supplies the editor's hands).
local wire = nil
function M.wire_runtime()
  if not wire then
    wire = wire_runtime.new({
      notify = notify,
      now_ms = function() return vim.uv.hrtime() / 1e6 end,
      -- A bare request (a session turning Ready) shares the coalescing window
      -- with every other lifecycle event; a caller with a callback wants its answer now.
      refresh_sessions = function(cb) if cb then M.list_sessions(cb) else M.refresh_sessions_soon() end end,
      active_session = function() return M.active_session end,
      redraw = function() vim.schedule(function() pcall(vim.cmd, "redrawstatus") end) end,
      redraw_later = function(ms) vim.defer_fn(function() pcall(vim.cmd, "redrawstatus") end, ms) end,
      ui = reload_ui,
      notify_reload = M.config.notify_reload,
      on_freshness = function(sid, f) fire_user_event("repl_freshness_changed", { sessionId = sid, freshness = f }) end,
    })
  end
  return wire
end

-- Dispatch table: action string → handler(raw_event)
-- Each handler receives the raw SSE event and decodes data as needed.
local dispatch_table

-- Data-driven SSE handler definitions (Muratori semantic compression, R10).
-- Each entry: { action, handler_fn, target ("testing"|"coverage"|"annotations"), session_scoped, event_name }
-- Custom handlers are closures that don't fit the pattern.
-- §5.4: `session_scoped` was applied to 5 of 11 testing/coverage handlers.
-- With two sessions on one daemon, session B's discovered test set, run
-- policy, source locations, providers and coverage merged into the
-- client's single state while only B's results/summaries were correctly
-- filtered out — session B's test list wearing session A's results. Every
-- handler that mutates per-session testing/coverage state now filters on
-- `session_matches`, matching the ones that already did.
local SSE_HANDLER_DEFS = {
  -- Testing cycle (decode + state update ± session check ± event)
  { action = "tests_discovered", fn = "handle_tests_discovered", target = "testing", session_scoped = true },
  { action = "test_results_batch", fn = "handle_results_batch", target = "testing", session_scoped = true, event = "test_results_batch" },
  { action = "test_run_started", fn = "handle_test_run_started", target = "testing", session_scoped = true, event = "test_run_started" },
  { action = "test_run_completed", fn = "handle_test_run_completed", target = "testing", session_scoped = true, event = "test_run_completed" },
  { action = "run_policy_changed", fn = "handle_run_policy_changed", target = "testing", session_scoped = true },
  { action = "test_locations_detected", fn = "handle_test_locations", target = "testing", session_scoped = true },
  { action = "test_source_locations", fn = "handle_source_locations", target = "testing", session_scoped = true, event = "test_source_locations" },
  { action = "providers_detected", fn = "handle_providers_detected", target = "testing", session_scoped = true, event = "providers_detected" },
  { action = "test_summary", fn = "handle_test_summary", target = "testing", session_scoped = true, event = "test_summary" },
  -- Coverage
  { action = "coverage_updated", fn = "apply_coverage_response", target = "coverage", session_scoped = true, event = "coverage_updated" },
  -- Annotations
  { action = "file_annotations", fn = "handle_file_annotations", target = "annotations", session_scoped = true, event = "file_annotations" },
  -- Fire-event-only (decode + fire, no state update)
  { action = "affected_tests_computed", event = "affected_tests_computed" },
  { action = "test_cycle_timing_recorded", event = "test_cycle_timing_recorded" },
  { action = "run_tests_requested", event = "run_tests_requested" },
  { action = "eval_completed", event = "eval_completed" },
  { action = "hot_reload_triggered", event = "hot_reload_triggered" },
  -- Cohort rows: one cohort spans every session, so none is session-scoped.
  -- :SageFsCohort refreshes on these (cohort_view.lua).
  { action = "cohort_matrix", event = "cohort_matrix" },
  { action = "claim_changed", event = "claim_changed" },
  { action = "landing_changed", event = "landing_changed" },
  { action = "save_observed", event = "save_observed" },
  { action = "cohort_changed", event = "cohort_changed" },
  -- Feature hooks (server-computed, push-only)
  { action = "eval_diff", event = "eval_diff" },
  { action = "cell_dependencies", event = "cell_dependencies" },
  { action = "binding_scope_map", event = "binding_scope_map" },
  { action = "eval_timeline", event = "eval_timeline" },
  -- Inline eval result decorations — fire event so plugins can display ghost text
  { action = "eval_result", event = "eval_result" },
  -- Failure narrative context for tests that transitioned Passed→Failed
  { action = "failure_narratives", fn = "handle_failure_narratives", target = "testing", event = "failure_narratives" },
  -- Coverage view: per-function aggregate badge (one per CoverageView)
  { action = "coverage_view", fn = "apply_coverage_view", target = "coverage", session_scoped = true, event = "coverage_view" },
}

-- State target → { state_key, module }
local TARGET_MAP = {
  testing = { key = "testing_state", mod = function() return testing end },
  coverage = { key = "coverage_state", mod = function() return coverage end },
  annotations = { key = "annotations_state", mod = function() return annotations end },
}

M.session_event_seq = 0
M.session_event_stamp = {}

local session_refresh_pending = false

--- Ask for the authoritative /api/sessions answer soon. A burst of requests
--- inside one window shares a single GET.
local function refresh_sessions_soon()
  if session_refresh_pending then return end
  session_refresh_pending = true
  vim.defer_fn(function()
    session_refresh_pending = false
    M.list_sessions()
  end, M.config.session_refresh_debounce_ms or 250)
end
M.refresh_sessions_soon = refresh_sessions_soon

--- Fold a session lifecycle announcement (sessions.lifecycle_update) into
--- the session list and the active session. Returns whether the session was
--- known, plus its id.
local function fold_session_update(data)
  local sid, fields = sessions.lifecycle_update(data)
  if not sid then return false, nil end
  -- Remember when this session last changed by event, so an older
  -- /api/sessions answer cannot undo it (see M.list_sessions).
  M.session_event_seq = M.session_event_seq + 1
  M.session_event_stamp[sid] = M.session_event_seq
  local found
  M.session_list, M.active_session, found = sessions.apply_update(M.session_list, M.active_session, sid, fields)
  return found, sid
end

local function build_handlers()
  local handlers = {}

  -- Validate definitions at build time (Wlaschin: cheap defense in depth)
  format.validate_handler_defs(SSE_HANDLER_DEFS)

  -- Generate handlers from data-driven definitions
  for _, def in ipairs(SSE_HANDLER_DEFS) do
    handlers[def.action] = function(raw)
      local data = decode_event_data(raw)
      if not data then return end
      if def.session_scoped and not session_matches(data) then return end
      if def.fn and def.target then
        local t = TARGET_MAP[def.target]
        M[t.key] = t.mod()[def.fn](M[t.key], data)
      end
      if def.event then fire_user_event(def.event, data) end
    end
  end

  -- Custom handlers that don't fit the pattern
  -- Daemon 0.6 folds most lifecycle changes into a single `state` SSE event whose
  -- real discriminant is a field inside the JSON. Decode the envelope, classify it,
  -- and route to the specific handler; unrecognized/heartbeat states are keepalive.
  handlers.state_update = function(raw)
    M.state = model.set_status(M.state, "connected")
    local data = decode_event_data(raw)
    if not data then return end
    local action = sse_parser.classify_state_event(data)
    if action ~= "state_update" and handlers[action] then
      handlers[action](raw)
    end
  end
  handlers.live_testing_enabled = function(raw)
    local data = decode_event_data(raw)
    if data then M.testing_state = testing.set_enabled(M.testing_state, true) end
  end
  handlers.live_testing_disabled = function(raw)
    local data = decode_event_data(raw)
    if data then M.testing_state = testing.set_enabled(M.testing_state, false) end
  end
  handlers.coverage_cleared = function(_raw)
    M.coverage_state = coverage.clear(M.coverage_state)
  end
  handlers.diagnostics_updated = function(raw)
    local data = decode_event_data(raw)
    if data and data.diagnostics then
      M.apply_diagnostics(data.diagnostics)
    end
  end
  -- `state {"sessionReady": <sid>}`: the daemon says warmup finished. This
  -- was classified as "session_ready" and then dropped, so the statusline
  -- kept the "(Starting)" snapshot taken right after create.
  handlers.session_ready = function(raw)
    local data = decode_event_data(raw)
    if not data then return end
    local _, sid = fold_session_update(data)
    if not sid then return end
    -- The daemon also sends Ready as a plain "state changed" signal right
    -- before a fault, and may announce a session the list does not know yet:
    -- the folded status is a best guess, the list is the authority.
    -- The worker was replaced: forget what reload events said about it, and
    -- ask for the list (through the coalescing window above).
    M.wire_runtime().on_session_ready(data)
    -- Ours, or no session picked yet: the warmup text is done. (The list
    -- re-read above is the one the label needs, so no second one here.)
    if not M.active_session or session_is_ours(sid) then
      reset_warmup_text()
    end
  end
  handlers.session_event = function(raw)
    local data = decode_event_data(raw)
    if not data then return end
    local event_type = data.type
    if event_type == "warmup_context_snapshot" then
      -- Another session's warmup context is not this session's.
      if data.sessionId and M.active_session and data.sessionId ~= M.active_session.id then return end
      M.warmup_context = data.context
      -- Clear warmup progress state — session is ready
      clear_warmup_state()
      fire_user_event("warmup_context", data)
    elseif event_type == "session_health_changed" then
      fold_session_update(data)
    elseif event_type == "hotreload_snapshot" then
      M.hotreload_files = data.watchedFiles or {}
      fire_user_event("hotreload_snapshot", data)
    elseif event_type == "workflow_switched" then
      M.workflow_label = data.workflowLabel or data.WorkflowLabel
      fire_user_event("workflow_switched", data)
    elseif event_type == "workflow_switching" then
      fire_user_event("workflow_switching", data)
    end
  end
  handlers.bindings_snapshot = function(raw)
    local data = decode_event_data(raw)
    if not data then return end
    local bindings = data.Bindings or data.bindings
    if not bindings then return end
    M.binding_tracker = format.tracker_from_snapshot(bindings)
    fire_user_event("bindings_snapshot", data)
  end
  handlers.test_trace = function(raw)
    local data = decode_event_data(raw)
    if not data then return end
    M.test_trace = data
    fire_user_event("test_trace", data)
  end
  -- eval_timeline: store server-computed stats for statusline + fire event
  handlers.eval_timeline = function(raw)
    local data = decode_event_data(raw)
    if not data then return end
    M.timeline_stats = data
    fire_user_event("eval_timeline", data)
  end
  -- warmup_progress: track warmup phase for statusline + notify on phase transitions
  handlers.warmup_progress = function(raw)
    local data = decode_event_data(raw)
    if not data then return end
    -- Every session's warmup reaches every client of a shared daemon: only
    -- react to the one this editor is waiting on.
    if not sessions.warmup_event_is_ours(data, M.active_session, expecting_warmup()) then return end
    local prev_phase = M.warmup_phase
    -- The 0.6 state-shaped progress event has a step but no phase: keep the
    -- phase we know instead of blanking it (which made the next legacy event
    -- look like a "transition" and announce an empty "Warming up:").
    M.warmup_phase = data.Phase or data.phase or M.warmup_phase
    M.warmup_step = data.Step or data.step or 0
    M.warmup_total = data.Total or data.total or 0
    M.warmup_message = data.Message or data.message or ""
    M.warmup_progress = data.Progress or data.progress or 0
    -- Notify on phase transitions (not every namespace open)
    if M.warmup_phase and M.warmup_phase ~= "" and M.warmup_phase ~= prev_phase and M.warmup_phase ~= "opening_namespaces" then
      local labels = {
        creating_fsi = "Creating FSI session...",
        scanning_sources = "Scanning source files...",
        loading_assemblies = "Loading assemblies...",
        finalizing = "Warmup complete!",
      }
      local label = labels[M.warmup_phase] or ("Warming up: " .. (M.warmup_phase or ""))
      notify(label)
    end
    fire_user_event("warmup_progress", data)
  end

  -- Phase 7C: SessionFaulted — clear session state, notify ERROR, fire autocmd
  handlers.session_faulted = function(raw)
    local data = decode_event_data(raw)
    if not data then return end
    -- 0.6 wire: { sessionFaulted = <sid>, error = <msg> }; older: session_id/reason.
    local sid = data.sessionFaulted or data.session_id or data.SessionId or "?"
    local reason = data.error or data.reason or data.Reason or "unknown"
    -- The session list learns of every fault (that is what keeps a faulted
    -- session from showing "Ready"); only our own session's fault clears this
    -- editor's state and shows a message.
    fold_session_update(data)
    -- Someone else's session faulting is not this editor's state to clear or
    -- its message to show (the event still fires for autocmd consumers). A
    -- fault that says nothing about whose it is stays ours.
    local faulted_id = data.sessionFaulted or data.session_id or data.SessionId
    if faulted_id ~= nil and not session_is_ours(faulted_id) then
      fire_user_event("session_faulted", data)
      return
    end
    -- Clear all session-specific state so stale results don't linger
    M.testing_state = testing.clear_session_state and testing.clear_session_state(M.testing_state) or M.testing_state
    M.coverage_state = coverage.clear and coverage.clear(M.coverage_state) or M.coverage_state
    -- The statusline returns early while a warmup phase is set, so a fault mid-warmup
    -- (a failed build is the common one) would hide "(Faulted)" behind the warmup text.
    reset_warmup_text()
    notify(string.format("Session faulted [%s]: %s", sid, reason), vim.log.levels.ERROR)
    fire_user_event("session_faulted", data)
  end

  -- Phase 7C: WarmupCompleted — notify INFO (configurable), fire autocmd
  handlers.warmup_completed = function(raw)
    local data = decode_event_data(raw)
    if not data then return end
    local sid = data.session_id or data.SessionId or "?"
    if not session_is_ours(sid) then
      fire_user_event("warmup_completed", data)
      return
    end
    clear_warmup_state()
    local n = data.project_count or data.ProjectCount or 0
    local label = n == 1 and "1 project" or (tostring(n) .. " projects")
    if M.config.notify_warmup_completed ~= false then
      notify(string.format("Session ready [%s] — %s loaded", sid, label))
    end
    fire_user_event("warmup_completed", data)
  end

  -- Phase 7C: FileReloaded — silent state update (no notify), fire autocmd
  handlers.file_reloaded = function(raw)
    local data = decode_event_data(raw)
    if not data then return end
    -- 0.6 wire: { fileReloaded = <path>, sessionId = <sid> }; older: file/elapsed_ms.
    M.last_reload_file = data.fileReloaded or data.file or data.File
    M.last_reload_ms = data.elapsed_ms or data.ElapsedMs
    reload_ui.note_file(data.sessionId, M.last_reload_file)
    fire_user_event("file_reloaded", data)
  end

  -- The `state` envelope's ReloadReported: what the last save did to the running
  -- app (applied, patched and ran, restart needed, ...). Read, not dropped.
  handlers.reload_reported = function(raw)
    local data = decode_event_data(raw)
    if not data then return end
    M.wire_runtime().on_reload_reported(data)
    fire_user_event("reload_reported", data)
  end

  -- Phase 7C: SystemAlarm — store for statusline, notify ERROR, fire autocmd
  handlers.system_alarm = function(raw)
    local data = decode_event_data(raw)
    if not data then return end
    M.system_alarm = data
    local phase = data.phase or data.Phase or "?"
    local msg = data.message or data.Message or "alarm"
    notify(string.format("⚠ ALARM [%s]: %s", phase, msg), vim.log.levels.ERROR)
    fire_user_event("system_alarm", data)
  end

  -- Wire-testing features (live bindings): handlers live in sagefs.wire_testing
  for action, fn in pairs(require("sagefs.wire_testing").sse_handlers(M, { decode = decode_event_data, fire = fire_user_event })) do
    handlers[action] = fn
  end

  return sse_parser.build_dispatch_table(handlers)
end

-- Debounce timer for gutter sign rendering (SSE can flood events)
local render_timer = nil
-- Adaptive debounce (Nu graduated sleep pattern):
-- Fast when idle (single event → 8ms), slower under sustained load (burst → 30ms)
local RENDER_DEBOUNCE_MIN_MS = 8
local RENDER_DEBOUNCE_MAX_MS = 30
local _render_request_count = 0
local _render_burst_reset = nil

-- Cached namespace for test failure diagnostics (avoid API call per render)
local test_diag_ns = nil
-- Version tracking for render skip (FDA short-circuit / Nu ViewVersion)
local last_rendered_test_version = -1
local last_rendered_ann_version = -1
local last_rendered_cov_version = -1
local last_rendered_file = ""

local function get_adaptive_debounce()
  _render_request_count = _render_request_count + 1
  -- Reset burst counter after 100ms of quiet
  if _render_burst_reset then pcall(vim.fn.timer_stop, _render_burst_reset) end
  _render_burst_reset = vim.fn.timer_start(100, function()
    _render_request_count = 0
    _render_burst_reset = nil
  end)
  if _render_request_count <= 1 then return RENDER_DEBOUNCE_MIN_MS end
  if _render_request_count <= 3 then return 15 end
  return RENDER_DEBOUNCE_MAX_MS
end

local function schedule_render()
  if render_timer then
    pcall(vim.fn.timer_stop, render_timer)
  end
  local debounce_ms = get_adaptive_debounce()
  render_timer = vim.fn.timer_start(debounce_ms, function()
    render_timer = nil
    vim.schedule(function()
      local buf = vim.api.nvim_get_current_buf()
      local file = vim.api.nvim_buf_get_name(buf) or ""
      -- Short-circuit: skip render if nothing changed (FDA/Nu ViewVersion pattern)
      local test_v = M.testing_state._version or 0
      local ann_v = M.annotations_state._version or 0
      local cov_v = M.coverage_state._version or 0
      if test_v == last_rendered_test_version
        and ann_v == last_rendered_ann_version
        and cov_v == last_rendered_cov_version
        and file == last_rendered_file then
        return
      end
      last_rendered_test_version = test_v
      last_rendered_ann_version = ann_v
      last_rendered_cov_version = cov_v
      last_rendered_file = file
      render.render_test_signs(buf, M.testing_state, M.annotations_state)
      render.render_coverage_signs(buf, M.coverage_state)
      render.render_annotations(buf, M.annotations_state, M.density_state)
      require("sagefs.wire_testing").render(buf, M)
      if file ~= "" then
        if not test_diag_ns then
          test_diag_ns = vim.api.nvim_create_namespace("sagefs_test_diagnostics")
        end
        local diags = testing.to_diagnostics(M.testing_state, file)
        vim.diagnostic.set(test_diag_ns, buf, diags)
      end
    end)
  end)
end

local function on_sse_events(raw_events)
  if not dispatch_table then
    dispatch_table = build_handlers()
  end

  -- Stats: track SSE event throughput
  M.state = model.record_sse_events(M.state, #raw_events)

  local classified = {}
  for _, event in ipairs(raw_events) do
    local c = sse_parser.classify_event(event)
    if c then
      table.insert(classified, { action = c.action, data = c.data })
    end
  end

  local errors = sse_parser.safe_dispatch_batch(dispatch_table, classified)
  for _, e in ipairs(errors) do
    vim.schedule(function()
      vim.notify(string.format("[SageFs] SSE handler error (%s): %s. Connection may be lost. Try: :SageFsConnect to re-establish", e.action, tostring(e.err)),
        vim.log.levels.WARN)
    end)
  end

  -- Forward events to the dashboard panel (if initialized)
  if M._dashboard then
    for _, c in ipairs(classified) do
      M._dashboard.on_event(c.action, c.data)
    end
  end

  -- Debounced gutter refresh — avoids flooding Neovim with extmark resets
  schedule_render()
end

-- ─── SSE Lifecycle ────────────────────────────────────────────────────────────

local function start_sse()
  if events_sse then events_sse.stop() end
  events_sse = transport.connect_sse(base_url() .. "/events", {
    on_events = function(events)
      on_sse_events(events)
    end,
    on_connect = function()
      M.state = model.set_status(M.state, "connected")
      -- A status change announced while disconnected (or before this stream
      -- existed) is never replayed as an event; re-read the snapshot so a
      -- session cannot stay "(Starting)" because we missed its Ready.
      if M.active_session or #M.session_list > 0 then
        M.list_sessions()
      end
      -- Cancel eval watchdog on reconnect
      if eval_watchdog_timer then
        pcall(vim.fn.timer_stop, eval_watchdog_timer)
        eval_watchdog_timer = nil
      end
      -- Two-phase reconnect (R10): increment generation counter.
      -- Clear testing/coverage/annotations since daemon replays them via SSE.
      -- Preserve warmup_context and hotreload_files (not session-scoped,
      -- expensive to re-acquire, and stale data is better than no data).
      -- Stats: only count reconnects, not the initial connect (R11)
      if not model.is_first_connect(M.state) then
        M.state = model.record_reconnect(M.state)
      end
      local gen = (M.state.reconnect_gen or 0) + 1
      M.state = model.set_reconnect_gen(M.state, gen)
      M.testing_state = testing.new()
      M.coverage_state = coverage.new()
      M.annotations_state = annotations.new()
      M.wire_runtime().on_reconnect()
      fire_user_event("connected")
      -- Forward connection to dashboard
      if M._dashboard then M._dashboard.on_event("connected") end
      vim.schedule(function()
        fire_user_event("test_recovery_needed")
      end)
    end,
    on_disconnect = function(code)
      -- §5.1: this used to set status and fire an autocmd with NO
      -- notification at all — a user with an active session got no signal
      -- whatsoever that the daemon died (the statusline fix above covers
      -- the passive case; this covers the active one).
      local was_connected = M.state.status == "connected"
      M.state = model.set_status(M.state, "disconnected")
      if was_connected then
        notify("Disconnected from SageFs daemon" .. (code and (" (code " .. tostring(code) .. ")") or ""), vim.log.levels.WARN)
      end
      fire_user_event("disconnected")
      -- Forward disconnection to dashboard
      if M._dashboard then M._dashboard.on_event("disconnected") end
      -- Eval watchdog: if an eval is in flight, notify after 5s
      if eval_id > 0 then
        local watchdog_eval_id = eval_id
        if eval_watchdog_timer then
          pcall(vim.fn.timer_stop, eval_watchdog_timer)
        end
        eval_watchdog_timer = vim.fn.timer_start(5000, function()
          eval_watchdog_timer = nil
          if eval_id == watchdog_eval_id then
            eval_id = 0
            vim.schedule(function()
              notify("⚠ Evaluation interrupted: daemon connection lost. Try :SageFsConnect", vim.log.levels.WARN)
            end)
          end
        end)
      end
    end,
    on_reconnecting = function(attempt, status)
      M.state = model.set_status(M.state, status)
      if status == "reconnecting" then
        fire_user_event("reconnecting")
      end
    end,
    on_spawn_error = function(msg)
      M.state = model.set_status(M.state, "disconnected")
      local missing = tostring(msg):find("not on PATH", 1, true)
      notify(missing and require("sagefs.spawn").missing_curl_message() or tostring(msg), vim.log.levels.ERROR)
    end,
    auto_reconnect = true,
  })
  events_sse.start()
end

local function stop_sse()
  if events_sse then events_sse.stop(); events_sse = nil end
  if diag_ns then vim.diagnostic.reset(diag_ns) end
  M.state = model.set_status(M.state, "disconnected")
  fire_user_event("disconnected")
end

-- Exposed directly on M (in addition to the `helpers` closure below that
-- commands/keymaps use) so tests can drive the real SSE dispatch pipeline
-- end-to-end without reaching into private locals.
M.start_sse = start_sse
M.stop_sse = stop_sse

-- ─── Diagnostics ─────────────────────────────────────────────────────────────

function M.apply_diagnostics(diags)
  diag_ns = diag_ns or vim.api.nvim_create_namespace("sagefs_diagnostics")
  local grouped = diagnostics.group_by_file(diags)
  for file, file_diags in pairs(grouped) do
    local vim_diags = diagnostics.to_vim_diagnostics(file_diags)
    local bufnr = vim.fn.bufnr(file)
    if bufnr ~= -1 then
      vim.diagnostic.set(diag_ns, bufnr, vim_diags)
    end
  end
end

-- ─── HTTP: eval + session API ─────────────────────────────────────────────────

--- Show shadow warning virtual text at cell end, auto-clears after 5s.
---@param buf number buffer handle
---@param cell_id string
---@param shadows table[] list of {name, old_type, new_type}
local function show_shadow_warnings(buf, cell_id, shadows)
  vim.schedule(function()
    local cell = M.state.cells[cell_id]
    local line = cell and cell.end_line or 0
    if line <= 0 then return end
    for _, s in ipairs(shadows) do
      local msg = s.old_type == s.new_type
        and string.format("⚠ shadowed: %s (was already defined)", s.name)
        or string.format("⚠ shadowed: %s (was %s, now %s)", s.name, s.old_type, s.new_type)
      vim.api.nvim_buf_set_extmark(buf, ns.shadow_warnings, line - 1, 0, {
        virt_text = {{ msg, "DiagnosticWarn" }},
        virt_text_pos = "eol",
      })
    end
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, ns.shadow_warnings, 0, -1)
      end
    end, 5000)
  end)
end

-- Evals whose status watcher read the session list while they were out. The
-- daemon called the session "Evaluating" then, and that is what the list now
-- holds; the result arriving is the moment to read it again.
local evals_that_polled = {}

local function handle_result(buf, cell_id, result, end_line, my_eval_id, anchor_line)
  -- Take the daemon's "REPL is BEHIND the app" banner off the output and say it once, with the remedy.
  result = M.wire_runtime().on_eval(result)
  if evals_that_polled[my_eval_id] then
    evals_that_polled[my_eval_id] = nil
    vim.schedule(function() M.list_sessions() end)
  end
  -- Only clear eval_id if we're still the current eval
  if eval_id == my_eval_id then
    eval_id = 0
  end
  -- Cancel any pending watchdog timer
  if eval_watchdog_timer then
    pcall(vim.fn.timer_stop, eval_watchdog_timer)
    eval_watchdog_timer = nil
  end
  local meta = { duration_ms = result.duration_ms, end_line = end_line, buf = buf, anchor_line = anchor_line }
  -- Stats: track eval completion
  if result.duration_ms then
    M.state = model.record_eval(M.state, result.duration_ms)
    -- Timeline: record eval event
    local timeline = require("sagefs.timeline")
    local start_ms = (vim.uv.hrtime() / 1e6) - result.duration_ms
    M.timeline_state = timeline.record(M.timeline_state, {
      cell_id = cell_id,
      start_ms = start_ms,
      duration_ms = result.duration_ms,
      status = result.ok and "success" or "error",
    })
    -- Time-travel: record output history
    local time_travel = require("sagefs.time_travel")
    local output = result.ok and result.output or result.error
    time_travel.record(M.time_travel_state, cell_id, output or "", {
      duration_ms = result.duration_ms,
      timestamp_ms = vim.uv.hrtime() / 1e6,
    })
  end
  if result.ok then
    M.state = model.set_cell_state(M.state, cell_id, "success", result.output, meta)
    vim.schedule(function()
      vim.diagnostic.set(ns.fsi_diagnostics, buf, {})
      cell_highlight.set_eval_hint(buf, "success")
    end)
    local shadows
    M.binding_tracker, shadows = format.update_bindings(M.binding_tracker, result.output)
    if #shadows > 0 then
      show_shadow_warnings(buf, cell_id, shadows)
    end
  else
    M.state = model.set_cell_state(M.state, cell_id, "error", result.error, meta)
    vim.schedule(function()
      cell_highlight.set_eval_hint(buf, "error")
    end)
  end
  vim.schedule(function()
    -- reveal: this result was just produced, so make room for it on screen
    render.render_all(buf, M.state, { reveal = cell_id })
  end)
end

-- ─── Why is nothing happening? ───────────────────────────────────────────────
-- After config.EVAL_SLOW_AFTER_MS with no result, ask the daemon for the real
-- state of the session the eval went to and show it on the running cell (and
-- once on the message line), then keep it fresh every EVAL_STATUS_POLL_MS.

local function watch_pending(buf, cell_id, my_eval_id, session_id, start_ns)
  local limits = require("sagefs.config")
  local pending = require("sagefs.pending")
  local last_kind = nil

  local function still_pending()
    return eval_id == my_eval_id and model.is_cell_running(M.state, cell_id)
  end

  local function tick()
    if not still_pending() then return end
    evals_that_polled[my_eval_id] = true
    M.list_sessions(function(result)
      if not still_pending() then return end
      local session = nil
      if result.ok then
        for _, s in ipairs(result.sessions) do
          if s.id == session_id then session = s end
        end
        if not session_id then session = M.active_session end
      else
        session = M.active_session
      end
      local warmup = nil
      if M.warmup_phase and M.warmup_phase ~= "" then
        warmup = { phase = M.warmup_phase, step = M.warmup_step, total = M.warmup_total }
      end
      local c = pending.classify({
        elapsed_ms = math.floor((vim.uv.hrtime() - start_ns) / 1e6),
        connection = M.state.status,
        daemon_reachable = result.ok,
        port = M.config.port,
        session = session,
        warmup = warmup,
      })
      local cell = M.state.cells[cell_id]
      if cell then cell.pending_text = c.short end
      if c.kind ~= last_kind then
        last_kind = c.kind
        -- "Still running" is shown inline on the cell; only a problem earns a
        -- message-line line (and a message that wraps raises a hit-enter prompt).
        if c.level ~= "info" then
          local levels = { warn = vim.log.levels.WARN, error = vim.log.levels.ERROR }
          notify(c.long, levels[c.level])
        end
      end
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then render.render_all(buf, M.state) end
      end)
      vim.defer_fn(tick, limits.EVAL_STATUS_POLL_MS)
    end)
  end

  vim.defer_fn(tick, limits.EVAL_SLOW_AFTER_MS)
end

--- The directory to put in an /exec or /api/completions body: the active (routed) session's own, and
--- Neovim's cwd only when the session list carried none.
local function eval_working_directory()
  local dir = M.active_session and M.active_session.working_directory
  if type(dir) == "string" and dir ~= "" then return dir end
  return vim.fn.getcwd()
end

local function post_exec(code, buf, cell_id, end_line, file_path, eval_mode, block_start_line, anchor_line)
  -- Bug #3 fix: reject eval if cell already running (concurrent eval guard)
  if model.is_cell_running(M.state, cell_id) then
    notify("Cell already evaluating", vim.log.levels.WARN)
    return
  end
  eval_id = eval_id + 1
  local my_eval_id = eval_id
  local start_time = vim.uv.hrtime()
  M.state = model.set_cell_state(M.state, cell_id, "running", nil, { end_line = end_line, buf = buf, anchor_line = anchor_line })
  vim.schedule(function()
    render.render_all(buf, M.state)
    cell_highlight.set_eval_hint(buf, "running")
  end)
  local body = {
    code = code,
    -- The routed session's own directory: evals route by the FILE's path, and the
    -- daemon refuses (404 SessionNotRoutable) a cwd that is not that directory or inside it.
    working_directory = eval_working_directory(),
    sessionId = M.active_session and M.active_session.id or nil,
    format = "json",
    file_path = file_path or "",
    eval_mode = eval_mode or "",
    block_start_line = block_start_line or 0,
  }
  watch_pending(buf, cell_id, my_eval_id, body.sessionId, start_time)
  transport.http_json({
    method = "POST",
    url = base_url() .. "/exec",
    body = body,
    timeout = 60,
    callback = function(ok, raw, meta)
      local elapsed_ms = math.floor((vim.uv.hrtime() - start_time) / 1e6)
      if ok then
        local result = format.parse_exec_response(raw)
        result.duration_ms = elapsed_ms
        -- Set FSI diagnostics via vim.diagnostic if structured diagnostics present
        if result.diagnostics and #result.diagnostics > 0 then
          vim.schedule(function()
            local vim_diags = {}
            for _, d in ipairs(result.diagnostics) do
              local severity = vim.diagnostic.severity.ERROR
              if d.severity == "warning" then severity = vim.diagnostic.severity.WARN
              elseif d.severity == "info" then severity = vim.diagnostic.severity.INFO end
              table.insert(vim_diags, {
                lnum = (d.startLine or 1) - 1,
                col = d.startColumn or 0,
                end_lnum = d.endLine and (d.endLine - 1) or nil,
                end_col = d.endColumn,
                message = d.message or "unknown error",
                severity = severity,
                source = "sagefs-fsi",
              })
            end
            vim.diagnostic.set(ns.fsi_diagnostics, buf, vim_diags)
          end)
        end
        handle_result(buf, cell_id, result, end_line, my_eval_id, anchor_line)
      else
        handle_result(buf, cell_id, { ok = false, error = format.http_failure_text(raw, meta), duration_ms = elapsed_ms }, end_line, my_eval_id, anchor_line)
      end
    end,
  })
end

local function session_http(method, path, body, callback, opts)
  transport.http_json({
    method = method,
    url = base_url() .. path,
    body = body,
    timeout = (opts and opts.timeout) or 5,
    callback = callback,
  })
end

-- ─── Eval Functions ───────────────────────────────────────────────────────────

--- Shared cell preparation: find cell at cursor, prepare code, resolve cell_id.
--- Returns nil (with user notification) if no valid cell found.
local function prepare_cell_eval()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local cell = cells.find_cell_auto(buf, lines, cursor_line)
  if not cell then
    notify("No cell found at cursor", vim.log.levels.WARN)
    return nil
  end

  local code = cells.prepare_code(cell.text)
  if not code then
    notify("Cell is empty", vim.log.levels.WARN)
    return nil
  end

  local all = cells.find_all_cells_auto(buf, lines)
  local cell_id = 1
  for _, c in ipairs(all) do
    if c.start_line == cell.start_line then
      cell_id = c.id
      break
    end
  end

  return {
    buf = buf,
    lines = lines,
    cursor_line = cursor_line,
    cell = cell,
    code = code,
    cell_id = cell_id,
  }
end

function M.eval_cell()
  local ctx = prepare_cell_eval()
  if not ctx then return end
  local fp = vim.api.nvim_buf_get_name(ctx.buf)
  render.flash_cell(ctx.buf, ctx.cell.start_line, ctx.cell.end_line)
  post_exec(ctx.code, ctx.buf, ctx.cell_id, ctx.cell.end_line, fp, "block", ctx.cell.start_line, ctx.cursor_line)
end

function M.eval_cell_and_advance()
  local ctx = prepare_cell_eval()
  if not ctx then return end
  local fp = vim.api.nvim_buf_get_name(ctx.buf)
  render.flash_cell(ctx.buf, ctx.cell.start_line, ctx.cell.end_line)
  post_exec(ctx.code, ctx.buf, ctx.cell_id, ctx.cell.end_line, fp, "block", ctx.cell.start_line, ctx.cursor_line)

  local next_start = cells.find_next_cell_start(ctx.lines, ctx.cursor_line)
  if next_start then
    vim.api.nvim_win_set_cursor(0, { next_start, 0 })
  end
end

--- Open the full result of the cell under the cursor in a float. This is what
--- the "N more lines, <leader>rE to expand" footer points at.
function M.show_result()
  local buf = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local all = cells.find_all_cells_auto(buf, lines)
  local found
  for _, c in ipairs(all) do
    if cursor_line >= c.start_line and cursor_line <= c.end_line then found = c; break end
  end
  local cs = found and M.state.cells[found.id] or nil
  local has_result = cs and (cs.buf == nil or cs.buf == buf)
    and (cs.status == "success" or cs.status == "error" or cs.status == "stale")
  if not has_result then
    notify("No result for the cell under the cursor. Evaluate it first with <A-CR>.", vim.log.levels.WARN)
    return
  end
  return render.show_result_float(cs)
end

function M.eval_selection()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)

  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local buf = vim.api.nvim_get_current_buf()

  local sel_lines = vim.api.nvim_buf_get_lines(buf, start_pos[2] - 1, end_pos[2], false)
  local text = table.concat(sel_lines, "\n")
  local code = cells.prepare_code(text)

  if not code then
    notify("Selection is empty", vim.log.levels.WARN)
    return
  end

  local fp = vim.api.nvim_buf_get_name(buf)
  render.flash_cell(buf, start_pos[2], end_pos[2])
  post_exec(code, buf, 0, nil, fp, "block", start_pos[2])
end

function M.eval_current_line()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_nr = cursor[1]
  local lines = vim.api.nvim_buf_get_lines(buf, line_nr - 1, line_nr, false)
  local text = lines[1]

  if not text or text:match("^%s*$") then
    notify("Current line is empty", vim.log.levels.WARN)
    return
  end

  local code = cells.prepare_code(text)
  if not code then
    notify("Current line is empty", vim.log.levels.WARN)
    return
  end

  local fp = vim.api.nvim_buf_get_name(buf)
  render.flash_cell(buf, line_nr, line_nr)
  post_exec(code, buf, 0, nil, fp, "block", line_nr)
end

function M.eval_file()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  local code = cells.prepare_code(text)

  if not code then
    notify("File is empty", vim.log.levels.WARN)
    return
  end

  local fp = vim.api.nvim_buf_get_name(buf)
  notify("Evaluating file: " .. vim.fn.expand("%:t"))
  render.flash_cell(buf, 1, #lines)
  post_exec(code, buf, 0, nil, fp, "file", nil)
end

-- ─── Code Completion ─────────────────────────────────────────────────────────

function M.omnifunc(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.fn.col(".") - 1
    while col > 0 and line:sub(col, col):match("[%w_]") do
      col = col - 1
    end
    M._completion_col = col
    return col
  end

  -- Async: fire HTTP request, call vim.fn.complete() when results arrive
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  local cursor = vim.api.nvim_win_get_cursor(0)
  local offset = 0
  for i = 1, cursor[1] - 1 do
    offset = offset + #lines[i] + 1
  end
  offset = offset + cursor[2]

  local working_directory = eval_working_directory()
  local body = completions.build_request_body(text, offset, working_directory)
  local col = (M._completion_col or 0) + 1

  transport.http_json({
    method = "POST",
    -- /dashboard/completions streams an SSE DOM patch. Omnifunc consumes the
    -- JSON editor contract served by the MCP HTTP API instead.
    url = base_url() .. "/api/completions",
    body = body,
    timeout = 5,
    callback = function(ok, raw)
      if not ok or not raw then return end
      vim.schedule(function()
        local items = completions.parse_response(raw)
        if #items > 0 then
          vim.fn.complete(col, items)
        end
      end)
    end,
  })

  -- Return empty — results arrive asynchronously via vim.fn.complete()
  return {}
end

-- ─── Session API ──────────────────────────────────────────────────────────────

local warmup_poll_timer = nil

--- While our session is still warming, look at the session list again until it
--- is not (see config.SESSION_WARMUP_POLL_MS).
local function poll_while_warming()
  if warmup_poll_timer then return end
  local s = M.active_session
  if not (s and sessions.WARMING_STATUSES[s.status]) then return end
  warmup_poll_timer = vim.fn.timer_start(require("sagefs.config").SESSION_WARMUP_POLL_MS, function()
    warmup_poll_timer = nil
    vim.schedule(function() M.list_sessions() end)
  end)
end

function M.list_sessions(callback)
  local requested_at = M.session_event_seq
  session_http("GET", "/api/sessions", nil, function(ok, raw)
    local result = sessions.parse_sessions_response(ok and raw or nil)
    if result.ok then
      -- Events folded in since the request went out are newer than this answer.
      local newer = {}
      for sid, stamp in pairs(M.session_event_stamp) do
        if stamp > requested_at then newer[sid] = true end
      end
      result.sessions = sessions.keep_newer(result.sessions, M.session_list, newer)
      M.session_list = result.sessions
      local active_id = M.active_session and M.active_session.id or nil
      M.active_session = sessions.select_active_session(result.sessions, active_id, vim.fn.getcwd())
      poll_while_warming()
      M.wire_runtime().on_sessions(result.sessions)
    end
    if callback then callback(result) end
  end)
end

function M.post_buffer_changed(buf, callback)
  local file_path = vim.api.nvim_buf_get_name(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local content = table.concat(lines, "\n")
  local request = sessions.build_buffer_change_request(M.session_list, M.active_session, file_path, content)

  if not request then
    if callback then callback(false, nil) end
    return
  end

  session_http("POST", request.path, request.body, function(ok, raw)
    if callback then callback(ok, raw) end
  end)
end

local function is_target_path(path)
  if type(path) ~= "string" or path == "" then return false end
  return path:lower():match("%.fsproj$") ~= nil
    or path:lower():match("%.sln$") ~= nil
    or path:lower():match("%.slnx$") ~= nil
end

local function create_targets(paths, working_dir, callback)
  working_dir = working_dir or vim.fn.getcwd()
  -- The daemon answers only once the session is up, so its warmup events
  -- arrive BEFORE the reply: expect them from the moment the request is out.
  M.warmup_expected_until = (vim.uv.hrtime() / 1e6) + 180000
  session_http("POST", "/api/sessions/create", {
    projects = paths,
    workingDirectory = working_dir,
  }, function(ok, raw)
    local result = sessions.parse_action_response(ok and raw or nil)
    if result.ok then
      -- the new session's warmup events are the ones to show, for a while
      M.warmup_expected_until = (vim.uv.hrtime() / 1e6) + 180000
      notify(result.message or "Session created")
      M.list_sessions()
    else
      notify(result.error or "Failed to create session", vim.log.levels.ERROR)
    end
    if callback then callback(result) end
  end, { timeout = 300 })
end

function M.create_session(paths, working_dir, callback)
  if type(paths) ~= "table" or #paths == 0 then
    local result = { ok = false, error = "create_session requires at least one explicit .fsproj, .sln, or .slnx path" }
    notify(result.error, vim.log.levels.ERROR)
    if callback then callback(result) end
    return
  end
  for _, path in ipairs(paths) do
    if not is_target_path(path) then
      local result = { ok = false, error = "create_session accepts only .fsproj, .sln, or .slnx paths: " .. tostring(path) }
      notify(result.error, vim.log.levels.ERROR)
      if callback then callback(result) end
      return
    end
  end
  create_targets(paths, working_dir, callback)
end

function M.create_bare_session(working_dir, callback)
  create_targets({}, working_dir, callback)
end

function M.switch_session(session_id, callback)
  session_http("POST", "/api/sessions/switch", {
    sessionId = session_id,
  }, function(ok, raw)
    local result = sessions.parse_action_response(ok and raw or nil)
    if result.ok then
      notify("Switched to session " .. (result.session_id or session_id))
      -- list_sessions keeps the CURRENT active id, so without this the plugin
      -- kept evaluating in the session the user just switched away from.
      M.active_session = { id = result.session_id or session_id }
      M.list_sessions()
    else
      notify(result.error or "Failed to switch", vim.log.levels.ERROR)
    end
    if callback then callback(result) end
  end)
end

function M.stop_session(session_id, callback)
  session_http("POST", "/api/sessions/stop", {
    sessionId = session_id,
  }, function(ok, raw)
    local result = sessions.parse_action_response(ok and raw or nil)
    if result.ok then
      notify(result.message or "Session stopped")
      if M.active_session and M.active_session.id == session_id then
        M.active_session = nil
      end
      M.list_sessions()
    else
      notify(result.error or "Failed to stop session", vim.log.levels.ERROR)
    end
    if callback then callback(result) end
  end, { timeout = 30 })
end

function M.reset_session(callback)
  session_http("POST", "/reset", {}, function(ok, raw)
    if ok then
      notify("Session reset")
    else
      local decode_ok, parsed = util.json_decode(raw)
      notify("Failed to reset session: " .. util.format_server_error(decode_ok and parsed or nil, raw), vim.log.levels.ERROR)
    end
    if callback then callback(ok) end
  end)
end

function M.hard_reset(callback)
  session_http("POST", "/hard-reset", { rebuild = true }, function(ok, raw)
    if ok then
      notify("Hard reset complete (rebuild)")
      M.wire_runtime().on_hard_reset()
    else
      local decode_ok, parsed = util.json_decode(raw)
      notify("Failed to hard reset: " .. util.format_server_error(decode_ok and parsed or nil, raw), vim.log.levels.ERROR)
    end
    if callback then callback(ok) end
  end, { timeout = 60 })
end

-- ─── Session Context ─────────────────────────────────────────────────────────

function M.show_session_context()
  local sid = M.active_session and M.active_session.id or nil
  if not sid then
    notify("No active session", vim.log.levels.WARN)
    return
  end
  transport.http_json({
    method = "GET",
    url = string.format("http://localhost:%d/api/sessions/%s/warmup-context",
      M.config.dashboard_port, sid),
    timeout = 5,
    callback = function(ok, raw)
      if not ok or raw == "" then
        local decode_ok, parsed = util.json_decode(raw)
        notify("Failed to fetch session context: " .. util.format_server_error(decode_ok and parsed or nil, raw), vim.log.levels.ERROR)
        return
      end
      local parse_ok, ctx = pcall(vim.json.decode, raw)
      if not parse_ok or type(ctx) ~= "table" then
        notify("Invalid session context response", vim.log.levels.ERROR)
        return
      end
      local lines = { "SageFs Session Context", string.rep("─", 40) }
      table.insert(lines, string.format("Session: %s", sid))
      local pt = ctx.phaseTiming
      if pt and pt.totalMs then
        table.insert(lines, string.format("Warmup: %dms (scan=%dms, asm=%dms, open=%dms)",
          pt.totalMs, pt.scanSourceFilesMs or 0, pt.scanAssembliesMs or 0, pt.openNamespacesMs or 0))
      end
      if ctx.assembliesLoaded then
        table.insert(lines, "")
        table.insert(lines, string.format("Assemblies (%d):", #ctx.assembliesLoaded))
        for _, a in ipairs(ctx.assembliesLoaded) do
          table.insert(lines, string.format("  %s (%d ns, %d mod)",
            a.name or "?", a.namespaceCount or 0, a.moduleCount or 0))
        end
      end
      if ctx.namespacesOpened then
        table.insert(lines, "")
        table.insert(lines, string.format("Namespaces Opened (%d):", #ctx.namespacesOpened))
        for _, n in ipairs(ctx.namespacesOpened) do
          local kind = n.isModule and "module" or "namespace"
          local dur = n.durationMs and string.format(", %.1fms", n.durationMs) or ""
          table.insert(lines, string.format("  %s (%s, %s%s)",
            n.name or "?", kind, n.source or "?", dur))
        end
      end
      if ctx.failedOpens and #ctx.failedOpens > 0 then
        table.insert(lines, "")
        table.insert(lines, string.format("Failed Opens (%d):", #ctx.failedOpens))
        for _, f in ipairs(ctx.failedOpens) do
          if type(f) == "table" and f.name then
            local kind = f.isModule and "module" or "namespace"
            table.insert(lines, string.format("  ✖ %s (%s) — %s", f.name, kind, f.errorMessage or "?"))
            if f.diagnostics then
              for _, d in ipairs(f.diagnostics) do
                local loc = d.fileName or "unknown"
                table.insert(lines, string.format("    FS%04d %s:%d:%d — %s",
                  d.errorNumber or 0, loc, d.startLine or 0, d.startColumn or 0, d.message or ""))
              end
            end
          else
            table.insert(lines, "  " .. tostring(f))
          end
        end
      end
      render.show_float(lines, { title = "Session Context" })
    end,
  })
end

-- ─── Session Picker ──────────────────────────────────────────────────────────

function M.session_picker()
  M.list_sessions(function(result)
    if not result.ok then
      notify("Failed to list sessions: " .. (result.error or ""), vim.log.levels.ERROR)
      return
    end

    local items = {}
    local lookup = {}
    for _, s in ipairs(result.sessions) do
      local line = sessions.picker_label(s)
      table.insert(items, line)
      lookup[line] = s
    end

    local create_label = "+ Create new session..."
    table.insert(items, create_label)

    vim.ui.select(items, { prompt = "SageFs Sessions:" }, function(choice)
      if not choice then return end
      if choice == create_label then
        M.discover_and_create()
        return
      end

      local session = lookup[choice]
      if not session then return end

      local actions = sessions.session_actions(session)
      local action_labels = {}
      for _, a in ipairs(actions) do
        table.insert(action_labels, a.label)
      end

      vim.ui.select(action_labels, {
        prompt = session.id .. ":",
      }, function(action_choice)
        if not action_choice then return end
        for _, a in ipairs(actions) do
          if a.label == action_choice then
            if a.name == "switch" then M.switch_session(session.id)
            elseif a.name == "stop" then M.stop_session(session.id)
            elseif a.name == "reset" then M.reset_session()
            elseif a.name == "hard_reset" then M.hard_reset()
            elseif a.name == "create" then M.discover_and_create()
            end
            return
          end
        end
      end)
    end)
  end)
end

function M.discover_and_create(working_dir, prompt, quiet_if_none)
  working_dir = working_dir or vim.fn.getcwd()
  local fsproj_files = vim.fn.glob(working_dir .. "/**/*.fsproj", false, true)

  -- Bug #4 fix: make paths relative and filter excluded dirs
  local items = {}
  for _, path in ipairs(fsproj_files) do
    table.insert(items, path:sub(#working_dir + 2))
  end
  items = format.filter_excluded_paths(items)

  if #items == 0 then
    if not quiet_if_none then
      notify("No .fsproj files found in " .. working_dir, vim.log.levels.WARN)
    end
    return
  end

  vim.ui.select(items, { prompt = prompt or "Select project to load:" }, function(choice)
    if not choice then return end
    M.create_session({ choice }, working_dir)
  end)
end

function M.configure_warmup_auto_open(working_dir)
  working_dir = working_dir or vim.fn.getcwd()
  local result = project_config.ensure_auto_open_opt_out(working_dir)
  if result.status == "failed" then
    notify("Could not create .SageFs/config.fsx: " .. tostring(result.error), vim.log.levels.ERROR)
    return
  end
  vim.cmd.edit(vim.fn.fnameescape(result.path))

  if result.status == "created" then
    notify("Created .SageFs/config.fsx with AutoOpenNamespaces = false")
  elseif result.status == "already_disabled" then
    notify("Warmup auto-open is already disabled for this directory")
  else
    notify("Existing config opened. Set AutoOpenNamespaces = false; it was not overwritten", vim.log.levels.WARN)
  end
end

-- ─── Check on Save ────────────────────────────────────────────────────────────

local function check_code(code)
  transport.http_json({
    method = "POST",
    url = base_url() .. "/diagnostics",
    body = { code = code },
    timeout = 10,
    callback = function() end, -- fire-and-forget; diagnostics arrive via SSE
  })
end

-- ─── Smart Eval ───────────────────────────────────────────────────────────────
-- Evals route by working directory (sessions.route). A session belongs to a
-- directory and a git worktree is its own boundary, so the plugin never
-- silently evaluates in another directory's session: when nothing here can
-- take the eval it says which sessions exist and asks.

--- Explicit "use this session for this directory" choices, keyed by the
--- normalized directory. Set only by the user picking a session in the prompt.
M.session_overrides = {}

--- Nearest ancestor of `file` holding a `.git` (a directory in a plain
--- checkout, a FILE in a git worktree): the checkout the file belongs to.
local function checkout_root_of_dir(dir)
  local found = vim.fs.find(".git", { upward = true, path = dir })[1]
  return found and vim.fs.dirname(found) or nil
end

local function is_fsharp_path(path)
  local lower = path:lower()
  return lower:match("%.fsx?$") ~= nil or lower:match("%.fsi$") ~= nil
end

--- Where `buf` lives, as sessions.route wants it.
---@param buf number|nil
---@return sagefs.RouteTarget
function M.eval_target(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  -- Only an F# buffer says where we are; anything else (a help page, a
  -- scratch buffer, the startup screen) routes by the working directory.
  local file = (name ~= "" and is_fsharp_path(name)) and vim.fn.fnamemodify(name, ":p") or nil
  local cwd = vim.fn.getcwd()
  local root = checkout_root_of_dir(file and vim.fs.dirname(file) or cwd)
  return {
    file = file,
    cwd = cwd,
    root = root,
    active_id = M.active_session and M.active_session.id or nil,
    override_id = M.session_overrides[sessions.normalize_path(root or cwd)],
  }
end

--- Offer to create a session for the directory (explicit project choice, the
--- plugin never infers one), listing the sessions that exist. `eval_fn`, when
--- given, runs if the user picks an existing session explicitly.
function M.offer_session_for(target, others, eval_fn)
  local dir = target.root or target.cwd
  notify(sessions.no_session_message(dir, others), vim.log.levels.WARN)

  local items = { "Create a session for " .. dir }
  local picks = { { create = true } }
  local shown = 0
  for _, s in ipairs(others) do
    if s.status ~= "Stopped" and shown < 5 then
      shown = shown + 1
      items[#items + 1] = "Evaluate in " .. sessions.compact_label(s, 64)
      picks[#picks + 1] = { session = s }
    end
  end
  items[#items + 1] = "Cancel"

  vim.ui.select(items, { prompt = "SageFs: no session for " .. dir .. ". Nothing was sent. Choose:" }, function(choice, idx)
    if not choice then return end
    local pick = picks[idx]
    if not pick then return end -- Cancel
    if pick.create then
      M.discover_and_create(dir)
    elseif pick.session then
      M.session_overrides[sessions.normalize_path(dir)] = pick.session.id
      M.active_session = pick.session
      if eval_fn then eval_fn() end
    end
  end)
end

local function smart_eval_with_session_check(eval_fn)
  return function()
    local target = M.eval_target()

    -- Fast path: the session we already hold is the one this directory routes
    -- to, so there is nothing to ask the daemon.
    if M.active_session then
      local r = sessions.route(M.session_list, target)
      if r.kind == "match" and r.session.id == M.active_session.id then
        eval_fn()
        return
      end
    end

    M.list_sessions(function(result)
      -- §5.6: `result.ok == false` (the transport/daemon itself is
      -- unreachable) and "the daemon answered with no session for here" used
      -- to collapse into the identical "No active session for this
      -- directory" message — the plugin HAD the transport failure in hand and
      -- rendered the opposite of the truth. Say what's actually wrong and
      -- name the one command that fixes it.
      if not result.ok then
        notify("SageFs not available on port " .. M.config.port .. ". Run :SageFsStart or start SageFs externally.", vim.log.levels.ERROR)
        return
      end

      target.active_id = M.active_session and M.active_session.id or nil
      local r = sessions.route(result.sessions, target)

      if r.kind == "match" then
        M.active_session = r.session
        eval_fn()
        return
      end

      if r.kind == "ambiguous" then
        local items, byname = {}, {}
        for _, s in ipairs(r.candidates) do
          local label = sessions.compact_label(s, 72)
          items[#items + 1] = label
          byname[label] = s
        end
        vim.ui.select(items, { prompt = "SageFs: several sessions serve " .. r.dir .. ". Evaluate in:" }, function(choice)
          local s = choice and byname[choice]
          if not s then return end
          M.session_overrides[sessions.normalize_path(r.dir)] = s.id
          M.active_session = s
          eval_fn()
        end)
        return
      end

      M.offer_session_for(target, result.sessions, eval_fn)
    end)
  end
end

--- One line for :SageFsStatus: which session an eval from the current buffer
--- would go to, and why not when there is none.
function M.describe_eval_route()
  local target = M.eval_target()
  local r = sessions.route(M.session_list, target)
  if r.kind == "match" then
    return string.format("%s [%s] (%s)", r.session.name or r.session.id, (r.session.id or ""):sub(1, 8), r.session.status or "?")
  elseif r.kind == "ambiguous" then
    return string.format("ambiguous: %d sessions serve %s", #r.candidates, r.dir)
  end
  return string.format("nothing (no session for %s)", r.dir)
end

--- At startup, on a shared daemon: if no session belongs to this directory,
--- offer to create one for it. The daemon having OTHER sessions is not a
--- reason to stay quiet (it used to need zero).
---@param result { ok: boolean, sessions: table[] }
function M.offer_session_for_startup(result)
  if not result or not result.ok then return end
  local target = M.eval_target()
  target.active_id = nil
  local r = sessions.route(result.sessions, target)
  if r.kind ~= "none" then return end
  local dir = target.root or target.cwd
  local prompt
  if #result.sessions > 0 then
    prompt = string.format("SageFs: no session for %s (%d other session%s exist). Create one with project:",
      dir, #result.sessions, #result.sessions == 1 and "" or "s")
  else
    prompt = string.format("SageFs: no session for %s. Create one with project:", dir)
  end
  M.discover_and_create(dir, prompt, true)
end

-- Exposed for tests — see the start_sse/stop_sse note above.
M.smart_eval_with_session_check = smart_eval_with_session_check

-- ─── Health Check & Statusline ────────────────────────────────────────────────

local function update_health_metadata(parsed)
  if type(parsed) ~= "table" then return end

  if parsed.apiVersion ~= nil then
    M.state.api_version = parsed.apiVersion
    M.state.features = parsed.features or {}
    -- Warn at startup ONLY for a real wire incompatibility (apiVersion
    -- outside the range the plugin declares), once per api version seen.
    -- A difference in release numbers is never a warning.
    local warning = compat.startup_warning(parsed.apiVersion)
    if warning and not compat_warned[parsed.apiVersion] then
      compat_warned[parsed.apiVersion] = true
      -- Deferred a tick so this never races ahead of the connect
      -- notification that's about to fire in the same call chain.
      vim.schedule(function() notify(warning, vim.log.levels.WARN) end)
    end
  end

  -- §5.12: the daemon's own semver, straight from the probe that just
  -- succeeded, kept for :checkhealth's version info line.
  if parsed.version ~= nil and parsed.version ~= "" then
    M.state.daemon_version = parsed.version
  end

  if parsed.error and type(parsed.error) == "table" then
    local err = parsed.error
    local msg = err.message or "Unknown error"
    local action = err.suggestedAction or ""
    local detail = action ~= "" and (msg .. " → " .. action) or msg
    notify(detail, vim.log.levels.WARN)
    M.state.last_error = err
  else
    M.state.last_error = nil
  end

  -- Store per-session health from /health (daemon-wide snapshot)
  if parsed.sessionStates and type(parsed.sessionStates) == "table" then
    M.state.health_session_states = parsed.sessionStates
  end
  if parsed.diagnosticSummary and type(parsed.diagnosticSummary) == "string" then
    M.state.health_diagnostic_summary = parsed.diagnosticSummary
  end
  if parsed.sessionCount and type(parsed.sessionCount) == "number" then
    M.state.health_session_count = parsed.sessionCount
  end
end

function M.health_check(callback)
  discovery.probe_contract(function(path, done)
    transport.http_json({
      method = "GET",
      url = base_url() .. path,
      timeout = 2,
      callback = function(ok, raw)
        if not ok then
          done(false, { raw = raw })
          return
        end

        done(true, { raw = raw })
      end,
    })
  end, function(ok, probe)
    vim.schedule(function()
      if ok and probe and probe.parsed then
        update_health_metadata(probe.parsed)
      end

      if ok and probe and probe.kind == "reachable" then
        notify("SageFs reachable (no session for this directory)")
        if callback then callback(true) end
      elseif ok then
        notify("Connected to SageFs on port " .. M.config.port)
        if callback then callback(true) end
      else
        notify("SageFs not available on port " .. M.config.port .. ". Run :SageFsStart or start SageFs externally.", vim.log.levels.ERROR)
        if callback then callback(false) end
      end
    end)
  end)
end

-- ─── Live Testing / Workflow Commands ────────────────────────────────────────

function M.enable_live_testing()
  transport.http_json({
    method = "POST",
    url = base_url() .. "/api/live-testing/enable",
    timeout = 5,
    callback = function(ok, raw)
      vim.schedule(function()
        if not ok then
          notify("Failed to enable live testing", vim.log.levels.ERROR)
          return
        end
        local parsed = pcall(vim.json.decode, raw) and vim.json.decode(raw) or nil
        if parsed and parsed.success == false then
          notify("SageFs: failed to enable live testing — " .. (parsed.message or parsed.reason or "Unknown"), vim.log.levels.ERROR)
        else
          notify("Live testing enabled")
        end
      end)
    end,
  })
end

function M.disable_live_testing()
  transport.http_json({
    method = "POST",
    url = base_url() .. "/api/live-testing/disable",
    timeout = 5,
    callback = function(ok, raw)
      vim.schedule(function()
        if not ok then
          notify("Failed to disable live testing", vim.log.levels.ERROR)
          return
        end
        local parsed = pcall(vim.json.decode, raw) and vim.json.decode(raw) or nil
        if parsed and parsed.success == false then
          notify("SageFs: failed to disable live testing — " .. (parsed.message or parsed.reason or "Unknown"), vim.log.levels.ERROR)
        else
          notify("Live testing disabled")
        end
      end)
    end,
  })
end

function M.switch_workflow()
  -- The daemon gained `POST /api/sessions/{id}/workflow` recently (see
  -- SageFs/McpServer.fs), so this stub is no longer blocked on a missing
  -- server-side route — wiring it up is a small, separate follow-up. It
  -- still just points at the MCP tool for now.
  notify("Use the SageFs MCP tool 'switch_workflow' or the TUI to change workflows", vim.log.levels.INFO)
end

function M.statusline()
  local parts = {}

  -- Show warmup progress when actively warming up
  if M.warmup_phase and M.warmup_phase ~= "" then
    local labels = {
      creating_fsi = "Creating FSI...",
      scanning_sources = "Scanning sources...",
      loading_assemblies = "Loading assemblies...",
      opening_namespaces = string.format("Opening namespaces (%d/%d)...", M.warmup_step, M.warmup_total),
      finalizing = "Ready!",
    }
    local label = labels[M.warmup_phase] or "Warming up..."
    table.insert(parts, "⏳ SageFs: " .. label)
    return table.concat(parts, " │ ")
  end

  if M.active_session then
    -- §5.1: the connection status must reach the statusline even when a
    -- session is active — this used to be computed only in the `else`
    -- branch below, so a dead daemon kept rendering "⚡ MyProject (Ready)"
    -- forever after M.state.status flipped to "disconnected".
    table.insert(parts, sessions.format_statusline(M.active_session, M.state.status))
  else
    local icon = M.state.status == "connected" and "⚡"
      or M.state.status == "reconnecting" and "🔌"
      or "💤"
    local cell_count = model.cell_count(M.state)
    local running = 0
    for _, c in pairs(M.state.cells or {}) do
      if c.status == "running" then running = running + 1 end
    end
    if running > 0 then
      table.insert(parts, "⏳ SageFs [" .. cell_count .. "]")
    elseif cell_count > 0 then
      table.insert(parts, icon .. " SageFs [" .. cell_count .. "]")
    else
      table.insert(parts, icon .. " SageFs")
    end
  end

  -- Workflow label (e.g. [REPL], [Live])
  if M.workflow_label and M.workflow_label ~= "" then
    table.insert(parts, "[" .. M.workflow_label .. "]")
  end

  local test_sl = testing.format_statusline(M.testing_state)
  if test_sl ~= "" then table.insert(parts, test_sl) end

  local cov_sl = coverage.format_statusline(M.coverage_state)
  if cov_sl ~= "" then table.insert(parts, cov_sl) end

  local timeline_sl = require("sagefs.timeline").format_statusline(M.timeline_stats)
  if timeline_sl ~= "" then table.insert(parts, timeline_sl) end

  local app_sl = require("sagefs.app_run").format_statusline(M.app_run_state)
  if app_sl ~= "" then table.insert(parts, app_sl) end

  -- What the last save did, and whether the REPL is behind the app
  for _, seg in ipairs(M.wire_runtime().statusline_segments()) do
    table.insert(parts, seg)
  end

  -- Phase 7C: system alarm indicator (highest visibility — always last in bar)
  if M.system_alarm then
    local phase = M.system_alarm.phase or M.system_alarm.Phase or "?"
    table.insert(parts, "⚠ ALARM [" .. phase .. "]")
  end

  return table.concat(parts, " │ ")
end

-- ─── Setup ───────────────────────────────────────────────────────────────────

function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", M.config, opts)
  M.config.port = tonumber(vim.env.SAGEFS_MCP_PORT) or M.config.port
  wire = nil -- rebuilt with this config on next use
  reload_ui.setup()

  render.get_namespace()
  render.setup_highlights(M.config.highlight)
  require("sagefs.wire_testing").define_highlights()

  -- Apply cell_highlight config
  cell_highlight.setup_highlights()
  if M.config.cell_highlight and M.config.cell_highlight.style then
    cell_highlight.set_style(M.config.cell_highlight.style)
  end

  -- Clean up timer handles on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function() cell_highlight.teardown() end,
    once = true,
  })

  -- Helper closures that commands/keymaps/autocmds need
  local helpers = {
    notify = notify,
    start_sse = start_sse,
    stop_sse = stop_sse,
    base_url = function() return "http://localhost:" .. M.config.port end,
    dashboard_url = function() return "http://localhost:" .. M.config.dashboard_port end,
    clear_and_render = function()
      M.state = model.clear_cells(M.state)
      render.clear_extmarks(vim.api.nvim_get_current_buf())
      notify("Cleared all results")
    end,
    smart_eval = smart_eval_with_session_check,
    mark_stale_and_render = function(buf)
      M.state = model.mark_all_stale(M.state)
      render.render_all(buf, M.state)
    end,
    render_all = function(buf)
      render.render_all(buf, M.state)
    end,
    first_attach = function(_buf)
      require("sagefs.help").maybe_show_hint(M.config)
    end,
    has_results = function(buf)
      for _, c in pairs(M.state.cells) do
        if (c.buf == nil or c.buf == buf) and c.status ~= "idle" then return true end
      end
      return false
    end,
    render_signs = function(buf)
      render.render_test_signs(buf, M.testing_state, M.annotations_state)
      render.render_coverage_signs(buf, M.coverage_state)
      render.render_annotations(buf, M.annotations_state, M.density_state)
      require("sagefs.wire_testing").render(buf, M)
    end,
    check_on_save = function() return M.config.check_on_save end,
    check_code = check_code,
    has_active_session = function() return M.active_session ~= nil end,
    post_buffer_changed = function(buf) M.post_buffer_changed(buf) end,
  }

  commands.register_commands(M, helpers)
  require("sagefs.wire_commands").register(M)
  -- register_keymaps is invoked per-F#-buffer from inside register_autocmds
  -- (roast item 13 / §5.6): <A-CR> and <leader>r* must not be global.
  commands.register_autocmds(M, helpers)

  -- Dashboard panel (opt-in via config.dashboard or :SageFsDashboard command)
  local dashboard = require("sagefs.dashboard")
  dashboard.setup(opts.dashboard)
  M._dashboard = dashboard

  hotreload.setup(M.config.dashboard_port)

  -- Load F# snippets when LuaSnip is available (opt-out via config.snippets = false)
  if M.config.snippets ~= false then
    local ok, loader = pcall(require, "luasnip.loaders.from_vscode")
    if ok then
      local source = debug.getinfo(1, "S").source:sub(2)
      local plugin_root = vim.fn.fnamemodify(source, ":h:h:h")
      loader.lazy_load({ paths = { plugin_root .. "/snippets" } })
    end
  end

  if M.config.auto_connect then
    vim.defer_fn(function()
      M.health_check(function(healthy)
        if healthy then
          start_sse()
          M.list_sessions(function(result)
            M.offer_session_for_startup(result)
          end)
        end
      end)
    end, 500)
  end

  -- One-time welcome hint for new users. `vim.g` globals only survive a
  -- restart via shada when the name is ALL-CAPS with no lowercase letter
  -- AND the shada '!' flag is set (:help shada-g) — `sagefs_welcomed` is
  -- lowercase, so it never persisted: this fired on every single launch,
  -- forever, for every user. A marker file under stdpath("data") persists
  -- regardless of the user's shada configuration.
  local welcome_marker = M.config.welcome_marker_path or (vim.fn.stdpath("data") .. "/sagefs_welcomed")
  if vim.fn.filereadable(welcome_marker) == 0 then
    -- stdpath("data") may not exist yet on a fresh machine; fileio makes it
    -- and reports a failure as a message instead of raising E482 out of setup().
    local wrote, write_err = require("sagefs.fileio").write_file(welcome_marker, {})
    vim.defer_fn(function()
      vim.notify("[SageFs] Welcome! Run :SageFsStart to begin, or :checkhealth sagefs for setup guide.", vim.log.levels.INFO)
      if not wrote then
        vim.notify("[SageFs] could not remember that the welcome was shown (" .. tostring(write_err)
          .. "). You will see it again next launch; set welcome_marker_path to a writable file to stop that.",
          vim.log.levels.WARN)
      end
    end, 1000)
  end

  _G.SageFs = M
end

return M
