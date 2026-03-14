-- sagefs/dashboard/sections/help.lua — Inline help section
-- Pure Lua, zero vim dependencies
--
-- Help is a section like any other — same protocol, same composition.
-- Toggled via `?` key. No special cases in the render pipeline.

local M = {}

M.id = "help"
M.label = "Help"
M.events = {} -- static content, never triggered by SSE events

local bindings = {
  { "q",       "Close dashboard" },
  { "<Tab>",   "Next section" },
  { "<S-Tab>", "Previous section" },
  { "1-9",     "Toggle section N" },
  { "e",       "Enable live testing" },
  { "d",       "Disable live testing" },
  { "h",       "Toggle hot reload" },
  { "r",       "Run all tests" },
  { "R",       "Refresh dashboard" },
  { "<CR>",    "Context action at cursor" },
  { "?",       "Toggle this help" },
}

--- Render the keybinding help section.
--- @param _ table state (unused — help is static content)
--- @return table SectionOutput
function M.render(_)
  local lines = {}
  local highlights = {}

  table.insert(lines, "═══ Keybindings ═══")
  table.insert(highlights, {
    line = 0, col_start = 0, col_end = #lines[1], hl_group = "SageFsSectionHeader",
  })

  for _, b in ipairs(bindings) do
    local line_text = string.format("  %-8s %s", b[1], b[2])
    table.insert(lines, line_text)
    table.insert(highlights, {
      line = #lines - 1,
      col_start = 2,
      col_end = 2 + #b[1],
      hl_group = "SageFsHelpKey",
    })
  end

  return { section_id = M.id, lines = lines, highlights = highlights, keymaps = {} }
end

return M
