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
    -- §5.5: a Degraded session is worker-Ready by definition (the worker is
    -- alive; it just loaded nothing usable) — `status` alone can never show
    -- it. `s.health` is passed through unchanged: absent means "no verdict
    -- computed", never "healthy" — so a session with no health data gets no
    -- suffix and no highlight, exactly like before this fix.
    local health = s.health
    local health_suffix = ""
    if health and (health.status == "Degraded" or health.status == "Failed") then
      health_suffix = string.format("  [%s%s]", health.status, health.reason and (" — " .. health.reason) or "")
    end
    local line_text = string.format("%s %s %s %s%s", marker, short_id, status, proj, health_suffix)
    table.insert(lines, line_text)

    local line_idx = #lines - 1
    if status == "Faulted" then
      table.insert(highlights, {
        line = line_idx, col_start = 0, col_end = #line_text, hl_group = "SageFsSessionFaulted",
      })
    elseif health and health.status == "Degraded" then
      table.insert(highlights, {
        line = line_idx, col_start = 0, col_end = #line_text, hl_group = "SageFsSessionDegraded",
      })
    elseif health and health.status == "Failed" then
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
