-- sagefs/type_explorer.lua — Pure type exploration formatting
-- Formats completions-based exploration results for picker/float display
-- Zero vim dependencies

local M = {}

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
---@return table[] { label, insertText, kind, drillable }
function M.format_completions(completions)
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
  return items
end

--- Format completions as a floating window panel (for non-drillable leaf views).
---@param qualified_name string
---@param completions table[] { label, kind, insertText }
---@return string[]
function M.format_members_panel(qualified_name, completions)
  local lines = { string.format("═══ %s ═══", qualified_name), "" }

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
