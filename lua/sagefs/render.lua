-- sagefs/render.lua — Extmark rendering, highlights, and floating windows
-- Owns the visual output layer. No state mutation — reads state, writes extmarks.

local cells = require("sagefs.cells")
local format = require("sagefs.format")
local model = require("sagefs.model")
local ann_module = require("sagefs.annotations")

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
  vim.api.nvim_set_hl(0, "SageFsCellBorder", { fg = "#585b70" })
  -- Testing highlights
  vim.api.nvim_set_hl(0, "SageFsTestPassed", { fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "SageFsTestFailed", { fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "SageFsTestRunning", { fg = "#f9e2af" })
  vim.api.nvim_set_hl(0, "SageFsTestStale", { fg = "#fab387" })
  vim.api.nvim_set_hl(0, "SageFsTestDetected", { fg = "#585b70" })
  vim.api.nvim_set_hl(0, "SageFsTestDisabled", { fg = "#585b70" })
  vim.api.nvim_set_hl(0, "SageFsTestSkipped", { fg = "#585b70" })
  -- Coverage highlights
  vim.api.nvim_set_hl(0, "SageFsCovered", { fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "SageFsUncovered", { fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "SageFsCovNotCovered", { fg = "#585b70" })
  vim.api.nvim_set_hl(0, "SageFsCovPending", { fg = "#45475a" })
  vim.api.nvim_set_hl(0, "SageFsCovFailing", { fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "SageFsCovPartial", { fg = "#fab387" })
  -- CodeLens highlights
  vim.api.nvim_set_hl(0, "SageFsCodeLensPassed", { fg = "#a6e3a1", italic = true })
  vim.api.nvim_set_hl(0, "SageFsCodeLensFailed", { fg = "#f38ba8", italic = true })
  vim.api.nvim_set_hl(0, "SageFsCodeLensRunning", { fg = "#f9e2af", italic = true })
  vim.api.nvim_set_hl(0, "SageFsCodeLensStale", { fg = "#fab387", italic = true })
  vim.api.nvim_set_hl(0, "SageFsCodeLensDetected", { fg = "#585b70", italic = true })
  -- Inline failure highlights
  vim.api.nvim_set_hl(0, "SageFsInlineFailure", { fg = "#f38ba8", italic = true })
end

-- ─── Extmark Rendering ────────────────────────────────────────────────────────

function M.clear_extmarks(buf)
  local ns_id = M.get_namespace()
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
end

function M.render_cell(buf, boundary_line, cell_id, state)
  local ns_id = M.get_namespace()
  local cell = model.get_cell_state(state, cell_id)
  local render = format.build_render_options(cell, cell_id)
  if not render then return end

  local virt_text = {}
  if render.inline then
    table.insert(virt_text, { render.inline.text, render.inline.hl })
  end

  local opts = {
    id = cell_id * 1000,
    virt_text = #virt_text > 0 and virt_text or nil,
    virt_text_pos = "eol",
    sign_text = render.sign.text,
    sign_hl_group = render.sign.hl,
    priority = 100,
  }

  pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, boundary_line - 1, 0, opts)

  if render.virtual_lines and #render.virtual_lines > 0 then
    local virt_lines = {}
    for _, vl in ipairs(render.virtual_lines) do
      table.insert(virt_lines, { { vl.text, vl.hl } })
    end
    pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, boundary_line - 1, 0, {
      id = cell_id * 1000 + 1,
      virt_lines = virt_lines,
      virt_lines_above = false,
    })
  end
end

function M.render_all(buf, state)
  local ns_id = M.get_namespace()
  M.clear_extmarks(buf)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local all_cells = cells.find_all_cells(lines)

  for _, cell in ipairs(all_cells) do
    M.render_cell(buf, cell.end_line, cell.id, state)

    local cell_state = model.get_cell_state(state, cell.id)
    if cell_state.status == "idle" or cell_state.status == "stale" then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, cell.end_line - 1, 0, {
        id = cell.id * 1000 + 2,
        virt_lines = { { { "▶ Eval", "SageFsRunning" } } },
        virt_lines_above = true,
      })
    end
  end
end

-- ─── Flash Animation ──────────────────────────────────────────────────────────

function M.flash_cell(buf, start_line, end_line)
  local flash_ns = vim.api.nvim_create_namespace("sagefs_flash")
  for i = start_line, end_line do
    pcall(vim.api.nvim_buf_add_highlight, buf, flash_ns, "SageFsRunning", i - 1, 0, -1)
  end
  vim.defer_fn(function()
    pcall(vim.api.nvim_buf_clear_namespace, buf, flash_ns, 0, -1)
  end, 150)
end

-- ─── Test Gutter Signs ────────────────────────────────────────────────────────

local testing = require("sagefs.testing")
local coverage = require("sagefs.coverage")

local test_ns = nil
local cov_ns = nil

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
  vim.api.nvim_buf_clear_namespace(buf, tns, 0, -1)

  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" then return end

  -- Build line→freshness lookup from annotations
  local freshness_by_line = {}
  if annotations_state then
    local ann = ann_module.get_file(annotations_state, file)
    if ann then
      for _, ta in ipairs(ann.TestAnnotations or ann.testAnnotations or {}) do
        local line = ta.Line or ta.line
        local fresh = ta.Freshness or ta.freshness
        if line and fresh then
          local case = type(fresh) == "table" and (fresh.Case or fresh.case) or fresh
          freshness_by_line[line] = case
        end
      end
    end
  end

  local by_file = testing.filter_by_file(testing_state, file)
  for _, t in ipairs(by_file) do
    if t.line and t.line > 0 then
      local sign = testing.gutter_sign(t.status)
      -- Override to stale/running when freshness says so
      local fresh = freshness_by_line[t.line]
      if fresh == "Stale" then
        sign = { text = "~", hl = "SageFsTestStale" }
      elseif fresh == "Running" then
        sign = { text = "⏳", hl = "SageFsTestRunning" }
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, tns, t.line - 1, 0, {
        sign_text = sign.text,
        sign_hl_group = sign.hl,
        priority = 200,
      })
    end
  end
end

-- ─── Coverage Gutter Signs ──────────────────────────────────────────────────

function M.render_coverage_signs(buf, coverage_state)
  local cns = get_cov_ns()
  vim.api.nvim_buf_clear_namespace(buf, cns, 0, -1)

  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" then return end

  local lines = coverage.get_file_lines(coverage_state, file)
  if not lines then return end

  for _, entry in ipairs(lines) do
    if entry.line and entry.line > 0 then
      local sign = coverage.gutter_sign(entry.hits)
      pcall(vim.api.nvim_buf_set_extmark, buf, cns, entry.line - 1, 0, {
        sign_text = sign.text,
        sign_hl_group = sign.hl,
        priority = 150,
      })
    end
  end
end

-- ─── File Annotations (CodeLens + Inline Failures) ─────────────────────────

local ann_ns = nil

local function get_ann_ns()
  if not ann_ns then ann_ns = vim.api.nvim_create_namespace("sagefs_annotations") end
  return ann_ns
end

function M.render_annotations(buf, annotations_state)
  local ans = get_ann_ns()
  vim.api.nvim_buf_clear_namespace(buf, ans, 0, -1)

  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" then return end

  local ann = ann_module.get_file(annotations_state, file)
  if not ann then return end

  local line_count = vim.api.nvim_buf_line_count(buf)

  -- Render CodeLens as virtual lines above test functions
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

  -- Render inline failures as virtual text at end of line
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

  -- Render coverage annotations as gutter signs on covered/uncovered lines
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
        -- Show branch count as virtual text for partial coverage
        if sign_hl == "SageFsCovPartial" then
          local detail = cov.Detail or cov.detail
          local count = detail and detail.Fields and detail.Fields[1] or 0
          if count > 0 then
            opts.virt_text = { { string.format(" ◐ %d branches", count), "SageFsCovPartial" } }
            opts.virt_text_pos = "eol"
          end
        end
        pcall(vim.api.nvim_buf_set_extmark, buf, ans, line - 1, 0, opts)
      end
    end
  end
end

-- ─── Floating Window ──────────────────────────────────────────────────────────

--- Show content in a centered floating window with q-to-close
---@param lines string[]
---@param opts { title: string|nil, max_height: number|nil, min_width: number|nil }|nil
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
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })

  return { buf = buf, win = win }
end

return M
