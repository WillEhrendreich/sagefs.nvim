-- sagefs/dashboard/sections/failures.lua — Test failure narratives section
-- Pure Lua, zero vim dependencies

local M = {}

M.id = "failures"
M.label = "Failures"
M.events = { "failure_narratives", "test_results_batch" }

--- Render the failures section from dashboard state.
--- @param state table
--- @return table SectionOutput
function M.render(state)
  local lines = {}
  local highlights = {}
  local keymaps = {}
  local narratives = (state.testing or {}).failure_narratives or {}

  table.insert(lines, "═══ Failures ═══")
  table.insert(highlights, {
    line = 0, col_start = 0, col_end = #lines[1], hl_group = "SageFsSectionHeader",
  })

  if #narratives == 0 then
    table.insert(lines, "No failures")
    table.insert(highlights, {
      line = 1, col_start = 0, col_end = #lines[2], hl_group = "SageFsTestsPass",
    })
    return { section_id = M.id, lines = lines, highlights = highlights, keymaps = keymaps }
  end

  table.insert(lines, string.format("🔴 %d failure(s)", #narratives))
  table.insert(highlights, {
    line = 1, col_start = 0, col_end = #lines[2], hl_group = "SageFsTestsFail",
  })

  for i, n in ipairs(narratives) do
    local name = n.testName or n.TestName or "Unknown"
    local summary = n.summary or n.Summary or ""
    table.insert(lines, string.format("  🔴 %s", name))
    table.insert(highlights, {
      line = #lines - 1, col_start = 2, col_end = #lines[#lines], hl_group = "SageFsTestsFail",
    })
    if summary ~= "" then
      table.insert(lines, string.format("     %s", summary))
    end
    -- Jump to test keymap
    table.insert(keymaps, {
      line = #lines - 2, key = "<CR>",
      action = { type = "jump_to_test", test_name = name },
    })
    -- Limit display
    if i >= 10 then
      table.insert(lines, string.format("  ... and %d more", #narratives - 10))
      break
    end
  end

  return { section_id = M.id, lines = lines, highlights = highlights, keymaps = keymaps }
end

return M
