-- sagefs/debug_test_ui.lua — The editor side of debugging a failing test
--
-- Which test does :SageFsDebugTest mean, the quiet "debug" hint drawn on a
-- failing-test line (the CodeLens-equivalent: the daemon marks a failing test's
-- lens with a DebugTest command, Neovim draws it as virtual text), and the
-- command and keymap registration. The hold/attach/release lifecycle is in
-- sagefs.debug_test.

local dt = require("sagefs.debug_test")

local M = {}

local LEVELS = (vim and vim.log and vim.log.levels) or { INFO = 1, WARN = 2, ERROR = 3 }

-- Not <leader>rtD: that is one shifted letter from <leader>rtd, which disables
-- live testing for the daemon's session.
M.KEY = "<leader>rtg"

-- ─── Pure: which test ────────────────────────────────────────────────────────

--- Decide which test a :SageFsDebugTest call means.
---@param ctx { args: string, testing_state: table, annotations_state: table, file: string, line: number }
---@return table { kind = "start", target, name } | { kind = "confirm", target, name, line, message } | { kind = "choose", choices } | { kind = "none", message }
function M.resolve_target(ctx)
  local args = ctx.args or ""
  if args ~= "" then
    local known = ctx.testing_state and ctx.testing_state.tests and ctx.testing_state.tests[args]
    if known then
      return { kind = "start", target = { test_id = args }, name = known.displayName }
    end
    return { kind = "start", target = { pattern = args }, name = args }
  end

  local function decide(list)
    if #list == 1 then
      return { kind = "start", target = { test_id = list[1].test_id }, name = list[1].name }
    elseif #list > 1 then
      return { kind = "choose", choices = list }
    end
    return nil
  end

  local here = dt.failing_tests_at(ctx.testing_state, ctx.annotations_state, ctx.file, ctx.line)
  local picked = decide(here)
  if picked then return picked end
  -- Running a test is a side effect: off the failing line, name the only failing
  -- test in the file and let the user confirm it.
  local elsewhere = dt.failing_tests_at(ctx.testing_state, ctx.annotations_state, ctx.file, nil)
  if #elsewhere == 1 then
    local only = elsewhere[1]
    return {
      kind = "confirm",
      target = { test_id = only.test_id },
      name = only.name,
      line = only.line,
      message = string.format('No failing test on this line. Debug "%s" (line %s) instead?', only.name, tostring(only.line)),
    }
  end
  picked = decide(elsewhere)
  if picked then return picked end
  return {
    kind = "none",
    message = "No failing test in this file. Run :SageFsDebugTest <name> to debug any test by name.",
  }
end

-- ─── The hint ────────────────────────────────────────────────────────────────

--- The extmark options for the debug hint on one line.
---@param count number failing tests on the line
---@param leader string|nil the leader key as typed, e.g. "<leader>"
function M.hint_extmark(count, leader)
  local text
  if count > 1 then
    text = string.format("▸ debug (%d failing)  %s", count, M.KEY)
  else
    text = "▸ debug  " .. M.KEY
  end
  if leader and leader ~= "<leader>" then
    text = text:gsub("<leader>", leader)
  end
  return {
    virt_text = { { text, "SageFsDebugHint" } },
    virt_text_pos = "right_align",
    priority = 170,
  }
end

local hint_ns = nil

--- Draw the hint on every line of `buf` that carries a debuggable failure.
---@param opts { api: table|nil, leader: string|nil, density: table|nil }|nil
function M.render_hints(buf, testing_state, annotations_state, opts)
  opts = opts or {}
  local api = opts.api or vim.api
  hint_ns = hint_ns or api.nvim_create_namespace("sagefs_debug_hint")
  api.nvim_buf_clear_namespace(buf, hint_ns, 0, -1)
  -- The hint is a CodeLens-class layer: density minimal turns it off.
  if opts.density and opts.density.codelens == false then return end
  local file = api.nvim_buf_get_name(buf)
  if file == "" then return end
  local line_count = api.nvim_buf_line_count(buf)
  local leader = opts.leader or (vim.g and vim.g.mapleader and vim.g.mapleader ~= "" and vim.g.mapleader) or "<leader>"
  if leader == " " then leader = "<space>" end
  for line, count in pairs(dt.hint_marks(testing_state, annotations_state, file)) do
    if line > 0 and line <= line_count then
      pcall(api.nvim_buf_set_extmark, buf, hint_ns, line - 1, 0, M.hint_extmark(count, leader))
    end
  end
end

--- Define the highlight group, quiet by default (the user's own colors win).
function M.define_highlights()
  pcall(vim.api.nvim_set_hl, 0, "SageFsDebugHint", { link = "Comment", default = true })
end

-- ─── Running ─────────────────────────────────────────────────────────────────

--- Debug a test: resolve which one, then hand it to the lifecycle.
---@param env { buf: number|nil, file: string|nil, line: number|nil, select: function|nil, start: function|nil }|nil
function M.run(plugin, helpers, args, env)
  env = env or {}
  local buf = env.buf or vim.api.nvim_get_current_buf()
  local file = env.file or vim.api.nvim_buf_get_name(buf)
  local line = env.line or vim.api.nvim_win_get_cursor(0)[1]
  local resolved = M.resolve_target({
    args = args,
    testing_state = plugin.testing_state,
    annotations_state = plugin.annotations_state,
    file = file,
    line = line,
  })

  local function start(target)
    local starter = env.start or function(t)
      return dt.start(dt.default_deps(plugin, helpers, buf), t)
    end
    return starter(target)
  end

  if resolved.kind == "none" then
    helpers.notify(resolved.message, LEVELS.WARN)
  elseif resolved.kind == "start" then
    start(resolved.target)
  elseif resolved.kind == "confirm" then
    local select = env.select or vim.ui.select
    select({ "Debug it", "Cancel" }, { prompt = resolved.message }, function(choice)
      if choice == "Debug it" then start(resolved.target) end
    end)
  else
    local select = env.select or vim.ui.select
    select(resolved.choices, {
      prompt = "Debug which failing test?",
      format_item = function(item) return string.format("%s  (line %s)", item.name, tostring(item.line)) end,
    }, function(choice)
      if choice then start({ test_id = choice.test_id }) end
    end)
  end
end

-- ─── Registration ────────────────────────────────────────────────────────────

---@param create_user_command function|nil defaults to nvim_create_user_command
function M.register_commands(plugin, helpers, create_user_command)
  create_user_command = create_user_command or vim.api.nvim_create_user_command

  create_user_command("SageFsDebugTest", function(cmd)
    M.run(plugin, helpers, vim.trim and vim.trim(cmd.args or "") or (cmd.args or ""))
  end, {
    nargs = "?",
    desc = "Debug a failing test with nvim-dap (no argument: the failing test on this line, or the file's only one after you confirm; or a test name or id)",
  })

  create_user_command("SageFsDebugRelease", function()
    if not dt.release_current() then
      helpers.notify("SageFs debug: nothing is being held.", LEVELS.INFO)
    end
  end, { desc = "Release the test SageFs is holding for the debugger (and stop the debug run)" })
end

function M.register_keymaps(plugin, helpers, bufnr)
  vim.keymap.set("n", M.KEY, function()
    M.run(plugin, helpers, "")
  end, { desc = "SageFs: debug the failing test here", silent = true, buffer = bufnr })
end

return M
