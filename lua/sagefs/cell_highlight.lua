-- sagefs/cell_highlight.lua — Dynamic visual feedback for eval region
-- Shows what region will be sent to SageFs when eval is triggered.
-- Integrates with eval state to show running/success/error feedback.
--
-- Highlight groups (all `default = true`, user-overridable):
--   SageFsCellBar         — sign column bar (neutral blue)
--   SageFsCellBarRunning  — sign bar during eval (yellow)
--   SageFsCellBarSuccess  — sign bar on success (green, fades after 1.5s)
--   SageFsCellBarError    — sign bar on error (red, fades after 3s)
--   SageFsCellNumber      — line number tint
--   SageFsCellGlow        — undercurl line decoration (neutral)
--   SageFsCellGlowRunning — undercurl during eval (yellow)
--   SageFsCellGlowSuccess — undercurl on success (green)
--   SageFsCellGlowError   — undercurl on error (red)
--   SageFsCellBound       — boundary markers (╭/╰/◆) and line counts
--   SageFsCellLineFull    — full-mode line background (adapts to transparency)
--   SageFsFlashFade1      — flash fade stage 1 (dim gold)
--   SageFsFlashFade2      — flash fade stage 2 (barely visible)

local cells = require("sagefs.cells")

local M = {}

M.ns = vim.api.nvim_create_namespace("sagefs_cell_highlight")

-- Style: "off" | "minimal" | "normal" | "full"
M.style = "normal"

-- Persistent debounce timer (one allocation, reused per CursorMoved)
local timer = vim.uv.new_timer()
local timer_open = true
local DEBOUNCE_MS = 50

-- Last rendered range (avoid redundant redraws)
local last = { buf = nil, start_line = nil, end_line = nil, hint = nil }

-- Eval state hint: bar/glow color reflects running/success/error
local hint_status = nil  -- nil | "running" | "success" | "error"
local hint_buf = nil     -- buffer the hint applies to
local hint_timer = vim.uv.new_timer()
local hint_timer_open = true

-- Hint-aware highlight lookup (eliminates parallel if-chains)
local HINT_HL = {
  running = { bar = "SageFsCellBarRunning", glow = "SageFsCellGlowRunning" },
  success = { bar = "SageFsCellBarSuccess", glow = "SageFsCellGlowSuccess" },
  error   = { bar = "SageFsCellBarError",   glow = "SageFsCellGlowError" },
}
local DEFAULT_HL = { bar = "SageFsCellBar", glow = "SageFsCellGlow" }

--- Resolve bar/glow highlights for current buffer
local function resolve_hl(buf)
  if hint_status and buf == hint_buf then
    return HINT_HL[hint_status] or DEFAULT_HL
  end
  return DEFAULT_HL
end

--- Safe extmark setter — silent in production, logs in debug mode
local function set_extmark(buf, line, col, opts)
  local ok, err = pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, line, col, opts)
  if not ok and vim.g.sagefs_debug then
    vim.notify("[SageFs debug] extmark failed: " .. tostring(err), vim.log.levels.WARN)
  end
end

--- Clear all cell highlight extmarks from a buffer
---@param buf number
local function clear(buf)
  pcall(vim.api.nvim_buf_clear_namespace, buf, M.ns, 0, -1)
  last = { buf = nil, start_line = nil, end_line = nil, hint = nil }
end

M.clear = clear

--- Build virt_text for a line based on style and position
local function build_virt_text(style, i, start_line, end_line, cell_lines)
  if style == "minimal" then return nil end

  local is_single = (start_line == end_line)
  local is_top = (i == start_line)
  local is_bottom = (i == end_line)

  if style == "normal" then
    if is_single then
      return { { " ◆ " .. cell_lines, "SageFsCellBound" } }
    elseif is_top then
      return { { " ╭", "SageFsCellBound" } }
    elseif is_bottom then
      return { { " ╰ " .. cell_lines, "SageFsCellBound" } }
    end
  elseif style == "full" then
    if is_top then
      return { { "┄ " .. cell_lines .. " lines", "SageFsCellBound" } }
    elseif is_bottom then
      return { { "┄ cell end", "SageFsCellBound" } }
    end
  end
  return nil
end

--- Line highlight group per style
local STYLE_LINE_HL = {
  minimal = nil,
  normal = "glow",  -- resolved dynamically from hint
  full = "SageFsCellLineFull",
}

--- Render cell boundary indicators
---@param buf number
---@param start_line number 1-indexed
---@param end_line number 1-indexed
local function render(buf, start_line, end_line)
  local cur_hint = (buf == hint_buf) and hint_status or nil

  -- Skip if identical to last render
  if buf == last.buf and start_line == last.start_line
    and end_line == last.end_line and cur_hint == last.hint then
    return
  end

  clear(buf)
  last = { buf = buf, start_line = start_line, end_line = end_line, hint = cur_hint }

  local style = M.style
  if style == "off" then return end

  local line_count = vim.api.nvim_buf_line_count(buf)
  local cell_lines = end_line - start_line + 1
  local hl = resolve_hl(buf)

  local line_hl
  local style_line = STYLE_LINE_HL[style]
  if style_line == "glow" then
    line_hl = hl.glow
  else
    line_hl = style_line  -- nil for minimal, literal group for full
  end

  for i = start_line, math.min(end_line, line_count) do
    local opts = {
      sign_text = "▎",
      sign_hl_group = hl.bar,
      number_hl_group = "SageFsCellNumber",
      priority = 5,
    }
    if line_hl then opts.line_hl_group = line_hl end

    local vt = build_virt_text(style, i, start_line, end_line, cell_lines)
    if vt then
      opts.virt_text = vt
      opts.virt_text_pos = "eol"
    end

    set_extmark(buf, i - 1, 0, opts)
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
  if not timer_open then return end

  -- Fast path: cursor still within cached cell, hint unchanged → skip
  local buf = vim.api.nvim_get_current_buf()
  local cur_hint = (buf == hint_buf) and hint_status or nil
  if buf == last.buf and last.start_line and cur_hint == last.hint then
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
    if ok and cursor[1] >= last.start_line and cursor[1] <= last.end_line then
      return
    end
  end

  timer:stop()
  timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(update_now))
end

--- Set eval state hint — changes bar/glow color for running/success/error
--- Called by init.lua after eval fires and when results return.
---@param buf number Buffer the hint applies to
---@param status string|nil "running"|"success"|"error"|nil
function M.set_eval_hint(buf, status)
  if hint_timer_open then hint_timer:stop() end
  hint_status = status
  hint_buf = buf

  -- Auto-clear success/error hints after a delay
  local fade_ms = status == "success" and 1500 or status == "error" and 3000 or nil
  if fade_ms and hint_timer_open then
    hint_timer:start(fade_ms, 0, vim.schedule_wrap(function()
      hint_status = nil
      hint_buf = nil
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

--- Release persistent timer handles (wire to VimLeavePre)
function M.teardown()
  if timer_open then
    timer:stop()
    timer:close()
    timer_open = false
  end
  if hint_timer_open then
    hint_timer:stop()
    hint_timer:close()
    hint_timer_open = false
  end
end

return M
