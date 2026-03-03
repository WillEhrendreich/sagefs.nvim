-- sagefs/scope_map.lua — Spatial binding scope visualization
-- Pure Lua, no vim dependencies.

local M = {}
local format = require("sagefs.format")

--- Build scope map from binding tracker + cell layout.
---@param tracker table binding tracker state
---@param cells_data table[] {id, start_line, end_line, text}
---@param cell_outputs table<number, string> cell_id → FSI output
---@return table[] ScopeEntry[]
function M.build_scope_map(tracker, cells_data, cell_outputs)
  local entries = {}
  for _, cell in ipairs(cells_data) do
    local output = cell_outputs[cell.id] or ""
    local bindings = format.parse_bindings(output)
    for _, b in ipairs(bindings) do
      local existing = tracker.bindings[b.name]
      entries[#entries + 1] = {
        name = b.name,
        type_sig = b.type_sig,
        cell_id = cell.id,
        cell_start_line = cell.start_line,
        cell_end_line = cell.end_line,
        shadow_count = existing and math.max(0, existing.count - 1) or 0,
        is_current = existing and existing.type_sig == b.type_sig or false,
      }
    end
  end
  table.sort(entries, function(a, b) return a.cell_start_line < b.cell_start_line end)
  return entries
end

--- Compute which bindings are in scope at a given line.
---@param scope_map table[] ScopeEntry[]
---@param line number 1-indexed
---@return table[] bindings visible at this line
function M.bindings_at_line(scope_map, line)
  local latest = {}
  for _, e in ipairs(scope_map) do
    if e.cell_end_line <= line or (e.cell_start_line <= line and e.cell_end_line >= line) then
      latest[e.name] = e
    end
  end
  local result = {}
  for _, e in pairs(latest) do result[#result + 1] = e end
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end

--- Format scope map for floating window display.
---@param scope_map table[]
---@return string[]
function M.format_panel(scope_map)
  local lines = { "═══ Binding Scope Map ═══", "" }
  for _, e in ipairs(scope_map) do
    local shadow = e.shadow_count > 0 and string.format(" !! shadowed x%d", e.shadow_count) or ""
    lines[#lines + 1] = string.format("  %s : %s  (cell %d, L%d-%d)%s",
      e.name, e.type_sig, e.cell_id, e.cell_start_line, e.cell_end_line, shadow)
  end
  return lines
end

--- Format scope map entries for telescope/picker.
---@param scope_map table[]
---@return table[] {label, name, cell_id, line}
function M.format_picker_items(scope_map)
  local items = {}
  for _, e in ipairs(scope_map) do
    local shadow = e.shadow_count > 0 and " !! shadow" or ""
    items[#items + 1] = {
      label = string.format("%s : %s  [cell %d]%s", e.name, e.type_sig, e.cell_id, shadow),
      name = e.name,
      cell_id = e.cell_id,
      line = e.cell_start_line,
    }
  end
  return items
end

return M
