-- sagefs/dashboard/sections/coverage.lua — Coverage section
-- Pure Lua, zero vim dependencies

local M = {}

M.id = "coverage"
M.label = "Coverage"
M.events = { "coverage_updated" }

--- Render the coverage section from dashboard state.
--- @param state table
--- @return table SectionOutput
function M.render(state)
  local lines = {}
  local highlights = {}
  local cov = state.coverage or {}

  table.insert(lines, "═══ Coverage ═══")
  table.insert(highlights, {
    line = 0, col_start = 0, col_end = #lines[1], hl_group = "SageFsSectionHeader",
  })

  local total = cov.total or 0
  local covered = cov.covered or 0
  local pct = cov.percent or 0

  if total == 0 then
    table.insert(lines, "No coverage data")
    return { section_id = M.id, lines = lines, highlights = highlights, keymaps = {} }
  end

  -- Progress bar
  local bar_width = 20
  local filled = math.floor(bar_width * pct / 100 + 0.5)
  local bar = string.rep("█", filled) .. string.rep("░", bar_width - filled)
  table.insert(lines, string.format("[%s] %d%%", bar, pct))

  -- Color the bar based on coverage level
  local hl_group
  if pct >= 80 then
    hl_group = "SageFsCoverageGood"
  elseif pct >= 50 then
    hl_group = "SageFsCoverageWarn"
  else
    hl_group = "SageFsCoverageBad"
  end
  table.insert(highlights, {
    line = 1, col_start = 0, col_end = #lines[2], hl_group = hl_group,
  })

  table.insert(lines, string.format("%d / %d lines covered", covered, total))

  return { section_id = M.id, lines = lines, highlights = highlights, keymaps = {} }
end

return M
