-- sagefs/dashboard/sections/hot_reload.lua — Hot reload section
-- Pure Lua, zero vim dependencies

local reload_state = require("sagefs.reload_state")
local repl_freshness = require("sagefs.repl_freshness")

local M = {}

M.id = "hot_reload"
M.label = "Hot Reload"
M.events = { "hotreload_snapshot", "file_reloaded", "reload_reported", "repl_freshness_changed" }

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

  -- What the last save did, in the words every surface uses, and whether the REPL
  -- runs the app's build. The session is the dashboard's active one when it has
  -- one, else the one that spoke last.
  local report, sid
  if state.active_session_id and state.reload then
    sid = state.active_session_id
    report = reload_state.current(state.reload, sid)
  elseif state.reload then
    report, sid = reload_state.latest(state.reload)
  end
  local function add_lines(entries)
    for _, entry in ipairs(entries) do
      table.insert(lines, entry.text)
      table.insert(highlights, {
        line = #lines - 1, col_start = 0, col_end = #entry.text, hl_group = entry.hl,
      })
    end
  end
  if report then
    add_lines(reload_state.lines(report, sid and reload_state.previous(state.reload, sid) or nil))
  end
  local fresh = state.repl_freshness and (state.repl_freshness[sid or state.repl_sid or ""] or nil)
  if fresh then
    add_lines(repl_freshness.lines(fresh))
  end

  return { section_id = M.id, lines = lines, highlights = highlights, keymaps = keymaps }
end

return M
