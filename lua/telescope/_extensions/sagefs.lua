-- telescope/_extensions/sagefs.lua — Telescope picker for SageFs live tests
-- Usage: :Telescope sagefs tests
--        :Telescope sagefs failures

local has_telescope, telescope = pcall(require, "telescope")
if not has_telescope then
  return
end

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")

local function get_sagefs()
  local ok, sagefs = pcall(require, "sagefs")
  if not ok then return nil end
  return sagefs
end

local status_icon = {
  Passed = "✓",
  Failed = "✗",
  Running = "⏳",
  Stale = "~",
  Detected = "◦",
  Queued = "⋯",
  Skipped = "⊘",
  PolicyDisabled = "—",
  NotRun = "·",
}

local status_hl = {
  Passed = "SageFsTestPassed",
  Failed = "SageFsTestFailed",
  Running = "SageFsTestRunning",
  Stale = "SageFsStale",
}

local function make_entry(displayer)
  return function(test)
    local icon = status_icon[test.status] or "?"
    local duration = test.duration or ""
    local short_file = test.file and test.file:match("[^\\/]+$") or ""
    return {
      value = test,
      ordinal = test.displayName .. " " .. (test.status or "") .. " " .. short_file,
      display = function(entry)
        return displayer({
          { icon, status_hl[entry.value.status] or "Comment" },
          { entry.value.displayName },
          { duration, "Comment" },
          { short_file, "Comment" },
        })
      end,
      filename = test.file,
      lnum = test.line,
      col = 0,
    }
  end
end

local function tests_picker(opts)
  opts = opts or {}
  local sagefs = get_sagefs()
  if not sagefs then
    vim.notify("SageFs not loaded", vim.log.levels.WARN)
    return
  end

  local testing = require("sagefs.testing")
  local all_tests = testing.all_tests(sagefs.testing_state)

  -- Sort: failed first, then running, then stale, then passed
  local order = { Failed = 1, Running = 2, Stale = 3, Detected = 4, Passed = 5, Skipped = 6 }
  table.sort(all_tests, function(a, b)
    local oa = order[a.status] or 99
    local ob = order[b.status] or 99
    if oa ~= ob then return oa < ob end
    return (a.displayName or "") < (b.displayName or "")
  end)

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 2 },
      { remaining = true },
      { width = 8 },
      { width = 30 },
    },
  })

  pickers.new(opts, {
    prompt_title = "SageFs Tests (" .. #all_tests .. ")",
    finder = finders.new_table({
      results = all_tests,
      entry_maker = make_entry(displayer),
    }),
    sorter = conf.generic_sorter(opts),
    previewer = conf.grep_previewer(opts),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local entry = action_state.get_selected_entry()
        if entry and entry.filename and entry.lnum then
          vim.cmd("edit " .. vim.fn.fnameescape(entry.filename))
          vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
          vim.cmd("normal! zz")
        end
      end)
      -- <C-r> to re-run selected test
      map("i", "<C-r>", function()
        local entry = action_state.get_selected_entry()
        if entry and entry.value and entry.value.testId then
          vim.notify("Running test: " .. entry.value.displayName, vim.log.levels.INFO)
          local cmd = require("sagefs.commands")
          if cmd and cmd.run_test then
            cmd.run_test(entry.value.testId)
          end
        end
      end)
      return true
    end,
  }):find()
end

local function failures_picker(opts)
  opts = opts or {}
  local sagefs = get_sagefs()
  if not sagefs then
    vim.notify("SageFs not loaded", vim.log.levels.WARN)
    return
  end

  local testing = require("sagefs.testing")
  local failed = testing.filter_by_status(sagefs.testing_state, "Failed")

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 2 },
      { remaining = true },
      { width = 8 },
      { width = 30 },
    },
  })

  pickers.new(opts, {
    prompt_title = "SageFs Failures (" .. #failed .. ")",
    finder = finders.new_table({
      results = failed,
      entry_maker = make_entry(displayer),
    }),
    sorter = conf.generic_sorter(opts),
    previewer = conf.grep_previewer(opts),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local entry = action_state.get_selected_entry()
        if entry and entry.filename and entry.lnum then
          vim.cmd("edit " .. vim.fn.fnameescape(entry.filename))
          vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
          vim.cmd("normal! zz")
        end
      end)
      return true
    end,
  }):find()
end

return telescope.register_extension({
  exports = {
    tests = tests_picker,
    failures = failures_picker,
  },
})
