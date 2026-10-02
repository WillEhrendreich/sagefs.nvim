-- sagefs/coverage_hover.lua — Which tests cover this line, and the symbol badge
--
-- The daemon records coverage per test. file_annotations carries, for every
-- covered line, exactly the tests whose own recorded coverage reaches it
-- (CoveringTests), and coverage_view carries one aggregate badge per symbol.
-- This module shows both: a float for the line under the cursor listing the
-- covering tests (name and last result) with <CR> to jump to one, and the badge
-- as end-of-line virtual text on the symbol's definition line. The decisions
-- and the text are pure (and tested under busted); the window code is not.

local coverage = require("sagefs.coverage")
local testing = require("sagefs.testing")

local M = {}

local LEVELS = (vim and vim.log and vim.log.levels) or { INFO = 1, WARN = 2, ERROR = 3 }

M.KEY = "<leader>rtc"

-- ─── Pure: the float ─────────────────────────────────────────────────────────

--- Lines for the float, the row → test map for <CR>, and a title.
---@param info table from coverage.covering_info
---@return table { lines, rows, title }
function M.format_float(info)
  local lines, rows = {}, {}
  local n = #info.tests
  if n == 0 and info.status == "Covered" then
    lines[1] = string.format("Line %d: covered, but the daemon has no per-test reading for it, so it cannot say which tests.", info.line)
  elseif n == 0 then
    lines[1] = string.format("Line %d: no test covers this line.", info.line)
  elseif n == 1 then
    lines[1] = string.format("Line %d: 1 test covers this", info.line)
  else
    lines[1] = string.format("Line %d: %d tests cover this", info.line, n)
  end
  for _, test in ipairs(info.tests) do
    local glyph = test.status and testing.gutter_sign(test.status).text or "?"
    if glyph == " " then glyph = "?" end
    table.insert(lines, string.format("%s %s  (%s)", glyph, test.name, test.status or "no result"))
    rows[#lines] = test
  end
  if n > 0 then
    table.insert(lines, "")
    table.insert(lines, "<CR> jump to the test   q close")
  end
  local title = info.span.from == info.span.to
    and string.format("Covering tests, line %d", info.span.from)
    or string.format("Covering tests, lines %d-%d", info.span.from, info.span.to)
  return { lines = lines, rows = rows, title = title }
end

--- Where <CR> on a test row goes.
---@return table { file, line } or { message }
function M.resolve_jump(test, testing_state)
  local file, line = coverage.test_location(testing_state, test.test_id, test.name)
  if not file then
    return { message = string.format("SageFs: no source location is known for '%s' yet.", tostring(test.name)) }
  end
  return { file = file, line = line or 1 }
end

--- The covering info for a line from the plugin's state, or nil and why not.
---@return table|nil info, string|nil why
function M.cover_info_at(plugin, file, line)
  local annotations = require("sagefs.annotations")
  local ann = plugin.annotations_state and annotations.get_file(plugin.annotations_state, file) or nil
  if not ann or #(ann.CoverageAnnotations or ann.coverageAnnotations or {}) == 0 then
    return nil, "No coverage for this file yet. Turn on live testing (:SageFsEnableTesting) and run the tests."
  end
  local info = coverage.covering_info(ann, line, plugin.testing_state)
  if not info then
    return nil, string.format("No coverage annotation reaches line %d.", line)
  end
  return info, nil
end

-- ─── Pure: the badge ─────────────────────────────────────────────────────────

local BADGE_GROUPS = {
  Passing = "SageFsCoverageViewPassing",
  Failing = "SageFsCoverageViewFailing",
  Running = "SageFsCoverageViewRunning",
  Stale = "SageFsCoverageViewStale",
  Skipped = "SageFsCoverageViewStale",
}

--- Extmark options for a view's badge, or nil when no test covers the symbol.
function M.badge_extmark(view)
  local text, health = coverage.format_badge(view)
  if not text then return nil end
  return {
    virt_text = { { "  " .. text, BADGE_GROUPS[health] or "Comment" } },
    virt_text_pos = "eol",
    priority = 165,
  }
end

local badge_ns = nil

--- Draw the badge on each symbol's definition line.
---@param opts { api: table|nil, density: table|nil }|nil
function M.render_badges(buf, coverage_state, opts)
  opts = opts or {}
  local api = opts.api or vim.api
  badge_ns = badge_ns or api.nvim_create_namespace("sagefs_coverage_view")
  api.nvim_buf_clear_namespace(buf, badge_ns, 0, -1)
  if opts.density and opts.density.codelens == false then return end
  local file = api.nvim_buf_get_name(buf)
  if file == "" then return end
  local line_count = api.nvim_buf_line_count(buf)
  for _, view in ipairs(coverage.views_for_file(coverage_state, file)) do
    local spec = M.badge_extmark(view)
    if spec and view.definition_line > 0 and view.definition_line <= line_count then
      pcall(api.nvim_buf_set_extmark, buf, badge_ns, view.definition_line - 1, 0, spec)
    end
  end
end

function M.define_highlights()
  local links = {
    SageFsCoverageViewPassing = "DiagnosticOk",
    SageFsCoverageViewFailing = "DiagnosticError",
    SageFsCoverageViewRunning = "DiagnosticInfo",
    SageFsCoverageViewStale = "Comment",
  }
  for group, link in pairs(links) do
    pcall(vim.api.nvim_set_hl, 0, group, { link = link, default = true })
  end
end

-- ─── The float window ────────────────────────────────────────────────────────

local function default_goto(file, line)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  pcall(vim.api.nvim_win_set_cursor, 0, { line or 1, 0 })
  vim.cmd("normal! zz")
end

local function default_open_float(float, jump)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, float.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = 30
  for _, l in ipairs(float.lines) do width = math.max(width, vim.fn.strdisplaywidth(l) + 2) end
  width = math.min(width, math.max(30, vim.o.columns - 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor", row = 1, col = 0,
    width = width, height = #float.lines,
    style = "minimal", border = "rounded",
    title = " " .. float.title .. " ", title_pos = "center",
  })
  local function close() pcall(vim.api.nvim_win_close, win, true) end
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<CR>", function()
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local test = float.rows[lnum]
    if test then
      close()
      jump(test)
    end
  end, { buffer = buf, nowait = true, desc = "SageFs: jump to the covering test" })
  -- start on the first test row
  for lnum = 1, #float.lines do
    if float.rows[lnum] then pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 }); break end
  end
