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
---@return table
function M.set_cell_state(m, cell_id, status, output)
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
  }
  return m
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

return M
