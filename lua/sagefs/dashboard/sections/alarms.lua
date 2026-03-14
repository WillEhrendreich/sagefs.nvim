-- sagefs/dashboard/sections/alarms.lua — System alarms section
-- Pure Lua, zero vim dependencies

local M = {}

M.id = "alarms"
M.label = "Alarms"
M.events = { "system_alarm" }

--- Render the alarms section from dashboard state.
--- @param state table
--- @return table SectionOutput
function M.render(state)
  local lines = {}
  local highlights = {}
  local alarms = state.alarms or {}

  table.insert(lines, "═══ Alarms ═══")
  table.insert(highlights, {
    line = 0, col_start = 0, col_end = #lines[1], hl_group = "SageFsSectionHeader",
  })

  if #alarms == 0 then
    table.insert(lines, "No alarms")
    return { section_id = M.id, lines = lines, highlights = highlights, keymaps = {} }
  end

  for i, a in ipairs(alarms) do
    local alarm_type = a.type or a.Type or "unknown"
    local value = a.value or a.Value or ""
    table.insert(lines, string.format("⚠ %s: %s", alarm_type, tostring(value)))
    table.insert(highlights, {
      line = #lines - 1, col_start = 0, col_end = 3, hl_group = "SageFsAlarm",
    })
    if i >= 10 then
      table.insert(lines, string.format("  ... and %d more", #alarms - 10))
      break
    end
  end

  return { section_id = M.id, lines = lines, highlights = highlights, keymaps = {} }
end

return M
