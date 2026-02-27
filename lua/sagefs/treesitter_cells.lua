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
--- Uses find_all_cells to get consistent boundaries, then finds
--- the cell containing the cursor line.
---@param buf number buffer handle
---@param cursor_line number 1-indexed line number
---@param cursor_col number|nil 0-indexed column (unused, kept for API compat)
---@return {start_line: number, end_line: number, node_type: string}|nil
function M.find_enclosing_cell(buf, cursor_line, cursor_col)
  local all = M.find_all_cells(buf)
  for _, cell in ipairs(all) do
    if cursor_line >= cell.start_line and cursor_line <= cell.end_line then
      return cell
    end
  end
  return nil
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

  --- Check if a source line (0-indexed) starts with 'with' keyword
  ---@param line_0 number 0-indexed line
  ---@return boolean
  local function line_starts_with_keyword(line_0, keyword)
    local line = vim.api.nvim_buf_get_lines(buf, line_0, line_0 + 1, false)[1]
    if not line then return false end
    return line:match("^%s*" .. keyword) ~= nil
  end

  --- Extract individual cells from a (possibly chained) declaration_expression
  --- inside an application_expression. In the `with` bug case, these chain:
  --- declaration_expression contains function_or_value_defn + application_expression.
  --- We extract each function_or_value_defn and recurse into nested app_exprs.
  ---@param node TSNode
  local function extract_from_app_expr(node)
    for j = 0, node:named_child_count() - 1 do
      local inner = node:named_child(j)
      local itype = inner:type()
      if itype == "declaration_expression" then
        -- A chained declaration_expression: extract the first binding
        local first_child = inner:named_child(0)
        if first_child then
          local ftype = first_child:type()
          if ftype == "function_or_value_defn" then
            local sr, _, er, _ = first_child:range()
            table.insert(cells, {
              id = #cells + 1,
              start_line = sr + 1,
              end_line = er + 1,
              node_type = "declaration_expression",
            })
          elseif M.cell_node_types[ftype] then
            local sr, _, er, _ = first_child:range()
            table.insert(cells, {
              id = #cells + 1,
              start_line = sr + 1,
              end_line = er + 1,
              node_type = ftype,
            })
          end
        end
        -- Recurse into the rest of the chained declaration
        extract_from_app_expr(inner)
      elseif itype == "application_expression" then
        -- Nested application_expression (e.g., second type...with block)
        -- Check if it contains an infix_expression that looks like a type+with
        local infix = nil
        for k = 0, inner:named_child_count() - 1 do
          local sub = inner:named_child(k)
          if sub:type() == "infix_expression" then
            local sr = sub:range()
            if line_starts_with_keyword(sr, "type") then
              -- This is a type definition parsed as infix_expression due to with bug.
              -- Find the full range including the with members.
              local _, _, er, _ = sub:range()
              -- Extend the previous type_definition cell if one exists, or create new
              table.insert(cells, {
                id = #cells + 1,
                start_line = sr + 1,
                end_line = er + 1,
                node_type = "type_definition",
              })
            end
            infix = sub
          end
        end
        -- Recurse for any declaration_expression children
        extract_from_app_expr(inner)
      end
    end
  end

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
      elseif ctype == "application_expression" then
        -- WORKAROUND: tree-sitter-fsharp parses `type Foo = { ... } with member ...`
        -- as type_definition + application_expression. The application_expression
        -- contains the `with` block merged with subsequent declarations.
        -- See: https://github.com/ionide/tree-sitter-fsharp (known grammar issue)
        local app_sr = child:range()

        -- If previous cell is a type_definition and this app_expr starts with 'with',
        -- extend the type_definition to include the with block
        if #cells > 0 and cells[#cells].node_type == "type_definition" then
          local first_inner = child:named_child(0)
          if first_inner and first_inner:type() == "infix_expression" then
            local _, _, infix_er, _ = first_inner:range()
            if line_starts_with_keyword(app_sr, "with") then
              -- Extend previous type_definition cell to include with members
              cells[#cells].end_line = infix_er + 1
            end
          end
        end

        -- Extract remaining cells from within the application_expression
        extract_from_app_expr(child)
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
