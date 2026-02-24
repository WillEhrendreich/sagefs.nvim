-- sagefs/render.lua — Extmark rendering, highlights, and floating windows
-- Owns the visual output layer. No state mutation — reads state, writes extmarks.

local cells = require("sagefs.cells")
local format = require("sagefs.format")
local model = require("sagefs.model")

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
  -- Coverage highlights
  vim.api.nvim_set_hl(0, "SageFsCovered", { fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "SageFsUncovered", { fg = "#f38ba8" })
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

function M.render_test_signs(buf, testing_state)
  local tns = get_test_ns()
  vim.api.nvim_buf_clear_namespace(buf, tns, 0, -1)

  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" then return end

  local by_file = testing.filter_by_file(testing_state, file)
  for _, t in ipairs(by_file) do
    if t.line and t.line > 0 then
      local sign = testing.gutter_sign(t.status)
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
  local height = math.min(#lines, opts.max_height or 30)

  local win_opts = {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
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
