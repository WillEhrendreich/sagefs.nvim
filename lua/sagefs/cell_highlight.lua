-- sagefs/cell_highlight.lua — Dynamic visual feedback for eval region
-- Shows what region will be sent to SageFs when eval is triggered.
-- Integrates with eval state to show running/success/error feedback.

local cells = require("sagefs.cells")

local M = {}

local ns = vim.api.nvim_create_namespace("sagefs_cell_highlight")

-- Style: "off" | "minimal" | "normal" | "full"
M.style = "normal"

-- Persistent debounce timer (one allocation, reused per CursorMoved)
local timer = vim.uv.new_timer()
local DEBOUNCE_MS = 50

-- Last rendered range (avoid redundant redraws)
local last_buf = nil
local last_start = nil
local last_end = nil
local last_hint = nil

-- Eval state hint: bar/glow color reflects running/success/error
local hint_status = nil  -- nil | "running" | "success" | "error"
local hint_timer = vim.uv.new_timer()

--- Clear all cell highlight extmarks from a buffer
---@param buf number
local function clear(buf)
  pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
  last_buf = nil
  last_start = nil
  last_end = nil
  last_hint = nil
end

-- Public alias so BufLeave can route through cache invalidation
M.clear = clear

--- Pick the bar highlight group based on eval hint
local function bar_hl()
  if hint_status == "running" then return "SageFsCellBarRunning" end
  if hint_status == "success" then return "SageFsCellBarSuccess" end
  if hint_status == "error" then return "SageFsCellBarError" end
  return "SageFsCellBar"
end

--- Pick the glow highlight group based on eval hint
local function glow_hl()
  if hint_status == "running" then return "SageFsCellGlowRunning" end
  if hint_status == "success" then return "SageFsCellGlowSuccess" end
  if hint_status == "error" then return "SageFsCellGlowError" end
  return "SageFsCellGlow"
end

--- Render cell boundary indicators
---@param buf number
---@param start_line number 1-indexed
---@param end_line number 1-indexed
local function render(buf, start_line, end_line)
  -- Skip if identical to last render (including hint state)
  if buf == last_buf and start_line == last_start
    and end_line == last_end and hint_status == last_hint then
    return
  end

  clear(buf)
  last_buf = buf
  last_start = start_line
  last_end = end_line
  last_hint = hint_status

  local style = M.style
  if style == "off" then return end

  local line_count = vim.api.nvim_buf_line_count(buf)
  local cell_lines = end_line - start_line + 1
  local cur_bar = bar_hl()
  local cur_glow = glow_hl()

  if style == "minimal" then
    for i = start_line, math.min(end_line, line_count) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0, {
        sign_text = "▎",
        sign_hl_group = cur_bar,
        number_hl_group = "SageFsCellNumber",
        priority = 5,
      })
    end

  elseif style == "normal" then
    for i = start_line, math.min(end_line, line_count) do
      local opts = {
        sign_text = "▎",
        sign_hl_group = cur_bar,
        line_hl_group = cur_glow,
        number_hl_group = "SageFsCellNumber",
        priority = 5,
      }
      -- Merge boundary virt_text into the per-line extmark
      if start_line == end_line and i == start_line then
        opts.virt_text = { { " ◆ " .. cell_lines, "SageFsCellBound" } }
        opts.virt_text_pos = "eol"
      elseif i == start_line then
        opts.virt_text = { { " ╭", "SageFsCellBound" } }
        opts.virt_text_pos = "eol"
      elseif i == end_line then
        opts.virt_text = { { " ╰ " .. cell_lines, "SageFsCellBound" } }
        opts.virt_text_pos = "eol"
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0, opts)
    end

  elseif style == "full" then
    for i = start_line, math.min(end_line, line_count) do
      local opts = {
        sign_text = "▎",
        sign_hl_group = cur_bar,
        line_hl_group = "SageFsCellLineFull",
        number_hl_group = "SageFsCellNumber",
        priority = 5,
      }
      if i == start_line then
        opts.virt_text = {
          { "┄ " .. cell_lines .. " lines", "SageFsCellBound" },
        }
        opts.virt_text_pos = "eol"
      elseif i == end_line then
        opts.virt_text = { { "┄ cell end", "SageFsCellBound" } }
        opts.virt_text_pos = "eol"
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0, opts)
    end
  end
