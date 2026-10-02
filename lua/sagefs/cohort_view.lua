-- sagefs/cohort_view.lua — :SageFsCohort, the cohort and the trunk in a scratch buffer
-- REQUIRES vim — the impure shell around cohort.lua and mcp_client.lua
--
-- get_cohort_status has no REST route, so the text is fetched with an MCP
-- tools/call (mcp_client). The view shows members, claims, the landing queue and
-- the `trunk <landingId>: ...` lines, with an older daemon's member handles masked. It refreshes
-- when the daemon says the cohort moved (cohort_matrix, claim_changed,
-- landing_changed, save_observed, cohortChanged) and when a reload report
-- arrives, because a trunk line changes from "applied, new body has not run yet"
-- to "patched (ran)" without any cohort event: a trunk line is read again, not
-- cached.

local cohort = require("sagefs.cohort")
local mcp_client = require("sagefs.mcp_client")

local M = {}

local BUF_NAME = "sagefs://cohort"
local REFRESH_EVENTS = {
  "SageFsCohortMatrix", "SageFsClaimChanged", "SageFsLandingChanged",
  "SageFsSaveObserved", "SageFsCohortChanged", "SageFsReloadReported",
}
local DEBOUNCE_MS = 300

local client = nil
local port_fn = function() return 37749 end
local bufnr = nil
local ns = nil
local last_matrix = nil
local pending = nil
local fetching = false

local function namespace()
  if not ns then ns = vim.api.nvim_create_namespace("sagefs_cohort") end
  return ns
end

local function get_client()
  if not client then client = mcp_client.connect(port_fn()) end
  return client
end

local function visible_window()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then return win end
  end
  return nil
end

local function write(lines)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local texts = {}
  for i, l in ipairs(lines) do texts[i] = l.text end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, texts)
  vim.bo[bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(bufnr, namespace(), 0, -1)
  for i, l in ipairs(lines) do
    if l.hl then
      pcall(vim.api.nvim_buf_add_highlight, bufnr, namespace(), l.hl, i - 1, 0, #l.text)
    end
  end
end

--- Lines for a fetch that failed: say so, and show what the event stream last said.
local function failure_lines(err)
  local lines = {
    { text = "Could not read the cohort status: " .. tostring(err), hl = "SageFsReloadError" },
    { text = "  Is the daemon running? Try :SageFsStart, or :checkhealth sagefs", hl = "SageFsReloadQuiet" },
  }
  if last_matrix then
    table.insert(lines, { text = "" })
    for _, text in ipairs(cohort.matrix_summary(last_matrix)) do
      table.insert(lines, { text = text, hl = "SageFsReloadQuiet" })
    end
  end
  return lines
end

--- Fetch get_cohort_status and show it.
function M.refresh()
  if fetching then return end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  fetching = true
  get_client().call_tool("get_cohort_status", {}, function(ok, text)
    fetching = false
    if not ok then
      write(failure_lines(text))
      return
    end
    local model = cohort.parse_status(text)
    if not model then
      -- Not a cohort status (the tool said something else): show its words.
      local lines = {}
      for line in (text .. "\n"):gmatch("([^\n]*)\n") do table.insert(lines, { text = line }) end
      write(lines)
      return
    end
    write(cohort.render(model).lines)
  end)
end

local function schedule_refresh()
  if not visible_window() then return end
  if pending then return end
  pending = vim.defer_fn(function()
    pending = nil
    M.refresh()
  end, DEBOUNCE_MS)
end

--- Open (or focus) the cohort buffer and refresh it.
function M.open()
  local win = visible_window()
  if win then
    vim.api.nvim_set_current_win(win)
  else
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      local existing = vim.fn.bufnr(BUF_NAME)
      bufnr = existing ~= -1 and existing or vim.api.nvim_create_buf(false, true)
      if existing == -1 then vim.api.nvim_buf_set_name(bufnr, BUF_NAME) end
      vim.bo[bufnr].buftype = "nofile"
      vim.bo[bufnr].bufhidden = "hide"
      vim.bo[bufnr].swapfile = false
      vim.bo[bufnr].filetype = "sagefs-cohort"
      vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = bufnr, silent = true, desc = "SageFs: close cohort view" })
      vim.keymap.set("n", "r", function() M.refresh() end, { buffer = bufnr, silent = true, desc = "SageFs: refresh cohort view" })
    end
    vim.cmd("botright 18split")
    vim.api.nvim_win_set_buf(0, bufnr)
  end
  write({ { text = "reading the cohort status...", hl = "SageFsReloadQuiet" } })
  M.refresh()
end

--- Register :SageFsCohort and the refresh autocmds.
---@param port function returns the daemon port
function M.register(port)
  port_fn = port or port_fn
  vim.api.nvim_create_user_command("SageFsCohort", function() M.open() end, {
    desc = "Show the cohort: members, claims, the landing queue and the trunk",
  })
  local group = vim.api.nvim_create_augroup("SageFsCohortView", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = REFRESH_EVENTS,
    callback = function(ev)
      if ev.match == "SageFsCohortMatrix" and type(ev.data) == "table" then last_matrix = ev.data end
      schedule_refresh()
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function() if client then client.close() end end,
  })
end

return M
