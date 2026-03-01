-- sagefs/notebook.lua — Literate .fsx notebook export/import
-- Pure Lua, no vim dependencies.

local M = {}

--- Export full session as rich .fsx notebook.
---@param cells_data table[] {source, output, duration_ms, bindings, status}
---@param metadata table {project?, timestamp?}
---@return string fsx_content
function M.export_notebook(cells_data, metadata)
  local parts = {}
  local ts = metadata.timestamp or os.date("%Y-%m-%dT%H:%M:%S")
  parts[#parts + 1] = string.format(
    '(* @sagefs-notebook: { "project": %q, "timestamp": %q, "cells": %d } *)',
    metadata.project or "", ts, #cells_data
  )
  parts[#parts + 1] = ""
  parts[#parts + 1] = M.summary_block(cells_data)
  parts[#parts + 1] = ""
  for i, cell in ipairs(cells_data) do
    local meta_parts = {}
    if cell.duration_ms then meta_parts[#meta_parts + 1] = string.format("duration_ms=%d", cell.duration_ms) end
    if cell.status then meta_parts[#meta_parts + 1] = "status=" .. cell.status end
    if cell.bindings and #cell.bindings > 0 then
      local bnames = {}
      for _, b in ipairs(cell.bindings) do bnames[#bnames + 1] = b.name .. ":" .. b.type_sig end
      meta_parts[#meta_parts + 1] = "bindings=[" .. table.concat(bnames, ",") .. "]"
    end
    parts[#parts + 1] = string.format("(* @sagefs-cell[%d]: %s *)", i, table.concat(meta_parts, ", "))
    parts[#parts + 1] = cell.source
    if cell.output and cell.output ~= "" then
      parts[#parts + 1] = "(* Output:"
      for line in (cell.output .. "\n"):gmatch("([^\n]*)\n") do
        parts[#parts + 1] = "   " .. line
      end
      parts[#parts + 1] = "*)"
    end
    parts[#parts + 1] = ""
  end
  return table.concat(parts, "\n")
end

--- Parse a rich .fsx notebook back into cells + metadata.
---@param fsx_content string
---@return table[] cells, table metadata
function M.parse_notebook(fsx_content)
  local cells_data = {}
  local metadata = {}
  -- Parse header
  local header = fsx_content:match("%(%* @sagefs%-notebook: ({.-}) %*%)")
  if header then
    metadata.project = header:match('"project"%s*:%s*"(.-)"') or ""
    metadata.timestamp = header:match('"timestamp"%s*:%s*"(.-)"') or ""
  end
  -- Parse cells: find @sagefs-cell markers and extract source + optional output
  local pos = 1
  while true do
    local cell_start, cell_end, meta_line = fsx_content:find(
      "%(%* @sagefs%-cell%[%d+%]: (.-) %*%)", pos
    )
    if not cell_start then break end
    local after = cell_end + 1
    -- Skip newline after cell marker
    if fsx_content:sub(after, after) == "\n" then after = after + 1 end
    -- Find source: everything until (* Output: or next (* @sagefs-cell or end
    local source_end = fsx_content:find("\n%(%* Output:", after)
      or fsx_content:find("\n%(%* @sagefs%-cell", after)
      or (#fsx_content + 1)
    local source = fsx_content:sub(after, source_end - 1):match("^(.-)%s*$")
    -- Try to find output block
    local output = nil
    local out_start = fsx_content:find("%(%* Output:\n", cell_end)
    local next_cell = fsx_content:find("%(%* @sagefs%-cell", cell_end + 1)
    if out_start and (not next_cell or out_start < next_cell) then
      local out_end = fsx_content:find("%*%)", out_start + 10)
      if out_end then
        local raw = fsx_content:sub(out_start + 11, out_end - 1)
        -- Strip leading whitespace from each line
        local cleaned = {}
        for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
          cleaned[#cleaned + 1] = line:match("^%s%s%s(.*)") or line
        end
        output = table.concat(cleaned, "\n"):match("^%s*(.-)%s*$")
      end
    end
    local cell = { source = source, output = output }
    cell.duration_ms = tonumber(meta_line:match("duration_ms=(%d+)"))
    cell.status = meta_line:match("status=(%w+)")
    cells_data[#cells_data + 1] = cell
    pos = cell_end + 1
  end
  return cells_data, metadata
end

--- Generate a summary header block.
---@param cells_data table[]
---@return string
function M.summary_block(cells_data)
  local total_ms, errors = 0, 0
  for _, c in ipairs(cells_data) do
    total_ms = total_ms + (c.duration_ms or 0)
    if c.status == "error" then errors = errors + 1 end
  end
  local text = string.format("(* Summary: %d cells, %dms total", #cells_data, total_ms)
  if errors > 0 then
    text = text .. string.format(", %d error%s", errors, errors > 1 and "s" or "")
  end
  text = text .. " *)"
  return text
end

return M
