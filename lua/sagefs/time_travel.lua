-- sagefs/time_travel.lua — Cell output history with navigation
-- Pure Lua, no vim dependencies.

local M = {}
local diff = require("sagefs.diff")

--- Create a new time-travel state.
---@param max_history number|nil default 50
---@return table
function M.new(max_history)
  return {
    max_history = max_history or 50,
    cells = {}, -- cell_id → { entries = {}, cursor = nil }
  }
end

local function ensure_cell(state, cell_id)
  if not state.cells[cell_id] then
    state.cells[cell_id] = { entries = {} }
  end
  return state.cells[cell_id]
end

--- Record a new eval output for a cell.
---@param state table
---@param cell_id number
---@param output string
---@param metadata table {duration_ms, timestamp_ms}
---@return table state
function M.record(state, cell_id, output, metadata)
  local cell = ensure_cell(state, cell_id)
  cell.entries[#cell.entries + 1] = {
    output = output,
    duration_ms = metadata and metadata.duration_ms or 0,
    timestamp_ms = metadata and metadata.timestamp_ms or 0,
  }
  -- Trim to max_history
  while #cell.entries > state.max_history do
    table.remove(cell.entries, 1)
  end
  return state
end

--- Count history entries for a cell.
---@param state table
---@param cell_id number
---@return number
function M.history_count(state, cell_id)
  local cell = state.cells[cell_id]
  if not cell then return 0 end
  return #cell.entries
end

--- Get the current (latest) entry for a cell.
---@param state table
---@param cell_id number
---@return table|nil {output, index, total, duration_ms, timestamp_ms}
function M.current(state, cell_id)
  local cell = state.cells[cell_id]
  if not cell or #cell.entries == 0 then return nil end
  local n = #cell.entries
  local e = cell.entries[n]
  return {
    output = e.output,
    index = n,
    total = n,
    duration_ms = e.duration_ms,
    timestamp_ms = e.timestamp_ms,
  }
end

--- Navigate relative to current (latest) position.
---@param state table
---@param cell_id number
---@param offset number negative = backward, positive = forward
---@return table|nil {output, index, total, duration_ms, timestamp_ms}
function M.navigate(state, cell_id, offset)
  local cell = state.cells[cell_id]
  if not cell or #cell.entries == 0 then return nil end
  local n = #cell.entries
  local target = math.max(1, math.min(n, n + offset))
  local e = cell.entries[target]
  return {
    output = e.output,
    index = target,
    total = n,
    duration_ms = e.duration_ms,
    timestamp_ms = e.timestamp_ms,
  }
end

--- Format a nav status line.
---@param nav table from current/navigate
---@return string
function M.format_nav_status(nav)
  if not nav then return "no history" end
  return string.format("%d/%d (%dms)", nav.index, nav.total, nav.duration_ms)
end

--- Diff a historical entry against the current (latest) output.
---@param state table
---@param cell_id number
---@param index number 1-based
---@return table[]|nil diff_result from diff.diff_lines
function M.diff_with_current(state, cell_id, index)
  local cell = state.cells[cell_id]
  if not cell or #cell.entries == 0 then return nil end
  local n = #cell.entries
  local idx = math.max(1, math.min(n, index))
  local old = cell.entries[idx].output
  local current = cell.entries[n].output
  return diff.diff_lines(old, current)
end

return M
