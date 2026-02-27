-- sagefs/cell_highlight.lua — Dynamic visual feedback for eval region
-- Shows what region will be sent to SageFs when eval is triggered.

local cells = require("sagefs.cells")

local M = {}

local ns = vim.api.nvim_create_namespace("sagefs_cell_highlight")

-- Style: "off" | "minimal" | "normal" | "full"
M.style = "normal"

-- Debounce timer handle
local timer = nil
local DEBOUNCE_MS = 50

-- Last rendered range (avoid redundant redraws)
local last_buf = nil
local last_start = nil
local last_end = nil

--- Clear all cell highlight extmarks from a buffer
---@param buf number
local function clear(buf)
  pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
  last_buf = nil
  last_start = nil
  last_end = nil
end

--- Render cell boundary indicators
---@param buf number
---@param start_line number 1-indexed
---@param end_line number 1-indexed
local function render(buf, start_line, end_line)
  -- Skip if same as last render
  if buf == last_buf and start_line == last_start and end_line == last_end then
    return
  end

  clear(buf)
  last_buf = buf
  last_start = start_line
  last_end = end_line

  local style = M.style
  if style == "off" then return end

  local line_count = vim.api.nvim_buf_line_count(buf)

  if style == "minimal" then
    -- Left bar sign column indicator on each line
    for i = start_line, math.min(end_line, line_count) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0, {
        sign_text = "▎",
        sign_hl_group = "SageFsCellBar",
        priority = 5,
      })
    end

  elseif style == "normal" then
    -- Left bar + subtle line highlight
    for i = start_line, math.min(end_line, line_count) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0, {
        sign_text = "▎",
        sign_hl_group = "SageFsCellBar",
        line_hl_group = "SageFsCellLine",
        priority = 5,
      })
    end

  elseif style == "full" then
    -- Full line highlight + bar + top/bottom virtual text markers
    for i = start_line, math.min(end_line, line_count) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0, {
        sign_text = "▎",
        sign_hl_group = "SageFsCellBar",
        line_hl_group = "SageFsCellLineFull",
        priority = 5,
      })
    end
    -- Top boundary marker
    if start_line >= 1 and start_line <= line_count then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, start_line - 1, 0, {
        virt_text = { { "┄ cell start", "SageFsCellBound" } },
        virt_text_pos = "eol",
        priority = 5,
      })
    end
    -- Bottom boundary marker
    if end_line >= 1 and end_line <= line_count then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, end_line - 1, 0, {
        virt_text = { { "┄ cell end", "SageFsCellBound" } },
        virt_text_pos = "eol",
        priority = 5,
      })
    end
  end
end

--- Update cell highlight at cursor position (debounced)
function M.update()
  if M.style == "off" then return end

  if timer then
    timer:stop()
  end

  timer = vim.defer_fn(function()
    local buf = vim.api.nvim_get_current_buf()
    local ft = vim.bo[buf].filetype
    if ft ~= "fsharp" then
      clear(buf)
      return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local cursor_line = cursor[1]
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local mode = cells.cell_mode(lines)

    local cell = nil
    if mode == "manual" then
      cell = cells.find_cell(lines, cursor_line)
    else
      -- Inferred: use tree-sitter directly, no whole-file fallback
      local ok, ts_cells = pcall(require, "sagefs.treesitter_cells")
      if ok then
        local info = ts_cells.find_enclosing_cell(buf, cursor_line)
        if info then
          cell = { start_line = info.start_line, end_line = info.end_line }
        end
      end
    end

    if cell then
      render(buf, cell.start_line, cell.end_line)
    else
      clear(buf)
    end
  end, DEBOUNCE_MS)
end

--- Set highlight style
---@param style string "off"|"minimal"|"normal"|"full"
function M.set_style(style)
  if style == "off" or style == "minimal" or style == "normal" or style == "full" then
    M.style = style
    -- Re-render immediately
    local buf = vim.api.nvim_get_current_buf()
    clear(buf)
    if style ~= "off" then
      M.update()
    end
  end
end

--- Cycle through styles: off → minimal → normal → full → off
function M.cycle_style()
  local order = { "off", "minimal", "normal", "full" }
  local current_idx = 1
  for i, s in ipairs(order) do
    if s == M.style then current_idx = i; break end
  end
  local next_idx = (current_idx % #order) + 1
  M.set_style(order[next_idx])
  vim.notify("[SageFs] Cell highlight: " .. M.style, vim.log.levels.INFO)
end

--- Setup highlight groups (call once at startup)
function M.setup_highlights()
  -- Subtle left bar in blue/cyan
  vim.api.nvim_set_hl(0, "SageFsCellBar", { default = true, fg = "#5f87af" })
  -- Very subtle line background for normal mode
  vim.api.nvim_set_hl(0, "SageFsCellLine", { default = true, bg = "#1a1d23" })
  -- Stronger line background for full mode
  vim.api.nvim_set_hl(0, "SageFsCellLineFull", { default = true, bg = "#1e2430" })
  -- Boundary marker text
  vim.api.nvim_set_hl(0, "SageFsCellBound", { default = true, fg = "#5f6f8f", italic = true })
end

return M
