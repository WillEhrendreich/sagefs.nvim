-- sagefs/treesitter_cells.lua — Tree-sitter based cell detection for F#
-- Requires vim.treesitter — use nvim_harness for integration tests
local M = {}

--- Top-level AST node types that represent evaluable "cells"
M.cell_node_types = {
  declaration_expression = true,
  type_definition = true,
}

--- Container node types that hold cells (walk up stops here)
M.container_types = {
  file = true,
  namespace = true,
  module_defn = true,
  named_module = true,
}

--- Find the enclosing cell node for a given cursor position.
--- Walks up the AST from the node at cursor to find the nearest
--- declaration_expression, type_definition, or module_defn.
---@param buf number buffer handle
---@param cursor_line number 1-indexed line number
---@param cursor_col number|nil 0-indexed column (defaults to first non-whitespace)
---@return {start_line: number, end_line: number, node_type: string}|nil
function M.find_enclosing_cell(buf, cursor_line, cursor_col)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "fsharp")
  if not ok or not parser then return nil end

  local trees = parser:parse()
  if not trees or #trees == 0 then return nil end

  local root = trees[1]:root()
  if not root or root:child_count() == 0 then return nil end

  -- Default to first non-whitespace column to avoid landing in indent whitespace
  if not cursor_col then
    local line = vim.api.nvim_buf_get_lines(buf, cursor_line - 1, cursor_line, false)[1]
    if line then
      local indent = line:match("^(%s*)")
      cursor_col = indent and #indent or 0
    else
      cursor_col = 0
    end
  end

  local row = cursor_line - 1 -- convert to 0-indexed

  local node = vim.treesitter.get_node({ bufnr = buf, pos = { row, cursor_col } })
  if not node then return nil end

  -- Walk up to find the top-level enclosing cell node.
  -- Keep going past nested declaration_expressions to find the one
  -- whose parent is a container (module_defn, namespace, file).
  local best_cell = nil
  while node do
    local ntype = node:type()
    if M.cell_node_types[ntype] then
      local sr, _, er, _ = node:range()
      best_cell = {
        start_line = sr + 1, -- back to 1-indexed
        end_line = er + 1,
        node_type = ntype,
      }
    end
    -- Stop if we hit a container
    if M.container_types[ntype] then
      return best_cell
    end
    node = node:parent()
  end

  return best_cell
end

--- Find all top-level cells in a buffer using tree-sitter.
--- Returns cells in document order.
---@param buf number buffer handle
---@return {id: number, start_line: number, end_line: number, node_type: string}[]
function M.find_all_cells(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "fsharp")
  if not ok or not parser then return {} end

  local trees = parser:parse()
  if not trees or #trees == 0 then return {} end

  local root = trees[1]:root()
  if not root then return {} end

  local cells = {}

  -- Walk through the AST collecting cell nodes
  -- Structure: file → namespace → module_defn → declaration_expression
  -- or: file → declaration_expression (script files)
  local function collect_cells(parent_node)
    for i = 0, parent_node:named_child_count() - 1 do
      local child = parent_node:named_child(i)
      local ctype = child:type()
      if M.cell_node_types[ctype] then
        local sr, _, er, _ = child:range()
        table.insert(cells, {
          id = #cells + 1,
          start_line = sr + 1,
          end_line = er + 1,
          node_type = ctype,
        })
      elseif ctype == "namespace" or ctype == "module_defn" or ctype == "named_module" then
        collect_cells(child)
      end
    end
  end

  collect_cells(root)
  return cells
end

--- Extract open/import statements for FSI evaluation context.
--- Walks the tree-sitter AST to find all open statements before the cursor line.
--- Returns F# code to prepend to a cell submission so FSI has the right imports.
---@param buf number buffer handle
---@param cursor_line number 1-indexed line number
---@return string|nil context F# open statements to prepend, or nil if none
function M.get_module_context(buf, cursor_line)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "fsharp")
  if not ok or not parser then return nil end

  local trees = parser:parse()
  if not trees or #trees == 0 then return nil end

  local root = trees[1]:root()
  if not root then return nil end

  local opens = {}
  local row = cursor_line - 1

  local function collect_opens(node)
    for i = 0, node:named_child_count() - 1 do
      local child = node:named_child(i)
      local ctype = child:type()
      local sr = child:range()

      if sr <= row then
        if ctype == "import_decl" or ctype == "open_declaration" then
          local text = vim.treesitter.get_node_text(child, buf)
          if text then
            table.insert(opens, text)
          end
        elseif ctype == "namespace" or ctype == "module_defn" or ctype == "named_module" then
          collect_opens(child)
        end
      end
    end
  end

  collect_opens(root)

  if #opens == 0 then return nil end
  return table.concat(opens, "\n")
end

return M
