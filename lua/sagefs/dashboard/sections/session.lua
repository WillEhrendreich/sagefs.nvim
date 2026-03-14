-- sagefs/dashboard/sections/session.lua — Session status section
-- Pure Lua, zero vim dependencies

local M = {}

M.id = "session"
M.label = "Sessions"
M.events = { "connected", "session_faulted" }

--- Render the session section from dashboard state.
--- @param state table
--- @return table SectionOutput
function M.render(state)
  local lines = {}
  local highlights = {}
  local keymaps = {}
  local sessions = state.sessions or {}
  local active = state.active_session_id

  table.insert(lines, "═══ Sessions ═══")
  table.insert(highlights, {
    line = 0, col_start = 0, col_end = #lines[1], hl_group = "SageFsSectionHeader",
  })

  if #sessions == 0 then
    table.insert(lines, "No sessions")
    return { section_id = M.id, lines = lines, highlights = highlights, keymaps = keymaps }
  end

  for i, s in ipairs(sessions) do
    local sid = s.id or "?"
    local short_id = sid:sub(1, 8)
    local status = s.status or "Unknown"
    local proj = s.project or ""
    local is_active = sid == active
    local marker = is_active and "▶" or " "
    local line_text = string.format("%s %s %s %s", marker, short_id, status, proj)
    table.insert(lines, line_text)

    local line_idx = #lines - 1
    if status == "Faulted" then
      table.insert(highlights, {
        line = line_idx, col_start = 0, col_end = #line_text, hl_group = "SageFsSessionFaulted",
      })
    elseif is_active then
      table.insert(highlights, {
        line = line_idx, col_start = 0, col_end = #line_text, hl_group = "SageFsSessionActive",
      })
    end

    -- Click to switch session
    table.insert(keymaps, {
      line = line_idx, key = "<CR>",
      action = { type = "switch_session", session_id = sid },
    })
  end

  return { section_id = M.id, lines = lines, highlights = highlights, keymaps = keymaps }
end

return M
