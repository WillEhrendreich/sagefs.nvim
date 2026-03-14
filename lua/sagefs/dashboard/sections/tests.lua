-- sagefs/dashboard/sections/tests.lua — Live testing section
-- Pure Lua, zero vim dependencies

local M = {}

M.id = "tests"
M.label = "Tests"
M.events = { "test_summary", "test_state", "test_results_batch" }

--- Render the testing section from dashboard state.
--- @param state table
--- @return table SectionOutput
function M.render(state)
  local lines = {}
  local highlights = {}
  local keymaps = {}
  local t = state.testing or {}
  local summary = t.summary or {}

  table.insert(lines, "═══ Tests ═══")
  table.insert(highlights, {
    line = 0, col_start = 0, col_end = #lines[1], hl_group = "SageFsSectionHeader",
  })

  -- ON/OFF status
  local status_line
  if t.enabled then
    status_line = "● Live Testing: ON"
    table.insert(highlights, {
      line = 1, col_start = 0, col_end = 1, hl_group = "SageFsTestsEnabled",
    })
  else
    status_line = "○ Live Testing: OFF"
    table.insert(highlights, {
      line = 1, col_start = 0, col_end = 1, hl_group = "SageFsTestsDisabled",
    })
  end
  table.insert(lines, status_line)

  -- Toggle keybinds
  table.insert(keymaps, {
    line = 1, key = "e",
    action = { type = "enable_testing" },
  })
  table.insert(keymaps, {
    line = 1, key = "d",
    action = { type = "disable_testing" },
  })

  -- Summary counts
  local total = summary.total or 0
  if total > 0 then
    local parts = {}
    if (summary.passed or 0) > 0 then
      table.insert(parts, string.format("✓%d", summary.passed))
    end
    if (summary.failed or 0) > 0 then
      table.insert(parts, string.format("✗%d", summary.failed))
    end
    if (summary.stale or 0) > 0 then
      table.insert(parts, string.format("~%d", summary.stale))
    end
    if (summary.running or 0) > 0 then
      table.insert(parts, string.format("⟳%d", summary.running))
    end
    local counts = table.concat(parts, " ")
    table.insert(lines, string.format("%d tests: %s", total, counts))

    -- Colorize pass/fail counts
    local line_idx = #lines - 1
    if (summary.failed or 0) > 0 then
      table.insert(highlights, {
        line = line_idx, col_start = 0, col_end = #lines[#lines], hl_group = "SageFsTestsFail",
      })
    elseif (summary.passed or 0) == total then
      table.insert(highlights, {
        line = line_idx, col_start = 0, col_end = #lines[#lines], hl_group = "SageFsTestsPass",
      })
    end
  else
    table.insert(lines, "No tests discovered")
  end

  -- Run all tests keymap
  table.insert(keymaps, {
    line = #lines - 1, key = "r",
    action = { type = "run_tests" },
  })

  return { section_id = M.id, lines = lines, highlights = highlights, keymaps = keymaps }
end

return M
