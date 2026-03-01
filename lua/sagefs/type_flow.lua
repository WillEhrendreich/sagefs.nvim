-- sagefs/type_flow.lua — Cross-cell type flow tracing
-- Pure Lua, no vim dependencies.

local M = {}
local format = require("sagefs.format")

--- Trace a single binding through the dependency graph.
---@param name string binding name
---@param graph table from depgraph.build_graph
---@param cell_outputs table<number, string>
---@return table|nil {origin, consumers, flow_path}
function M.trace_binding(name, graph, cell_outputs)
  -- Find the producer cell for this binding
  local origin_cell = nil
  local origin_type = nil
  for cell_id, analysis in pairs(graph.analyses) do
    for _, p in ipairs(analysis.produces) do
      if p == name then
        origin_cell = cell_id
        break
      end
    end
    if origin_cell then break end
  end
  if not origin_cell then return nil end

  -- Get type from output
  local output = cell_outputs[origin_cell] or ""
  for _, b in ipairs(format.parse_bindings(output)) do
    if b.name == name then
      origin_type = b.type_sig
      break
    end
  end

  -- Find consumer cells
  local consumers = {}
  for cell_id, analysis in pairs(graph.analyses) do
    if cell_id ~= origin_cell then
      for _, c in ipairs(analysis.consumes) do
        if c == name then
          consumers[#consumers + 1] = { cell_id = cell_id }
          break
        end
      end
    end
  end
  table.sort(consumers, function(a, b) return a.cell_id < b.cell_id end)

  return {
    name = name,
    origin = { cell_id = origin_cell, type_sig = origin_type or "unknown" },
    consumers = consumers,
  }
end

--- Compute all flows in the graph.
---@param graph table
---@param cell_outputs table<number, string>
---@return table[] flows
function M.all_flows(graph, cell_outputs)
  local seen = {}
  local flows = {}
  for _, analysis in pairs(graph.analyses) do
    for _, p in ipairs(analysis.produces) do
      if not seen[p] then
        seen[p] = true
        local flow = M.trace_binding(p, graph, cell_outputs)
        if flow and #flow.consumers > 0 then
          flows[#flows + 1] = flow
        end
      end
    end
  end
  table.sort(flows, function(a, b) return a.origin.cell_id < b.origin.cell_id end)
  return flows
end

--- Format a human-readable flow path.
---@param flow table
---@return string
function M.format_flow_path(flow)
  if not flow then return "" end
  local parts = { string.format("%s : %s (cell %d)", flow.name, flow.origin.type_sig, flow.origin.cell_id) }
  for _, c in ipairs(flow.consumers) do
    parts[#parts + 1] = string.format("→ cell %d", c.cell_id)
  end
  return table.concat(parts, " ")
end

--- Format flow annotations for virtual text placement.
---@param flows table[]
---@param cells_layout table<number, {start_line: number, end_line: number}>
---@return table[] {line, text, hl}
function M.format_flow_annotations(flows, cells_layout)
  local annotations = {}
  for _, flow in ipairs(flows) do
    -- Annotate at each consumer cell
    for _, consumer in ipairs(flow.consumers) do
      local layout = cells_layout[consumer.cell_id]
      if layout then
        annotations[#annotations + 1] = {
          line = layout.start_line,
          text = string.format("  ← %s : %s (cell %d)", flow.name, flow.origin.type_sig, flow.origin.cell_id),
          hl = "SageFsTypeFlow",
        }
      end
    end
  end
  table.sort(annotations, function(a, b) return a.line < b.line end)
  return annotations
end

return M
