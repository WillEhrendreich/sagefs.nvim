-- sagefs/cells.lua — Cell boundary detection and parsing for .fsx files
-- Pure Lua, no vim API dependencies — fully testable with busted
local M = {}

--- Check if a line is a cell boundary (ends with ;; outside strings/comments)
---@param line string
---@return boolean
function M.is_boundary_line(line)
  if not line or line == "" then return false end

  -- Strip trailing whitespace
  local trimmed = line:match("^(.-)%s*$")

  -- Must end with ;;
  if not trimmed:match(";;$") then return false end

  -- Check for ;; in middle of expression (something after ;;)
  -- Already handled: trimmed ends with ;; so nothing after

  -- Reject if ;; is inside a string literal
  -- Simple heuristic: count unescaped quotes before the ;;
  local code_before_terminator = trimmed:sub(1, #trimmed - 2)
  local in_string = false
  local i = 1
  while i <= #code_before_terminator do
    local c = code_before_terminator:sub(i, i)
    if c == '"' then
      -- Check for triple-quote
      if code_before_terminator:sub(i, i + 2) == '"""' then
        -- Find closing triple-quote
        local close = code_before_terminator:find('"""', i + 3, true)
        if close then
          i = close + 3
        else
          -- Unclosed triple-quote — ;; is inside string
          return false
        end
      else
        in_string = not in_string
      end
    end
    i = i + 1
  end
  if in_string then return false end

  -- Reject if line is a comment
  local stripped = trimmed:match("^%s*(.-)$")
  if stripped:match("^//") then return false end

  return true
end

--- Find all cell boundary line numbers in a buffer
---@param lines string[]
---@return number[]
function M.find_boundaries(lines)
  local boundaries = {}
  for i, line in ipairs(lines) do
    if M.is_boundary_line(line) then
      table.insert(boundaries, i)
    end
  end
  return boundaries
end

--- Find the cell containing the given cursor line (1-indexed)
---@param lines string[]
---@param cursor_line number
---@return {start_line: number, end_line: number, text: string}|nil
function M.find_cell(lines, cursor_line)
  if #lines == 0 then return nil end
  if cursor_line < 1 or cursor_line > #lines then return nil end

  local boundaries = M.find_boundaries(lines)

  -- Find which cell the cursor is in
  local cell_start = 1
  local cell_end = #lines

  if #boundaries == 0 then
    -- Entire buffer is one cell
    cell_start = 1
    cell_end = #lines
  else
    -- Find the boundary at or after cursor (this cell's end)
    -- Find the boundary before cursor (previous cell's end = this cell's start - 1)
    local prev_boundary = 0
    local next_boundary = nil

    for _, b in ipairs(boundaries) do
      if b >= cursor_line and not next_boundary then
        next_boundary = b
      end
      if b < cursor_line then
        prev_boundary = b
      end
    end

    cell_start = prev_boundary + 1
    cell_end = next_boundary or #lines
  end

  -- Build cell text
  local cell_lines = {}
  for i = cell_start, cell_end do
    table.insert(cell_lines, lines[i])
  end

  return {
    start_line = cell_start,
    end_line = cell_end,
    text = table.concat(cell_lines, "\n"),
  }
end

--- Find all cells in a buffer
---@param lines string[]
---@return {id: number, start_line: number, end_line: number, text: string}[]
function M.find_all_cells(lines)
  if #lines == 0 then return {} end

  local boundaries = M.find_boundaries(lines)
  local cells = {}
  local cell_start = 1

  for _, b in ipairs(boundaries) do
    local cell_lines = {}
    for i = cell_start, b do
      table.insert(cell_lines, lines[i])
    end
    table.insert(cells, {
      id = #cells + 1,
      start_line = cell_start,
      end_line = b,
      text = table.concat(cell_lines, "\n"),
    })
    cell_start = b + 1
  end

  -- Trailing unterminated cell
  if cell_start <= #lines then
    local cell_lines = {}
    for i = cell_start, #lines do
      table.insert(cell_lines, lines[i])
    end
    table.insert(cells, {
      id = #cells + 1,
      start_line = cell_start,
      end_line = #lines,
      text = table.concat(cell_lines, "\n"),
    })
  end

  return cells
end

--- Find the start line of the next cell after the cursor's current cell.
--- Returns nil if cursor is in the last cell.
---@param lines string[]
---@param cursor_line number 1-indexed
---@return number|nil 1-indexed start line of next cell
function M.find_next_cell_start(lines, cursor_line)
  if #lines == 0 then return nil end
  local cell = M.find_cell(lines, cursor_line)
  if not cell then return nil end
  local next_start = cell.end_line + 1
  if next_start > #lines then return nil end
  return next_start
end

--- Prepare code for submission to /exec
---@param code string
---@return string|nil
function M.prepare_code(code)
  if not code then return nil end

  -- Trim leading blank lines
  code = code:match("^%s*\n?(.*)")
  if not code then return nil end

  -- Trim trailing whitespace and blank lines
  code = code:match("^(.-)[%s]*$")
  if not code or code == "" then return nil end

  -- Append ;; if not already present
  if not code:match(";;$") then
    code = code .. ";;"
  end

  return code
end

--- Find cell boundaries from treesitter-parsed nodes
--- Takes pre-extracted boundary nodes with position and context
---@param nodes table[] — { row, col, text, in_string?, in_comment? }
---@return number[] — 1-indexed line numbers of boundaries
function M.find_boundaries_treesitter(nodes)
  local boundaries = {}
  for _, node in ipairs(nodes) do
    if not node.in_string and not node.in_comment then
      table.insert(boundaries, node.row + 1) -- convert 0-indexed to 1-indexed
    end
  end
  return boundaries
end

--- Check if a buffer uses manual cell delimiters (any valid ;; boundary exists)
---@param lines string[]
---@return boolean
function M.has_manual_cells(lines)
  return #M.find_boundaries(lines) > 0
end

--- Determine the cell detection mode: "manual" if ;; delimiters exist, "inferred" otherwise
---@param lines string[]
---@return "manual"|"inferred"
function M.cell_mode(lines)
  return M.has_manual_cells(lines) and "manual" or "inferred"
end

--- Find cell using auto-detection: manual mode (;;) or inferred (tree-sitter).
--- This is the primary entry point for eval_cell — it picks the right strategy.
---@param buf number buffer handle
---@param lines string[] buffer lines
---@param cursor_line number 1-indexed
---@return {start_line: number, end_line: number, text: string}|nil
function M.find_cell_auto(buf, lines, cursor_line)
  if #lines == 0 then return nil end
  if cursor_line < 1 or cursor_line > #lines then return nil end

  local mode = M.cell_mode(lines)
  if mode == "manual" then
    return M.find_cell(lines, cursor_line)
  end

  -- Inferred mode: use tree-sitter
  local ok, ts_cells = pcall(require, "sagefs.treesitter_cells")
  if not ok then
    -- Fallback: whole file as one cell (same as original no-;; behavior)
    return M.find_cell(lines, cursor_line)
  end

  local cell_info = ts_cells.find_enclosing_cell(buf, cursor_line)
  if not cell_info then
    -- Cursor on a non-cell line (comment, blank, module declaration)
    -- Fallback: whole file
    return M.find_cell(lines, cursor_line)
  end

  -- Build text from the detected range
  local cell_lines = {}
  for i = cell_info.start_line, cell_info.end_line do
    table.insert(cell_lines, lines[i])
  end

  return {
    start_line = cell_info.start_line,
    end_line = cell_info.end_line,
    text = table.concat(cell_lines, "\n"),
  }
end

--- Auto-select find_all_cells: manual uses ;;-based, inferred uses tree-sitter.
---@param buf number buffer handle
---@param lines string[] buffer lines
---@return {id: number, start_line: number, end_line: number, text: string}[]
function M.find_all_cells_auto(buf, lines)
  if #lines == 0 then return {} end

  local mode = M.cell_mode(lines)
  if mode == "manual" then
    return M.find_all_cells(lines)
  end

  local ok, ts_cells = pcall(require, "sagefs.treesitter_cells")
  if not ok then
    return M.find_all_cells(lines)
  end

  local ts_results = ts_cells.find_all_cells(buf)
  local result = {}
  for _, info in ipairs(ts_results) do
    local cell_lines = {}
    for i = info.start_line, info.end_line do
      table.insert(cell_lines, lines[i] or "")
    end
    table.insert(result, {
      id = info.id,
      start_line = info.start_line,
      end_line = info.end_line,
      text = table.concat(cell_lines, "\n"),
    })
  end
  return result
end

--- Get module context (opens) for a cell in inferred mode.
--- Returns nil in manual mode or if tree-sitter unavailable.
---@param buf number buffer handle
---@param lines string[] buffer lines
---@param cursor_line number 1-indexed
---@return string|nil opens F# open statements to prepend
function M.get_module_context(buf, lines, cursor_line)
  local mode = M.cell_mode(lines)
  if mode == "manual" then return nil end

  local ok, ts_cells = pcall(require, "sagefs.treesitter_cells")
  if not ok then return nil end

  return ts_cells.get_module_context(buf, cursor_line)
end

return M
