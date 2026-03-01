-- sagefs/model.lua — Elmish-inspired model for cell state management
-- Pure Lua, no vim API dependencies — fully testable with busted
--
-- State machine: idle → running → success|error → stale → running
-- stale is only reachable via mark_stale, not set_cell_state.
-- idle is the default state (via clear_cells or unknown cell).
local M = {}

-- Valid cell evaluation statuses
M.VALID_CELL_STATUSES = {
  idle = true,
  running = true,
  success = true,
  error = true,
  stale = true,
}

-- Valid connection statuses
M.VALID_CONNECTION_STATUSES = {
  connected = true,
  disconnected = true,
  reconnecting = true,
}

-- Valid transitions for set_cell_state
local TRANSITIONS = {
  idle = { running = true },
  running = { success = true, error = true, running = true },
  success = { running = true },
  error = { running = true },
  stale = { running = true },
}

--- Create a new empty model
---@return table
function M.new()
  return {
    cells = {},
    status = "disconnected",
    reconnect_gen = 0,
    stats = {
      eval_count = 0,
      eval_latency_sum_ms = 0,
      sse_events_total = 0,
      reconnect_count = 0,
    },
  }
end

--- Count tracked cells
---@param m table
---@return number
function M.cell_count(m)
  local count = 0
  for _ in pairs(m.cells) do count = count + 1 end
  return count
end

--- Set cell evaluation state with transition validation
---@param m table
---@param cell_id number
---@param status string "running"|"success"|"error"
---@param output string|nil
---@param metadata table|nil Optional extra data (e.g. duration_ms)
---@return table
function M.set_cell_state(m, cell_id, status, output, metadata)
  if not status or not M.VALID_CELL_STATUSES[status] then
    error(string.format("invalid cell status: %s", tostring(status)))
  end
  if status == "stale" then
    error("invalid cell status: stale (use mark_stale)")
  end
  if status == "idle" then
    error("invalid cell status: idle (use clear_cells)")
  end

  local current = m.cells[cell_id]
  local from = current and current.status or "idle"
  local allowed = TRANSITIONS[from]

  if not allowed or not allowed[status] then
    error(string.format("invalid transition: %s → %s", from, status))
  end

  m.cells[cell_id] = {
    status = status,
    output = output,
    duration_ms = metadata and metadata.duration_ms or nil,
    end_line = metadata and metadata.end_line or nil,
  }
  return m
end

--- Check if a cell is currently running (guard for concurrent eval)
---@param m table
---@param cell_id number
---@return boolean
function M.is_cell_running(m, cell_id)
  local cell = m.cells[cell_id]
  return cell ~= nil and cell.status == "running"
end

--- Get cell state (returns idle for unknown cells)
---@param m table
---@param cell_id number
---@return {status: string, output: string|nil}
function M.get_cell_state(m, cell_id)
  local cell = m.cells[cell_id]
  if not cell then
    return { status = "idle", output = nil }
  end
  return cell
end

--- Mark a cell as stale (only if it was success or error)
---@param m table
---@param cell_id number
---@return table
function M.mark_stale(m, cell_id)
  local cell = m.cells[cell_id]
  if cell and (cell.status == "success" or cell.status == "error") then
    cell.status = "stale"
  end
  return m
end

--- Mark all evaluated cells as stale
---@param m table
---@return table
function M.mark_all_stale(m)
  for id, cell in pairs(m.cells) do
    if cell.status == "success" or cell.status == "error" then
      cell.status = "stale"
    end
  end
  return m
end

--- Clear all cell state
---@param m table
---@return table
function M.clear_cells(m)
  m.cells = {}
  return m
end

--- Set connection status with validation
---@param m table
---@param status string "connected"|"disconnected"|"reconnecting"
---@return table
function M.set_status(m, status)
  if not status or not M.VALID_CONNECTION_STATUSES[status] then
    error(string.format("invalid connection status: %s", tostring(status)))
  end
  m.status = status
  return m
end

-- ─── Reconnect Generation Tracking ──────────────────────────────────────────

--- Set reconnect generation counter (for two-phase reconnect)
---@param m table
---@param gen number
---@return table
function M.set_reconnect_gen(m, gen)
  m.reconnect_gen = gen
  return m
end

-- ─── Stats / Observability ──────────────────────────────────────────────────

--- Record an eval completion with latency
---@param m table
---@param latency_ms number
---@return table
function M.record_eval(m, latency_ms)
  m.stats.eval_count = m.stats.eval_count + 1
  m.stats.eval_latency_sum_ms = m.stats.eval_latency_sum_ms + latency_ms
  return m
end

--- Record SSE events received (batch count)
---@param m table
---@param count number
---@return table
function M.record_sse_events(m, count)
  m.stats.sse_events_total = m.stats.sse_events_total + count
  return m
end

--- Record a reconnect event
---@param m table
---@return table
function M.record_reconnect(m)
  m.stats.reconnect_count = m.stats.reconnect_count + 1
  return m
end

--- Get average eval latency (or nil if no evals)
---@param m table
---@return number|nil
function M.eval_latency_avg(m)
  if m.stats.eval_count == 0 then return nil end
  return m.stats.eval_latency_sum_ms / m.stats.eval_count
end

return M