end

--- Synchronous find-and-render (shared by update debounce and set_style)
local function update_now()
  local buf = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return end

  local ft = vim.bo[buf].filetype
  if ft ~= "fsharp" then
    clear(buf)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local cell = cells.find_cell_auto(buf, lines, cursor[1])
  if cell then
    render(buf, cell.start_line, cell.end_line)
  else
    clear(buf)
  end
end

--- Update cell highlight at cursor position (debounced, with fast-path)
function M.update()
  if M.style == "off" then return end

  -- Fast path: cursor still within cached cell, hint unchanged → skip
  local buf = vim.api.nvim_get_current_buf()
  if buf == last_buf and last_start and hint_status == last_hint then
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
    if ok and cursor[1] >= last_start and cursor[1] <= last_end then
      return
    end
  end

  timer:stop()
  timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(update_now))
end

--- Set eval state hint — changes bar/glow color for running/success/error
--- Called by init.lua after eval fires and when results return.
---@param status string|nil "running"|"success"|"error"|nil
function M.set_eval_hint(status)
  hint_timer:stop()
  hint_status = status

  -- Auto-clear success/error hints after a delay
  if status == "success" then
    hint_timer:start(1500, 0, vim.schedule_wrap(function()
      hint_status = nil
      update_now()
    end))
  elseif status == "error" then
    hint_timer:start(3000, 0, vim.schedule_wrap(function()
      hint_status = nil
      update_now()
    end))
  end

  -- Re-render immediately with new hint
  update_now()
end

--- Set highlight style (synchronous — no flicker)
---@param style string "off"|"minimal"|"normal"|"full"
function M.set_style(style)
  if style == "off" or style == "minimal" or style == "normal" or style == "full" then
    M.style = style
    local buf = vim.api.nvim_get_current_buf()
    clear(buf)
    if style ~= "off" then
      update_now()
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

--- Setup highlight groups (call once at startup and on ColorScheme)
function M.setup_highlights()
  -- Neutral state
  vim.api.nvim_set_hl(0, "SageFsCellBar", { default = true, fg = "#5f87af" })
  vim.api.nvim_set_hl(0, "SageFsCellNumber", { default = true, fg = "#5f87af" })
  vim.api.nvim_set_hl(0, "SageFsCellGlow", { default = true, sp = "#5f87af", undercurl = true })
  vim.api.nvim_set_hl(0, "SageFsCellBound", { default = true, fg = "#5f6f8f", italic = true })

  -- Eval-state bar colors
  vim.api.nvim_set_hl(0, "SageFsCellBarRunning", { default = true, fg = "#f9e2af" })
  vim.api.nvim_set_hl(0, "SageFsCellBarSuccess", { default = true, fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "SageFsCellBarError", { default = true, fg = "#f38ba8" })

  -- Eval-state glow colors
  vim.api.nvim_set_hl(0, "SageFsCellGlowRunning", {
    default = true, sp = "#f9e2af", undercurl = true
  })
  vim.api.nvim_set_hl(0, "SageFsCellGlowSuccess", {
    default = true, sp = "#a6e3a1", undercurl = true
  })
  vim.api.nvim_set_hl(0, "SageFsCellGlowError", {
    default = true, sp = "#f38ba8", undercurl = true
  })

  -- Flash fade stages
  vim.api.nvim_set_hl(0, "SageFsFlashFade1", { default = true, fg = "#d4b872" })
  vim.api.nvim_set_hl(0, "SageFsFlashFade2", { default = true, fg = "#a89050" })

  -- Adapt "full" mode to transparent vs opaque terminal
  local normal_hl = vim.api.nvim_get_hl(0, { name = "Normal" })
  if normal_hl.bg then
    vim.api.nvim_set_hl(0, "SageFsCellLineFull", { default = true, bg = "#1e2430" })
  else
    vim.api.nvim_set_hl(0, "SageFsCellLineFull", {
      default = true, sp = "#5f87af", underdouble = true, bold = true
    })
  end
end

--- Release persistent timer handles
function M.teardown()
  timer:stop()
  timer:close()
  hint_timer:stop()
  hint_timer:close()
end

return M
