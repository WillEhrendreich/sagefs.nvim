-- sagefs/dashboard/sections/filmstrip.lua — Filmstrip/timeline section
-- Pure Lua, zero vim dependencies

local M = {}

M.id = "filmstrip"
M.label = "Filmstrip"
M.events = { "eval_timeline" }

--- Render the filmstrip section from dashboard state.
--- @param state table
--- @return table SectionOutput
function M.render(state)
  local lines = {}
  local highlights = {}
  local keymaps = {}
  local entries = state.filmstrip or {}

  table.insert(lines, "═══ Filmstrip ═══")
  table.insert(highlights, {
    line = 0, col_start = 0, col_end = #lines[1], hl_group = "SageFsSectionHeader",
  })

  if #entries == 0 then
    table.insert(lines, "(no evals yet)")
    return { section_id = M.id, lines = lines, highlights = highlights, keymaps = keymaps }
  end

  for i, e in ipairs(entries) do
    local idx = e.index or e.Index or i
    local label = e.label or e.Label or ""
    local dur = e.durationMs or e.DurationMs
    local status = e.status or e.Status or "ok"
    local icon = status == "ok" and "✓" or "✗"

    local line_text
    if dur then
      line_text = string.format(" %s [%d] %s (%dms)", icon, idx, label, dur)
    else
      line_text = string.format(" %s [%d] %s", icon, idx, label)
    end
    table.insert(lines, line_text)

    local hl_group = status == "ok" and "SageFsEvalOk" or "SageFsEvalFail"
    table.insert(highlights, {
      line = #lines - 1, col_start = 1, col_end = 1 + #icon, hl_group = hl_group,
    })

    -- Navigate to eval
    table.insert(keymaps, {
      line = #lines - 1, key = "<CR>",
      action = { type = "jump_to_eval", index = idx },
    })

    if i >= 15 then
      table.insert(lines, string.format("  ... and %d more", #entries - 15))
      break
    end
  end

  return { section_id = M.id, lines = lines, highlights = highlights, keymaps = keymaps }
end

return M
