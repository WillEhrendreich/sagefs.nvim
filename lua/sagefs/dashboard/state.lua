-- sagefs/dashboard/state.lua — Single state table for the dashboard
-- Pure Lua, zero vim dependencies, fully testable with busted
--
-- All dashboard-relevant state lives here. Updated by SSE event handlers.
-- Pure update function: (state, event_type, payload) -> state

local M = {}

-- ─── Default State ───────────────────────────────────────────────────────────

--- Create a fresh initial state with all defaults.
--- @return table
function M.new()
  return {
    daemon = {
      connected = false,
      version = nil,
      uptime = nil,
      memory_mb = nil,
      session_count = 0,
    },
    sessions = {},
    active_session_id = nil,
    testing = {
      enabled = false,
      summary = { total = 0, passed = 0, failed = 0, stale = 0, running = 0 },
      tests = {},
      failure_narratives = {},
    },
    hot_reload = {
      enabled = false,
      watched_files = {},
      total_files = 0,
    },
    diagnostics = {},
    eval = {
      output = nil,
      cell_id = nil,
      duration_ms = nil,
    },
    filmstrip = {},
    bindings = {},
    coverage = {
      total = 0,
      covered = 0,
      percent = 0,
    },
    alarms = {},
    warmup_context = nil,
    -- UI state
    visible_sections = {
      "health", "session", "tests", "diagnostics", "failures",
    },
    focused_section = nil,
  }
end

-- ─── Section Visibility ──────────────────────────────────────────────────────

--- Check if a section is visible.
--- @param state table
--- @param section_id string
--- @return boolean
function M.is_visible(state, section_id)
  for _, id in ipairs(state.visible_sections) do
    if id == section_id then return true end
  end
  return false
end

--- Toggle a section's visibility (add if absent, remove if present).
--- @param state table
--- @param section_id string
--- @return table state (mutated)
function M.toggle_section(state, section_id)
  for i, id in ipairs(state.visible_sections) do
    if id == section_id then
      table.remove(state.visible_sections, i)
      return state
    end
  end
  table.insert(state.visible_sections, section_id)
  return state
end

-- ─── Event Handlers ──────────────────────────────────────────────────────────

local handlers = {}

handlers.connected = function(state, payload)
  state.daemon.connected = true
  if payload then
    state.daemon.version = payload.version or payload.Version or state.daemon.version
    state.daemon.uptime = payload.uptime or payload.Uptime or state.daemon.uptime
    state.daemon.memory_mb = payload.memoryMb or payload.MemoryMb or state.daemon.memory_mb
    state.daemon.session_count = payload.sessionCount or payload.SessionCount or state.daemon.session_count
  end
  return state
end

handlers.disconnected = function(state, _)
  state.daemon.connected = false
  return state
end

handlers.test_summary = function(state, payload)
  if not payload then return state end
  state.testing.summary = {
    total = payload.total or payload.Total or 0,
    passed = payload.passed or payload.Passed or 0,
    failed = payload.failed or payload.Failed or 0,
    stale = payload.stale or payload.Stale or 0,
    running = payload.running or payload.Running or 0,
  }
  return state
end

handlers.test_state = function(state, payload)
  if not payload then return state end
  local enabled = payload.enabled
  if enabled == nil then enabled = payload.Enabled end
  if enabled ~= nil then state.testing.enabled = enabled end
  return state
end

handlers.failure_narratives = function(state, payload)
  if not payload then return state end
  state.testing.failure_narratives = payload.narratives or payload.Narratives or payload
  return state
end

handlers.eval_result = function(state, payload)
  if not payload then return state end
  state.eval = {
    output = payload.output or payload.Output or payload.text or payload.Text,
    cell_id = payload.cellId or payload.CellId,
    duration_ms = payload.durationMs or payload.DurationMs,
  }
  return state
end

handlers.eval_timeline = function(state, payload)
  if not payload then return state end
  state.filmstrip = payload.entries or payload.Entries or payload
  return state
end

handlers.bindings_snapshot = function(state, payload)
  if not payload then return state end
  state.bindings = payload.bindings or payload.Bindings or payload
  return state
end

handlers.coverage_updated = function(state, payload)
  if not payload then return state end
  state.coverage = {
    total = payload.total or payload.Total or 0,
    covered = payload.covered or payload.Covered or 0,
    percent = payload.percent or payload.Percent or 0,
  }
  return state
end

handlers.hotreload_snapshot = function(state, payload)
  if not payload then return state end
  local files = payload.files or payload.Files or {}
  state.hot_reload.watched_files = files
  state.hot_reload.total_files = payload.totalFiles or payload.TotalFiles or #files
  local enabled = payload.enabled
  if enabled == nil then enabled = payload.Enabled end
  if enabled ~= nil then state.hot_reload.enabled = enabled end
  return state
end

handlers.system_alarm = function(state, payload)
  if not payload then return state end
  table.insert(state.alarms, payload)
  return state
end

handlers.warmup_context = function(state, payload)
  if not payload then return state end
  state.warmup_context = payload
  return state
end

handlers.warmup_completed = function(state, _)
  -- Clear warmup context on completion; daemon health gets updated via connected
  return state
end

handlers.session_faulted = function(state, payload)
  if not payload then return state end
  -- Mark the session as faulted in session list if present
  local sid = payload.sessionId or payload.SessionId
  if sid then
    for _, s in ipairs(state.sessions) do
      if s.id == sid then s.status = "Faulted" end
    end
  end
  return state
end

-- ─── Dispatcher ──────────────────────────────────────────────────────────────

--- Pure update: event_type + payload → new state.
--- Unknown events are silently ignored (no error, state returned unchanged).
--- @param state table
--- @param event_type string
--- @param payload table|nil
--- @return table
function M.update(state, event_type, payload)
  local handler = handlers[event_type]
  if handler then
    return handler(state, payload)
  end
  return state
end

--- Get the list of all event types this state module handles.
--- Useful for wiring autocmd subscriptions.
--- @return string[]
function M.handled_events()
  local result = {}
  for k, _ in pairs(handlers) do
    table.insert(result, k)
  end
  table.sort(result)
  return result
end

return M