end

--- Show the covering tests of the line under the cursor.
---@param env { buf: number|nil, file: string|nil, line: number|nil, open_float: function|nil, goto_location: function|nil }|nil
function M.show(plugin, helpers, env)
  env = env or {}
  local file = env.file or vim.api.nvim_buf_get_name(env.buf or vim.api.nvim_get_current_buf())
  local line = env.line or vim.api.nvim_win_get_cursor(0)[1]
  local info, why = M.cover_info_at(plugin, file, line)
  if not info then
    helpers.notify(why, LEVELS.INFO)
    return
  end
  local float = M.format_float(info)
  local goto_location = env.goto_location or default_goto
  local function jump(test)
    local target = M.resolve_jump(test, plugin.testing_state)
    if not target.file then
      helpers.notify(target.message, LEVELS.WARN)
      return
    end
    goto_location(target.file, target.line)
  end
  ;(env.open_float or default_open_float)(float, jump)
end

-- ─── Registration ────────────────────────────────────────────────────────────

function M.register_commands(plugin, helpers, create_user_command)
  create_user_command = create_user_command or vim.api.nvim_create_user_command
  create_user_command("SageFsCoveringTests", function()
    M.show(plugin, helpers)
  end, { desc = "Which tests cover the line under the cursor (name and last result), <CR> jumps to one" })
end

function M.register_keymaps(plugin, helpers, bufnr)
  vim.keymap.set("n", M.KEY, function()
    M.show(plugin, helpers)
  end, { desc = "SageFs: tests covering this line", silent = true, buffer = bufnr })
end

return M
