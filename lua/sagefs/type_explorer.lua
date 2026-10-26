-- sagefs/type_explorer.lua — Pure type exploration formatting
-- Formats completions-based exploration results for picker/float display
-- Zero vim dependencies

local completions_wire = require("sagefs.completions")

local M = {}

--- How many members one explorer request asks for. The daemon's default is 50,
--- which cut `System.IO` (64 members) without saying so; its ceiling is 2000.
--- 200 is what the VS Code Type Explorer asks for, and a picker with more rows
--- than that is not browsable anyway: the size line says how many were left out.
M.ROWS_REQUESTED = 200

--- The body of the explorer's POST /api/completions: "Name." with the cursor
--- after the dot, and a limit. The caller adds the session id (sessions.scope_body).
---@param qualified_name string
---@return table
function M.build_request_body(qualified_name)
  local code = qualified_name .. "."
  return { code = code, cursor_position = #code, limit = M.ROWS_REQUESTED }
end

-- Kind icons for type/member completions
local KIND_ICONS = {
  Class = "◆", Struct = "◇", Interface = "◈",
  Enum = "▣", Union = "▤", Module = "▥",
  Namespace = "▷", Method = "ƒ", Property = "●",
  Field = "○", Event = "⚡", Constant = "π",
  Variable = "𝑥", Keyword = "⌘", ExtensionMethod = "ƒ+",
  EnumMember = "▪", Delegate = "◈", Exception = "⚠",
  OverriddenMethod = "ƒ↑", TypeParameter = "T", Typedef = "≡",
}

-- Kinds that represent drillable items (can explore further with ".")
local DRILLABLE_KINDS = {
  Namespace = true, Module = true, Class = true, Struct = true,
  Interface = true, Enum = true, Union = true, Type = true,
}

--- Format completions into picker items for exploration.
---@param completions table[] { label, kind, insertText }
---@param listing table|nil from completions.listing_of; when the reply was cut from a larger set
---  a last row says so. It is a note, not a member: `note = true`, and choosing it does nothing.
---@return table[] { label, insertText, kind, drillable, note? }
function M.format_completions(completions, listing)
  local items = {}
  for _, c in ipairs(completions) do
    local icon = KIND_ICONS[c.kind] or "·"
    local drillable = DRILLABLE_KINDS[c.kind] or false
    items[#items + 1] = {
      label = string.format("%s %s  (%s)%s", icon, c.label, c.kind or "?", drillable and " →" or ""),
      insertText = c.insertText or c.label,
      kind = c.kind or "",
      drillable = drillable,
    }
  end
  table.sort(items, function(a, b)
    if a.drillable ~= b.drillable then return a.drillable end
    if a.kind ~= b.kind then return a.kind < b.kind end
    return a.label < b.label
  end)
  local size_line = completions_wire.size_line(listing)
  if size_line then
    items[#items + 1] = { label = size_line, insertText = "", kind = "", drillable = false, note = true }
  end
  return items
end

--- Format completions as a floating window panel (for non-drillable leaf views).
---@param qualified_name string
---@param completions table[] { label, kind, insertText }
---@param listing table|nil from completions.listing_of; says how large the set was when it was
---  cut, or why nothing could be listed
---@return string[]
function M.format_members_panel(qualified_name, completions, listing)
  local lines = { string.format("═══ %s ═══", qualified_name), "" }
  local note = completions_wire.unavailable_line(listing) or completions_wire.size_line(listing)
  if note then
    lines[#lines + 1] = note
    lines[#lines + 1] = ""
  end

  -- Group by kind
  local grouped = {}
  local kind_order = {}
  for _, c in ipairs(completions) do
    local kind = c.kind or "Other"
    if not grouped[kind] then
      grouped[kind] = {}
      kind_order[#kind_order + 1] = kind
    end
    grouped[kind][#grouped[kind] + 1] = c
  end
  table.sort(kind_order)

  for _, kind in ipairs(kind_order) do
    local icon = KIND_ICONS[kind] or "·"
    lines[#lines + 1] = string.format("  %s %s:", icon, kind)
    for _, c in ipairs(grouped[kind]) do
      lines[#lines + 1] = "    " .. (c.label or c.insertText or "?")
    end
    lines[#lines + 1] = ""
  end

  return lines
end

--- Common starting namespaces for initial exploration prompt.
---@return string[]
function M.common_roots()
  return {
    "System",
    "System.Collections.Generic",
    "System.IO",
    "System.Linq",
    "System.Text",
    "System.Threading.Tasks",
    "Microsoft.FSharp.Collections",
    "Microsoft.FSharp.Core",
  }
end

return M
