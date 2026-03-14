-- sagefs/dashboard/sections/hot_reload.lua — Hot reload section
-- Pure Lua, zero vim dependencies

local M = {}

M.id = "hot_reload"
M.label = "Hot Reload"
M.events = { "hotreload_snapshot", "file_reloaded" }

--- Render the hot reload section from dashboard state.
--- @param state table
--- @return table SectionOutput
function M.render(state)
  local lines = {}
  local highlights = {}
  local keymaps = {}
  local hr = state.hot_reload or {}

  table.insert(lines, "═══ Hot Reload ═══")
  table.insert(highlights, {
    line = 0, col_start = 0, col_end = #lines[1], hl_group = "SageFsSectionHeader",
  })

  local status_line
  if hr.enabled then
    status_line = "● Hot Reload: ON"
    table.insert(highlights, {
      line = 1, col_start = 0, col_end = 1, hl_group = "SageFsHotReloadOn",
    })
  else
    status_line = "○ Hot Reload: OFF"
    table.insert(highlights, {
      line = 1, col_start = 0, col_end = 1, hl_group = "SageFsHotReloadOff",
    })
  end
  table.insert(lines, status_line)

  -- Toggle keymap
  table.insert(keymaps, {
    line = 1, key = "h",
    action = { type = "toggle_hot_reload" },
  })

  -- File count
  local watched = hr.watched_files or {}
  local total = hr.total_files or 0
  if total > 0 then
    table.insert(lines, string.format("Watched: %d / %d files", #watched, total))
  end

  return { section_id = M.id, lines = lines, highlights = highlights, keymaps = keymaps }
end

return M
