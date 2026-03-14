-- sagefs/dashboard/sections/diagnostics.lua — Diagnostics/errors section
-- Pure Lua, zero vim dependencies

local M = {}

M.id = "diagnostics"
M.label = "Diagnostics"
M.events = { "eval_completed", "eval_result" }

--- Render the diagnostics section from dashboard state.
--- @param state table
--- @return table SectionOutput
function M.render(state)
  local lines = {}
  local highlights = {}
  local diags = state.diagnostics or {}

  table.insert(lines, "═══ Diagnostics ═══")
  table.insert(highlights, {
    line = 0, col_start = 0, col_end = #lines[1], hl_group = "SageFsSectionHeader",
  })

  if #diags == 0 then
    table.insert(lines, "No diagnostics")
    return { section_id = M.id, lines = lines, highlights = highlights, keymaps = {} }
  end

  for i, d in ipairs(diags) do
    local severity = d.severity or "info"
    local msg = d.message or ""
    local prefix
    local hl_group
    if severity == "error" then
      prefix = "✗"
      hl_group = "SageFsDiagError"
    elseif severity == "warning" then
      prefix = "⚠"
      hl_group = "SageFsDiagWarn"
    else
      prefix = "ℹ"
      hl_group = "SageFsDiagInfo"
    end

    local loc = ""
    if d.file then
      loc = string.format(" (%s:%s)", d.file, d.line or "?")
    end
    local line_text = string.format(" %s %s%s", prefix, msg, loc)
    table.insert(lines, line_text)
    table.insert(highlights, {
      line = #lines - 1, col_start = 1, col_end = 1 + #prefix, hl_group = hl_group,
    })
    -- Limit visible count
    if i >= 20 then
      table.insert(lines, string.format("  ... and %d more", #diags - 20))
      break
    end
  end

  return { section_id = M.id, lines = lines, highlights = highlights, keymaps = {} }
end

return M
