-- sagefs/depgraph_viz.lua — In-buffer dependency arrow visualization
-- Pure Lua, no vim dependencies.

local M = {}
local depgraph = require("sagefs.depgraph")

--- Compute arrow descriptors from graph edges + cell layout.
---@param graph table from depgraph.build_graph
---@param cells_layout table<number, {start_line: number, end_line: number}>
---@return table[] arrows
function M.compute_arrows(graph, cells_layout)
  local arrows = {}
  for _, edge in ipairs(graph.edges) do
    local from_layout = cells_layout[edge.from]
    local to_layout = cells_layout[edge.to]
    if from_layout and to_layout then
      -- Find which bindings flow along this edge
      local binding_names = {}
      local from_analysis = graph.analyses[edge.from]
      local to_analysis = graph.analyses[edge.to]
      if from_analysis and to_analysis then
        local produces_set = {}
        for _, p in ipairs(from_analysis.produces) do produces_set[p] = true end
        for _, c in ipairs(to_analysis.consumes) do
          if produces_set[c] then
            binding_names[#binding_names + 1] = c
          end
        end
      end
      table.sort(binding_names)
      arrows[#arrows + 1] = {
        from_cell = edge.from,
        to_cell = edge.to,
        from_line = from_layout.end_line,
        to_line = to_layout.start_line,
        binding_names = binding_names,
      }
    end
  end
  table.sort(arrows, function(a, b) return a.from_line < b.from_line end)
  return arrows
end

--- Format sign column marks for cells that have dependencies.
---@param arrows table[] from compute_arrows
---@param cells_layout table
---@return table[] {line, text, hl}
function M.format_sign_marks(arrows, cells_layout)
  local marks = {}
  local producer_cells = {}
  local consumer_cells = {}
  for _, a in ipairs(arrows) do
    producer_cells[a.from_cell] = true
    consumer_cells[a.to_cell] = true
  end
  for cell_id in pairs(producer_cells) do
    local layout = cells_layout[cell_id]
    if layout then
      marks[#marks + 1] = {
        line = layout.start_line,
        text = "▶",
        hl = "SageFsDepSource",
      }
    end
  end
  for cell_id in pairs(consumer_cells) do
    local layout = cells_layout[cell_id]
    if layout then
      marks[#marks + 1] = {
        line = layout.start_line,
        text = "◀",
        hl = "SageFsDepTarget",
      }
    end
  end
  table.sort(marks, function(a, b) return a.line < b.line end)
  return marks
end

--- Format inline annotations showing dataflow.
---@param arrows table[]
---@return table[] {line, text, hl}
function M.format_inline_annotations(arrows)
  local annotations = {}
  for _, a in ipairs(arrows) do
    local names = table.concat(a.binding_names, ", ")
    annotations[#annotations + 1] = {
      line = a.to_line,
      text = string.format("  ← %s from cell %d", names, a.from_cell),
      hl = "SageFsDepFlow",
    }
  end
  return annotations
end

--- Format stale cascade when a cell is re-evaluated.
---@param graph table
---@param changed_cell number
---@param cells_layout table
---@return table[] {cell_id, line, label}
function M.format_stale_cascade(graph, changed_cell, cells_layout)
  local stale_ids = depgraph.transitive_stale(graph, changed_cell)
  local result = {}
  for _, cid in ipairs(stale_ids) do
    local layout = cells_layout[cid]
    if layout then
      result[#result + 1] = {
        cell_id = cid,
        line = layout.start_line,
        label = string.format("⚡ stale (depends on cell %d)", changed_cell),
      }
    end
  end
  return result
end

--- Format a panel summary of all dependency arrows.
---@param arrows table[]
---@param cells_layout table
---@return string[]
function M.format_panel(arrows, cells_layout)
  if #arrows == 0 then
    return { "No cross-cell dependencies detected." }
  end
  local lines = { string.format("═══ Dependency Arrows (%d flows) ═══", #arrows), "" }
  for _, a in ipairs(arrows) do
    local names = table.concat(a.binding_names, ", ")
    lines[#lines + 1] = string.format("  cell %d → cell %d  via %s  (L%d → L%d)",
      a.from_cell, a.to_cell, names, a.from_line, a.to_line)
  end
  return lines
end

return M
