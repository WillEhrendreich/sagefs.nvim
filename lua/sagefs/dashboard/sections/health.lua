-- sagefs/dashboard/sections/health.lua — Daemon health section
-- Pure Lua, zero vim dependencies

local M = {}

M.id = "health"
M.label = "Health"
M.events = { "connected", "disconnected", "warmup_progress", "warmup_completed" }

--- Render the health section from dashboard state.
--- @param state table
--- @return table SectionOutput { lines, highlights, keymaps }
function M.render(state)
  local lines = {}
  local highlights = {}
  local d = state.daemon or {}

  table.insert(lines, "═══ Health ═══")
  table.insert(highlights, {
    line = 0, col_start = 0, col_end = #lines[1], hl_group = "SageFsSectionHeader",
  })

  local status = d.connected and "● Connected" or "○ Disconnected"
  table.insert(lines, status)
  table.insert(highlights, {
    line = #lines - 1,
    col_start = 0,
    col_end = d.connected and 1 or 1,
    hl_group = d.connected and "SageFsHealthOk" or "SageFsHealthError",
  })

  if d.version then
    table.insert(lines, "Version: " .. tostring(d.version))
  end
  if d.uptime then
    table.insert(lines, "Uptime: " .. tostring(d.uptime))
  end
  if d.memory_mb then
    table.insert(lines, string.format("Memory: %d MB", d.memory_mb))
  end
  if d.session_count and d.session_count > 0 then
    table.insert(lines, string.format("Sessions: %d", d.session_count))
  end

  -- Warmup context indicator
  if state.warmup_context then
    table.insert(lines, "⏳ Warming up...")
    table.insert(highlights, {
      line = #lines - 1, col_start = 0, col_end = 2, hl_group = "SageFsWarmup",
    })
  end

  return { section_id = M.id, lines = lines, highlights = highlights, keymaps = {} }
end

return M
