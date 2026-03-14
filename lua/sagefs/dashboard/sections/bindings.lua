-- sagefs/dashboard/sections/bindings.lua — Bindings section
-- Pure Lua, zero vim dependencies

local M = {}

M.id = "bindings"
M.label = "Bindings"
M.events = { "bindings_snapshot" }

--- Render the bindings section from dashboard state.
--- @param state table
--- @return table SectionOutput
function M.render(state)
  local lines = {}
  local highlights = {}
  local keymaps = {}
  local bindings = state.bindings or {}

  table.insert(lines, "═══ Bindings ═══")
  table.insert(highlights, {
    line = 0, col_start = 0, col_end = #lines[1], hl_group = "SageFsSectionHeader",
  })

  if #bindings == 0 then
    table.insert(lines, "(no bindings)")
    return { section_id = M.id, lines = lines, highlights = highlights, keymaps = keymaps }
  end

  for _, b in ipairs(bindings) do
    local name = b.name or b.Name or "?"
    local type_sig = b.typeSig or b.TypeSig or ""
    local value = b.value or b.Value or ""

    local line_text
    if type_sig ~= "" then
      line_text = string.format("val %s : %s = %s", name, type_sig, value)
    else
      line_text = string.format("val %s = %s", name, value)
    end
    table.insert(lines, line_text)

    -- Highlight the binding name
    table.insert(highlights, {
      line = #lines - 1, col_start = 4, col_end = 4 + #name, hl_group = "SageFsBindingName",
    })

    -- Jump to binding keymap
    table.insert(keymaps, {
      line = #lines - 1, key = "<CR>",
      action = { type = "inspect_binding", name = name },
    })
  end

  return { section_id = M.id, lines = lines, highlights = highlights, keymaps = keymaps }
end

return M
