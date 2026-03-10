-- sagefs/telescope_picker.lua — SageFsPickTest: fuzzy telescope picker over live test status
-- Allows filtering tests by name and running selected test via POST /api/live-testing/run
--
-- <CR>    run selected test by display name
-- <C-r>   run all tests matching the current prompt query

local M = {}

-- ─── Status formatting (pure, testable without telescope) ────────────────────

M.STATUS_PREFIX = {
  Passed         = "[PASS]",
  Failed         = "[FAIL]",
  Running        = "[RUN ]",
  Queued         = "[RUN ]",
  Stale          = "[STALE]",
  Detected       = "[NEW ]",
  Skipped        = "[SKIP]",
  PolicyDisabled = "[OFF ]",
}

M.STATUS_HL = {
  Passed  = "SageFsTestPassed",
  Failed  = "SageFsTestFailed",
  Running = "SageFsTestRunning",
  Queued  = "SageFsTestRunning",
  Stale   = "SageFsStale",
}

--- Format the status prefix bracket label for a test entry.
---@param status string
---@return string prefix e.g. "[PASS]", "[FAIL]", "[STALE]"
function M.format_status_prefix(status)
  return M.STATUS_PREFIX[status] or "[    ]"
end

-- ─── Telescope guard ──────────────────────────────────────────────────────────

local has_telescope = pcall(require, "telescope")
if not has_telescope then
  vim.notify(
    "sagefs.nvim: telescope.nvim not found — SageFsPickTest not available",
    vim.log.levels.WARN
  )
  return M
end

local pickers       = require("telescope.pickers")
local finders       = require("telescope.finders")
local conf          = require("telescope.config").values
local actions       = require("telescope.actions")
local action_state  = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")
local previewers    = require("telescope.previewers")

-- ─── HTTP helper ─────────────────────────────────────────────────────────────

local function run_tests_by_pattern(pattern, port)
  local transport   = require("sagefs.transport")
  local testing_mod = require("sagefs.testing")
  local req = testing_mod.build_run_request({
    pattern = (pattern and pattern ~= "") and pattern or nil,
  })
  transport.http_json({
    method  = "POST",
    url     = string.format("http://localhost:%d/api/live-testing/run", port or 37749),
    body    = req,
    timeout = 10,
    callback = function(ok, raw)
      if not ok then
        vim.notify("SageFs: failed to trigger tests", vim.log.levels.ERROR)
        return
      end
      local parse_ok, resp = pcall(vim.json.decode, raw)
      if parse_ok and resp and resp.success then
        local label = (pattern and pattern ~= "") and ("'" .. pattern .. "'") or "all tests"
        vim.notify("SageFs: running tests matching " .. label, vim.log.levels.INFO)
      else
        local reason = (parse_ok and resp and (resp.message or resp.reason)) or raw or "unknown error"
        vim.notify("SageFs: test run failed — " .. reason, vim.log.levels.ERROR)
      end
    end,
  })
end

-- ─── Preview ─────────────────────────────────────────────────────────────────

local function make_test_previewer()
  return previewers.new_buffer_previewer({
    title = "Test Details",
    define_preview = function(self, entry)
      local test = entry.value
      if not test then return end
      local lines = {}
      table.insert(lines, "Name:     " .. (test.displayName or "?"))
      table.insert(lines, "Status:   " .. (test.status or "?"))
      if test.category and test.category ~= "" then
        table.insert(lines, "Category: " .. test.category)
      end
      if test.framework and test.framework ~= "" then
        table.insert(lines, "Framework: " .. test.framework)
      end
      if test.file then
        local loc = test.file
        if test.line then loc = loc .. ":" .. test.line end
        table.insert(lines, "Location: " .. loc)
      end
      if test.output and test.output ~= "" then
        table.insert(lines, "")
        table.insert(lines, "── Failure Output ──────────────────────────")
        local count = 0
        for line in test.output:gmatch("[^\n]+") do
          if count >= 10 then
            table.insert(lines, "  … (truncated)")
            break
          end
          table.insert(lines, "  " .. line)
          count = count + 1
        end
      elseif test.status == "Passed" then
        table.insert(lines, "")
        table.insert(lines, "  ✓ Test passed")
      end
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
    end,
  })
end

-- ─── Picker ──────────────────────────────────────────────────────────────────

--- SageFsPickTest: fuzzy telescope picker over live test status.
--- Keybindings inside picker:
---   <CR>    run selected test (posts its display name as filter)
---   <C-r>   run all tests matching the current prompt query
---@param opts table|nil Telescope opts
function M.pick_test(opts)
  opts = opts or {}
  local ok, sagefs = pcall(require, "sagefs")
  if not ok then
    vim.notify("SageFs not loaded", vim.log.levels.WARN)
    return
  end

  local testing_mod = require("sagefs.testing")
  local all_tests   = testing_mod.all_tests(sagefs.testing_state)
  local port        = (sagefs.config and sagefs.config.port) or 37749

  -- Sort: failed → running/queued → stale → detected → passed → skipped → disabled
  local order = {
    Failed = 1, Running = 2, Queued = 2, Stale = 3,
    Detected = 4, Passed = 5, Skipped = 6, PolicyDisabled = 7,
  }
  table.sort(all_tests, function(a, b)
    local oa = order[a.status] or 99
    local ob = order[b.status] or 99
    if oa ~= ob then return oa < ob end
    return (a.displayName or "") < (b.displayName or "")
  end)

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 7 },      -- status prefix: "[FAIL]", "[STALE]", etc.
      { remaining = true }, -- test display name
    },
  })

  local function entry_maker(test)
    local prefix = M.format_status_prefix(test.status)
    local hl     = M.STATUS_HL[test.status] or "Comment"
    return {
      value   = test,
      ordinal = (test.status or "") .. " " .. (test.displayName or "") .. " " .. (test.fullName or ""),
      display = function(e)
        return displayer({
          { prefix, hl },
          { e.value.displayName or e.value.fullName or "?" },
        })
      end,
    }
  end

  pickers.new(opts, {
    prompt_title = "SageFsPickTest (" .. #all_tests .. ")",
    finder = finders.new_table({
      results     = all_tests,
      entry_maker = entry_maker,
    }),
    sorter    = conf.generic_sorter(opts),
    previewer = make_test_previewer(),
    attach_mappings = function(prompt_bufnr, map)
      -- <CR>: run selected test by display name
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local entry = action_state.get_selected_entry()
        if entry and entry.value then
          run_tests_by_pattern(entry.value.displayName or entry.value.fullName or "", port)
        end
      end)
      -- <C-r>: run tests matching current prompt query
      map("i", "<C-r>", function()
        local query = action_state.get_current_line()
        actions.close(prompt_bufnr)
        run_tests_by_pattern(query or "", port)
      end)
      map("n", "<C-r>", function()
        local query = action_state.get_current_line()
        actions.close(prompt_bufnr)
        run_tests_by_pattern(query or "", port)
      end)
      return true
    end,
  }):find()
end

return M
