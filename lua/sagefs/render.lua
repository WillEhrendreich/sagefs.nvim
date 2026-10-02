-- sagefs/render.lua — Extmark rendering, highlights, and floating windows
-- Owns the visual output layer. No state mutation — reads state, writes extmarks.

local cells = require("sagefs.cells")
local format = require("sagefs.format")
local model = require("sagefs.model")
local ann_module = require("sagefs.annotations")
local placement = require("sagefs.placement")

local M = {}

local ns = nil

function M.get_namespace()
  if not ns then
    ns = vim.api.nvim_create_namespace("sagefs")
  end
  return ns
end

-- ─── Highlight Setup ──────────────────────────────────────────────────────────

function M.setup_highlights(hl_config)
  vim.api.nvim_set_hl(0, "SageFsSuccess", hl_config.success)
  vim.api.nvim_set_hl(0, "SageFsError", hl_config.error)
  vim.api.nvim_set_hl(0, "SageFsOutput", hl_config.output)
  vim.api.nvim_set_hl(0, "SageFsRunning", hl_config.running)
  vim.api.nvim_set_hl(0, "SageFsStale", hl_config.stale)
  vim.api.nvim_set_hl(0, "SageFsCellBorder", { default = true, fg = "#585b70" })
  -- Testing highlights
  vim.api.nvim_set_hl(0, "SageFsTestPassed", { default = true, fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "SageFsTestFailed", { default = true, fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "SageFsTestRunning", { default = true, fg = "#f9e2af" })
  vim.api.nvim_set_hl(0, "SageFsTestStale", { default = true, fg = "#fab387" })
  vim.api.nvim_set_hl(0, "SageFsTestDetected", { default = true, fg = "#585b70" })
  vim.api.nvim_set_hl(0, "SageFsTestDisabled", { default = true, fg = "#585b70" })
  vim.api.nvim_set_hl(0, "SageFsTestSkipped", { default = true, fg = "#585b70" })
  -- Coverage highlights (covered = quiet, uncovered = loud)
  vim.api.nvim_set_hl(0, "SageFsCovered", { default = true, fg = "#587358" })
  vim.api.nvim_set_hl(0, "SageFsUncovered", { default = true, fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "SageFsCovNotCovered", { default = true, fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "SageFsCovPending", { default = true, fg = "#45475a" })
  vim.api.nvim_set_hl(0, "SageFsCovFailing", { default = true, fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "SageFsCovPartial", { default = true, fg = "#fab387" })
  -- Branch coverage highlights (shape + color for accessibility)
  vim.api.nvim_set_hl(0, "SageFsBranchFull", { default = true, fg = "#a6e3a1" })    -- green ▐
  vim.api.nvim_set_hl(0, "SageFsBranchPartial", { default = true, fg = "#f9e2af" }) -- yellow ◐
  vim.api.nvim_set_hl(0, "SageFsBranchNone", { default = true, fg = "#f38ba8" })    -- red ▌
  -- CodeLens highlights
  vim.api.nvim_set_hl(0, "SageFsCodeLensPassed", { default = true, fg = "#a6e3a1", italic = true })
  vim.api.nvim_set_hl(0, "SageFsCodeLensFailed", { default = true, fg = "#f38ba8", italic = true })
  vim.api.nvim_set_hl(0, "SageFsCodeLensRunning", { default = true, fg = "#f9e2af", italic = true })
  vim.api.nvim_set_hl(0, "SageFsCodeLensStale", { default = true, fg = "#fab387", italic = true })
  vim.api.nvim_set_hl(0, "SageFsCodeLensDetected", { default = true, fg = "#585b70", italic = true })
  -- Dependency visualization highlights
  vim.api.nvim_set_hl(0, "SageFsDepSource", { default = true, fg = "#89b4fa" })
  vim.api.nvim_set_hl(0, "SageFsDepTarget", { default = true, fg = "#cba6f7" })
  vim.api.nvim_set_hl(0, "SageFsDepFlow", { default = true, fg = "#6c7086", italic = true })
  -- Inline failure highlights
  vim.api.nvim_set_hl(0, "SageFsInlineFailure", { default = true, fg = "#f38ba8", italic = true })
end

-- ─── Extmark Rendering ────────────────────────────────────────────────────────

function M.clear_extmarks(buf)
  local ns_id = M.get_namespace()
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
end

--- The window showing `buf` and how much of it we can draw into. A buffer
--- that is not on screen gets an unclipped stand-in, so placement is the old
--- "at the cell's end" until a window shows it (WinScrolled/BufEnter re-render).
---@param buf number
---@return table { win, top, bot, rows, width, rows_through }
local function geometry(buf)
  local win = vim.fn.bufwinid(buf)
  local line_count = vim.api.nvim_buf_line_count(buf)
  if win == -1 then
    return { win = nil, top = 1, bot = line_count, rows = line_count + 1000, width = math.max(vim.o.columns, 20) }
  end
  local info = vim.fn.getwininfo(win)[1]
  local g = {
    win = win,
    top = vim.fn.line("w0", win),
    bot = vim.fn.line("w$", win),
    rows = info.height,
    width = math.max(info.width - info.textoff, 1),
  }
  if vim.api.nvim_win_text_height then
    -- Screen rows used by top..line, counting wraps and the virtual lines
    -- already drawn between them (earlier results, codelens).
    -- nvim_win_text_height counts the "filler" ABOVE its first row, and
    -- virtual lines hung below line N are that filler for line N+1: for the
    -- window's top line those belong to a line that is scrolled off, so they
    -- are not on screen. Take the top line's own rows by themselves and the
    -- rest of the range from the next line down.
    local function height(from_row, to_row)
      local ok, r = pcall(vim.api.nvim_win_text_height, win, { start_row = from_row, end_row = to_row })
      if ok and type(r) == "table" and r.all then return r end
      return nil
    end
    local top_rows
    do
      local r = height(g.top - 1, g.top - 1)
      top_rows = r and math.max(r.all - (r.fill or 0), 1) or 1
    end
    g.rows_through = function(line)
      if line <= g.top then return top_rows end
      local r = height(g.top, line - 1)
      if r then return top_rows + r.all end
      return line - g.top + 1
    end
  end
  return g
end

--- The cell state this buffer should draw: another buffer's cell with the same
--- id is not ours (cell ids are per buffer, the model is shared).
local function cell_view(buf, cell_id, state)
  local cs = model.get_cell_state(state, cell_id)
  if cs.buf and cs.buf ~= buf then return { status = "idle" } end
  return cs
end

--- Draw one cell's gutter sign, inline summary and virtual lines.
---@param buf number
---@param cell { id: number, start_line: number, end_line: number }
---@param cs table the cell state from the model
---@param opts table build_render_options result (non-nil)
---@param geom table geometry(buf)
function M.draw_result(buf, cell, cs, opts, geom)
  local ns_id = M.get_namespace()
  local limits = require("sagefs.config")
  local line_count = vim.api.nvim_buf_line_count(buf)

  local anchor = cs.anchor_line
  if anchor and (anchor < cell.start_line or anchor > cell.end_line) then anchor = nil end

  local function place(height)
    return placement.place({
      cell_start = cell.start_line,
      cell_end = math.min(cell.end_line, line_count),
      anchor = anchor,
      top = geom.top,
      bot = geom.bot,
      rows = geom.rows,
      height = height,
      max_lines = limits.RESULT_MAX_LINES,
      rows_through = geom.rows_through,
    })
  end

  --- Room for inline text after the code on `line`.
  local function inline_budget(line)
    local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
    local used = vim.fn.strdisplaywidth(text) % math.max(geom.width, 1)
    return geom.width - used - 2
  end

  local inline, lines, p
  if cs.status == "running" then
    -- No result yet: a one-row status on the cell, from real model state.
    p = place(0)
    if cs.pending_text and cs.pending_text ~= "" then
      inline = format.fit_inline("⏳ " .. cs.pending_text, inline_budget(p.line))
    end
  else
    local result = opts.result
    local raw = result.ok and (result.output or "") or (result.error or "error")
    local summary = opts.inline.text
    if raw == "" and result.ok then summary = "→ (no output)" end
    lines = format.wrap_lines(format.result_lines(result), geom.width)
    p = place(#lines)
    inline = format.fit_inline(summary, inline_budget(p.line))
    -- A one-line result that fits inline is just inline: no duplicate row.
    if format.is_single_line(raw) and raw ~= "" and inline == summary then
      p = place(0)
      lines = nil
      inline = format.fit_inline(summary, inline_budget(p.line)) or inline
    end
  end

  local mark = {
    id = cell.id * 1000,
    virt_text = inline and { { inline, cs.status == "running" and "SageFsRunning" or opts.inline.hl } } or nil,
    virt_text_pos = "eol",
    sign_text = opts.sign.text,
    sign_hl_group = opts.sign.hl,
    priority = 100,
  }
  pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, p.line - 1, 0, mark)

  if lines and (p.shown > 0 or p.footer) then
    local virt_lines = {}
    for i = 1, p.shown do
      virt_lines[#virt_lines + 1] = { { lines[i].text, lines[i].hl } }
    end
    if p.footer then
      virt_lines[#virt_lines + 1] = { { format.expand_footer(p.hidden, limits.EXPAND_RESULT_KEY), "SageFsOutput" } }
    end
    pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, p.line - 1, 0, {
      id = cell.id * 1000 + 1,
      virt_lines = virt_lines,
      virt_lines_above = false,
    })
  end
end

--- Render one cell's result (kept for callers that draw a single cell).
---@param buf number
---@param cell { id: number, start_line: number, end_line: number }
---@param state table model
---@param geom table|nil
---@return table|nil the render options, nil for an idle cell
function M.render_cell(buf, cell, state, geom)
  local cs = cell_view(buf, cell.id, state)
  local opts = format.build_render_options(cs, cell.id)
  if not opts then return nil end
  M.draw_result(buf, cell, cs, opts, geom or geometry(buf))
  return opts
end

function M.render_all(buf, state)
  local ns_id = M.get_namespace()
  M.clear_extmarks(buf)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local all_cells = cells.find_all_cells_auto(buf, lines)
  local geom = geometry(buf)

  for _, cell in ipairs(all_cells) do
    local cs = cell_view(buf, cell.id, state)
    local opts = format.build_render_options(cs, cell.id)
    local codelens =
      opts and opts.codelens
      or (cs.status == "idle" and { text = "▶ Eval", hl = "SageFsCodeLensDetected" })

    -- The codelens goes in first so its row is counted when the result below
    -- it is placed against the window.
    if codelens then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, cell.start_line - 1, 0, {
        id = cell.id * 1000 + 2,
        virt_lines = { { { codelens.text, codelens.hl or "SageFsCodeLensDetected" } } },
        virt_lines_above = true,
      })
    end
    if opts then M.draw_result(buf, cell, cs, opts, geom) end
  end
end

-- ─── Flash Animation ──────────────────────────────────────────────────────────

local flash_ns = nil

function M.flash_cell(buf, start_line, end_line)
  if not flash_ns then flash_ns = vim.api.nvim_create_namespace("sagefs_flash") end

  local function set_flash(hl_group)
    pcall(vim.api.nvim_buf_clear_namespace, buf, flash_ns, 0, -1)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    for i = start_line, end_line do
      pcall(vim.api.nvim_buf_set_extmark, buf, flash_ns, i - 1, 0, {
        hl_eol = true,
        line_hl_group = hl_group,
        priority = 200,
      })
    end
  end

  -- 3-step fade: full (80ms) → dim (70ms) → barely (70ms) → clear
  set_flash("SageFsRunning")
  vim.defer_fn(function()
    set_flash("SageFsFlashFade1")
    vim.defer_fn(function()
      set_flash("SageFsFlashFade2")
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_buf_clear_namespace, buf, flash_ns, 0, -1)
        end
      end, 70)
    end, 70)
  end, 80)
end

-- ─── Test Gutter Signs ────────────────────────────────────────────────────────

local testing = require("sagefs.testing")
local coverage = require("sagefs.coverage")

local test_ns = nil
local cov_ns = nil
-- Cached table for freshness_by_line (Nu cached-collections pattern: wipe and reuse)
local _freshness_cache = {}
-- Delta extmark state: track what was rendered last frame (FDA delta propagation)
-- { [buf] = { test_signs = { [line_0indexed] = "hl_group" }, cov_signs = { [line_0indexed] = "hl_group" } } }
local _prev_signs = {}

local function get_test_ns()
  if not test_ns then test_ns = vim.api.nvim_create_namespace("sagefs_tests") end
  return test_ns
end

local function get_cov_ns()
  if not cov_ns then cov_ns = vim.api.nvim_create_namespace("sagefs_coverage") end
  return cov_ns
end

function M.render_test_signs(buf, testing_state, annotations_state)
  local tns = get_test_ns()

  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" then
    vim.api.nvim_buf_clear_namespace(buf, tns, 0, -1)
    _prev_signs[buf] = nil
    return
  end

  -- Reuse cached table (Nu cached-collections: wipe instead of allocate — 7.9x faster in LuaJIT)
  for k in pairs(_freshness_cache) do _freshness_cache[k] = nil end
  if annotations_state and ann_module then
    local ann = ann_module.get_file(annotations_state, file)
    if ann then
      for _, ta in ipairs(ann.TestAnnotations or ann.testAnnotations or {}) do
        local line = ta.Line or ta.line
        local fresh = ta.Freshness or ta.freshness
        if line and fresh then
          local case = type(fresh) == "table" and (fresh.Case or fresh.case) or fresh
          _freshness_cache[line] = case
        end
      end
    end
  end

  -- Build desired sign state: line_0indexed → { text, hl }
  local desired = {}
  local by_file = testing.filter_by_file(testing_state, file)
  for _, t in ipairs(by_file) do
    if t.line and t.line > 0 then
      local sign = testing.gutter_sign(t.status)
      local fresh = _freshness_cache[t.line]
      if fresh == "Stale" then
        sign = { text = "~", hl = "SageFsTestStale" }
      elseif fresh == "Running" then
        sign = { text = "⏳", hl = "SageFsTestRunning" }
      end
      desired[t.line - 1] = sign.text .. "|" .. sign.hl
    end
  end

  -- Delta update: compare with previous frame (FDA delta propagation)
  local prev = _prev_signs[buf] and _prev_signs[buf].test_signs or {}
  local changed = false

  -- Check if anything changed at all (fast path)
  for line, key in pairs(desired) do
    if prev[line] ~= key then changed = true; break end
  end
  if not changed then
    for line in pairs(prev) do
      if not desired[line] then changed = true; break end
    end
  end

  if not changed then return end

  -- Full clear + readd (Neovim doesn't support per-extmark update by line efficiently
  -- without tracking extmark IDs, but the version skip above already eliminates ~90% of calls;
  -- this clear+readd only fires when actual sign content changed)
  vim.api.nvim_buf_clear_namespace(buf, tns, 0, -1)
  for line_0, key in pairs(desired) do
    local text, hl = key:match("^(.+)|(.+)$")
    pcall(vim.api.nvim_buf_set_extmark, buf, tns, line_0, 0, {
      sign_text = text,
      sign_hl_group = hl,
      priority = 200,
    })
  end

  -- Store current state for next delta comparison
  if not _prev_signs[buf] then _prev_signs[buf] = {} end
  _prev_signs[buf].test_signs = desired
end

-- ─── Coverage Gutter Signs ──────────────────────────────────────────────────

function M.render_coverage_signs(buf, coverage_state)
  local cns = get_cov_ns()

  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" then
    vim.api.nvim_buf_clear_namespace(buf, cns, 0, -1)
    if _prev_signs[buf] then _prev_signs[buf].cov_signs = nil end
    return
  end

  local lines = coverage.get_file_lines(coverage_state, file)
  if not lines then
    -- Clear if we had signs before
    if _prev_signs[buf] and _prev_signs[buf].cov_signs then
      vim.api.nvim_buf_clear_namespace(buf, cns, 0, -1)
      _prev_signs[buf].cov_signs = nil
    end
    return
  end

  -- Build desired state
  local desired = {}
  for _, entry in ipairs(lines) do
    if entry.line and entry.line > 0 then
      local sign = coverage.gutter_sign(entry.hits)
      desired[entry.line - 1] = sign.text .. "|" .. sign.hl
    end
  end

  -- Delta check
  local prev = _prev_signs[buf] and _prev_signs[buf].cov_signs or {}
  local changed = false
  for line, key in pairs(desired) do
    if prev[line] ~= key then changed = true; break end
  end
  if not changed then
    for line in pairs(prev) do
      if not desired[line] then changed = true; break end
    end
  end
  if not changed then return end

  vim.api.nvim_buf_clear_namespace(buf, cns, 0, -1)
  for line_0, key in pairs(desired) do
    local text, hl = key:match("^(.+)|(.+)$")
    pcall(vim.api.nvim_buf_set_extmark, buf, cns, line_0, 0, {
      sign_text = text,
      sign_hl_group = hl,
      priority = 150,
    })
  end

  if not _prev_signs[buf] then _prev_signs[buf] = {} end
  _prev_signs[buf].cov_signs = desired
end

-- ─── File Annotations (CodeLens + Inline Failures) ─────────────────────────

local ann_ns = nil

local function get_ann_ns()
  if not ann_ns then ann_ns = vim.api.nvim_create_namespace("sagefs_annotations") end
  return ann_ns
end

function M.render_annotations(buf, annotations_state, density_state)
  local ans = get_ann_ns()
  vim.api.nvim_buf_clear_namespace(buf, ans, 0, -1)

  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" then return end

  local ann = ann_module.get_file(annotations_state, file)
  if not ann then return end

  local line_count = vim.api.nvim_buf_line_count(buf)
  local density = density_state or { signs = true, codelens = true, inline_failures = true, branch_eol = false }

  -- Render CodeLens as virtual lines above test functions
  if density.codelens then
    local lenses = ann.CodeLenses or ann.codeLenses or {}
    for _, lens in ipairs(lenses) do
      local line = lens.Line or lens.line
      if line and line > 0 and line <= line_count then
        local text, hl = ann_module.format_codelens(lens)
        pcall(vim.api.nvim_buf_set_extmark, buf, ans, line - 1, 0, {
          virt_lines_above = true,
          virt_lines = { { { "  " .. text, hl } } },
          priority = 180,
        })
      end
    end
  end

  -- Render inline failures as virtual text at end of line
  if density.inline_failures then
    local failures = ann.InlineFailures or ann.inlineFailures or {}
    for _, failure in ipairs(failures) do
      local line = failure.Line or failure.line
      if line and line > 0 and line <= line_count then
        local text, hl = ann_module.format_inline_failure(failure)
        pcall(vim.api.nvim_buf_set_extmark, buf, ans, line - 1, 0, {
          virt_text = { { text, hl } },
          virt_text_pos = "eol",
          priority = 190,
        })
      end
    end
  end

  -- Render coverage annotations as gutter signs on covered/uncovered lines
  if density.signs then
    local cov_anns = ann.CoverageAnnotations or ann.coverageAnnotations or {}
    for _, cov in ipairs(cov_anns) do
      local line = cov.Line or cov.line
      if line and line > 0 and line <= line_count then
        local sign_text, sign_hl = ann_module.format_coverage_sign(cov)
        if sign_text then
          local opts = {
            sign_text = sign_text,
            sign_hl_group = sign_hl,
            priority = 140,
          }
          -- Show branch EOL text for partial branch coverage
          if density.branch_eol then
            local eol_text = ann_module.format_branch_eol(cov)
            if eol_text then
              opts.virt_text = { { " " .. eol_text .. " branches", "SageFsBranchPartial" } }
              opts.virt_text_pos = "eol"
            end
          end
          pcall(vim.api.nvim_buf_set_extmark, buf, ans, line - 1, 0, opts)
        end
      end
    end
  end
end

--- Clean up cached sign state for a buffer (call on BufWipeout/BufDelete)
---@param buf number
function M.clear_sign_cache(buf)
  _prev_signs[buf] = nil
end

-- ─── Floating Window ──────────────────────────────────────────────────────────

--- Show content in a centered floating window with q-to-close
---@param lines string[]
---@param opts { title: string|nil, max_height: number|nil, min_width: number|nil, wrap: boolean|nil }|nil
---@return { buf: number, win: number }
function M.show_float(lines, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

  local width = opts.min_width or 60
  for _, l in ipairs(lines) do
    if #l + 2 > width then width = #l + 2 end
  end
  local max_w = math.max(1, vim.o.columns - 4)
  local max_h = math.max(1, vim.o.lines - 4)
  width = math.max(1, math.min(width, max_w))
  local height = math.max(1, math.min(#lines, opts.max_height or 30, max_h))

  local win_opts = {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
  }
  if opts.title then
    win_opts.title = " " .. opts.title .. " "
    win_opts.title_pos = "center"
  end

  local win = vim.api.nvim_open_win(buf, true, win_opts)
  if opts.wrap then
    vim.api.nvim_set_option_value("wrap", true, { win = win })
    vim.api.nvim_set_option_value("linebreak", true, { win = win })
  end
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })

  return { buf = buf, win = win }
end

--- Show the full result of a cell in a float (the expansion behind the
--- "N more lines, <key> to expand" footer).
---@param cs { status: string, output: string|nil, duration_ms: number|nil }
---@return { buf: number, win: number }
function M.show_result_float(cs)
  local text = (cs.output or ""):gsub("\r", "")
  if text == "" then text = "(no output)" end
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then lines[#lines] = nil end
  local glyph = cs.status == "error" and "✖ Error" or (cs.status == "stale" and "~ Stale result" or "✓ Result")
  local dur = format.format_duration(cs.duration_ms)
  local title = glyph .. (dur and ("  " .. dur) or "") .. string.format("  (%d lines, q to close)", #lines)
  return M.show_float(lines, { title = title, max_height = 40, min_width = 40, wrap = true })
end

return M
