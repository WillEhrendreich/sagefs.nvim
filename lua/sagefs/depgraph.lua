-- sagefs/depgraph.lua — Reactive cell dependency graph
-- Pure Lua, no vim dependencies.

local M = {}
local format = require("sagefs.format")

local IDENT = "[%a_][%w_']*"

local KEYWORDS = {
  ["let"]=1,["in"]=1,["if"]=1,["then"]=1,["else"]=1,
  ["match"]=1,["with"]=1,["fun"]=1,["function"]=1,["type"]=1,["module"]=1,
  ["open"]=1,["do"]=1,["for"]=1,["while"]=1,["true"]=1,["false"]=1,
  ["not"]=1,["and"]=1,["or"]=1,["mutable"]=1,["rec"]=1,["val"]=1,
  ["member"]=1,["this"]=1,["self"]=1,["base"]=1,["static"]=1,
  ["override"]=1,["abstract"]=1,["private"]=1,["public"]=1,["internal"]=1,
  ["printfn"]=1,["sprintf"]=1,["printf"]=1,["string"]=1,["int"]=1,
  ["float"]=1,["bool"]=1,["unit"]=1,["of"]=1,["as"]=1,["when"]=1,
  ["yield"]=1,["return"]=1,["use"]=1,["try"]=1,["finally"]=1,
  ["raise"]=1,["failwith"]=1,["new"]=1,["null"]=1,["default"]=1,
}

--- Analyze a cell's produces/consumes sets.
---@param cell_source string
---@param cell_output string
---@return table {produces: string[], consumes: string[]}
function M.analyze_cell(cell_source, cell_output)
  local produces = {}
  for _, b in ipairs(format.parse_bindings(cell_output or "")) do
    produces[#produces + 1] = b.name
  end
  local produces_set = {}
  for _, p in ipairs(produces) do produces_set[p] = true end
  -- Scan source for identifiers (heuristic)
  local consumes_set = {}
  for ident in cell_source:gmatch(IDENT) do
    if not KEYWORDS[ident] and not produces_set[ident] then
      consumes_set[ident] = true
    end
  end
  local consumes = {}
  for id in pairs(consumes_set) do consumes[#consumes + 1] = id end
  table.sort(consumes)
  return { produces = produces, consumes = consumes }
end

--- Build dependency graph from cell data.
---@param cells_data table[] {id, source, output}
---@return table {edges, adj, analyses}
function M.build_graph(cells_data)
  local producer = {}
  local analyses = {}
  for _, c in ipairs(cells_data) do
    local a = M.analyze_cell(c.source, c.output)
    analyses[c.id] = a
    for _, name in ipairs(a.produces) do
      producer[name] = c.id
    end
  end
  local edges = {}
  local adj = {}
  for _, c in ipairs(cells_data) do
    local a = analyses[c.id]
    for _, name in ipairs(a.consumes) do
      local from = producer[name]
      if from and from ~= c.id then
        edges[#edges + 1] = { from = from, to = c.id }
        if not adj[from] then adj[from] = {} end
        adj[from][c.id] = true
      end
    end
  end
  return { edges = edges, adj = adj, analyses = analyses }
end

--- Given a re-evaluated cell, return all transitively stale cells.
---@param graph table from build_graph
---@param changed_cell number
---@return number[] sorted stale cell IDs
function M.transitive_stale(graph, changed_cell)
  local visited = {}
  local queue = { changed_cell }
  visited[changed_cell] = true
  local result = {}
  while #queue > 0 do
    local current = table.remove(queue, 1)
    local downstream = graph.adj[current]
    if downstream then
      for cid in pairs(downstream) do
        if not visited[cid] then
          visited[cid] = true
          result[#result + 1] = cid
          queue[#queue + 1] = cid
        end
      end
    end
  end
  table.sort(result)
  return result
end

return M
