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
local actions = require("sagefs.cohort_actions")
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

--- The arguments for one `get_cohort_status` call.
---
--- Pure, and separately testable, because the thing that went wrong here is invisible in the
--- product: passing `{}` is valid, returns a valid cohort, and shows the wrong repository's
--- members with nothing on screen to say so. `refresh` is a buffer-and-client affair that a
--- unit test cannot reach, so the decision it makes is lifted out and pinned here.
---
--- An EMPTY STRING, never nil. `working_directory` is optional in the tool, and a nil would
--- be dropped from the JSON object entirely — the daemon would then read the cohort of the
--- directory IT started in, silently. An empty string is what the tool's
--- `DefaultParameterValue("")` turns into "the caller named none", which is honest.
function M.status_args(cwd)
  return { working_directory = cwd or "" }
end

--- The last status the view parsed, which is what completion reads. Kept so the
--- member and landing ids a command offers are the ones actually on screen: a
--- completion that offers a stale id is worse than one that offers none.
local last_model = nil

--- The ids a completion offers, from the last status. Pure over the model, so the
--- decision is testable and the shell stays a shell.
---@param model table|nil parsed cohort, or nil when nothing has been read
---@param which string "members" or "landings"
---@return string[] ids
function M.complete_ids(model, which)
  if not model then return {} end
  if which == "members" then
    local out = {}
    for _, m in ipairs(model.members or {}) do table.insert(out, m.id) end
    return out
  end
  local out = {}
  for _, l in ipairs(model.landings or {}) do table.insert(out, l.id) end
  return out
end

--- Fetch get_cohort_status and show it.
function M.refresh()
  if fetching then return end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  fetching = true
  get_client().call_tool("get_cohort_status", M.status_args(vim.fn.getcwd()), function(ok, text)
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
    last_model = model
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
      if existing ~= -1 then vim.api.nvim_buf_set_name(bufnr, BUF_NAME) end
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

--- Report the outcome of an action, where a person will see it: the cohort buffer
--- if it is open, otherwise a notification.
local function report(ok, text)
  local win = visible_window()
  if win then
    vim.api.nvim_echo({ { text, ok and "Title" or "ErrorMsg" } }, false, {})
  else
    vim.notify(text, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end
end

--- Run one cohort action: build its arguments, refuse locally what the tool's own
--- bounds forbid, call it, and refresh the view so the row shows the new state.
---
--- The arguments come from the matching builder in cohort_actions, which is where
--- the `working_directory` rule lives. A local refusal is not a second source of
--- truth about the rules: it covers only the two bounds the tool documents (a
--- reason of 1..1000 characters, and required names), so a malformed command costs
--- no round trip and the message arrives before the user wonders.
local function run_action(spec, args, refusal)
  if refusal then
    report(false, refusal)
    return
  end
  get_client().call_tool(spec.tool, args, function(ok, text)
    report(ok, text)
    -- A landing that just went Blocked, resolved or withdrawn shows in the buffer,
    -- and the cohort SSE event will also fire; refreshing here means the row is
    -- right now rather than at the next event.
    M.refresh()
  end)
end

--- Register :SageFsCohort and the refresh autocmds.
---@param port function returns the daemon port
function M.register(port)
  port_fn = port or port_fn
  vim.api.nvim_create_user_command("SageFsCohort", function() M.open() end, {
    desc = "Show the cohort: members, claims, the landing queue and the trunk",
  })

  -- The four cohort actions from 0.6.896. Each takes the agent name first (the
  -- name the cohort knows you by), then its own arguments. The landing ids and
  -- member ids complete from the last status read into this view.
  --
  -- `nargs = "+"` and not the arity, because Neovim refuses a numeric nargs above
  -- 1. The count is checked in the handler so a short command can say WHICH
  -- argument is missing (see cohort_actions.check_arity).
  local function register_action(spec, builder, which)
    local usage = spec.name .. " <agent>"
      .. (spec.arity == 3 and " <landing> <reason>" or " <landing-or-member>")
    vim.api.nvim_create_user_command(spec.name, function(opts)
      local parts = vim.split(opts.args or "", "%s+", { trimempty = true })
      -- ONE split, shared by the refusals and the call: a veto's reason is the
      -- rest of the line joined, and checking one string while sending another is
      -- how a bound gets enforced on the wrong value.
      local agent, id, reason = actions.split_args(parts)
      local bad = actions.check_arity(parts, spec.arity, usage)
      if not bad then
        bad = actions.check_agent(agent, spec.name)
      end
      if not bad and spec.arity == 3 then
        bad = actions.check_veto(reason, id)
      end
      local args
      if spec.arity == 3 then
        args = actions.veto_args(agent, id, reason, vim.fn.getcwd())
      else
        args = builder(agent, id, vim.fn.getcwd())
      end
      run_action(spec, args, bad)
    end, {
      nargs = "+",
      desc = spec.desc,
      complete = function(_, lead)
        local ids = M.complete_ids(last_model, which)
        return vim.tbl_filter(function(id) return id:find(lead, 1, true) == 1 end, ids)
      end,
    })
  end

  register_action(
    { name = "SageFsCohortDelegate", tool = "delegate_conductor", arity = 2,
      desc = "Hand the conductor seat to another present cohort member" },
    function(agent, to_member, cwd) return actions.delegate_args(agent, to_member, cwd) end,
    "members"
  )
  register_action(
    { name = "SageFsCohortVeto", tool = "veto_landing", arity = 3,
      desc = "Object to a landing, with the reason" },
    function(agent, landing_id, reason, cwd) return actions.veto_args(agent, landing_id, reason, cwd) end,
    "landings"
  )
  register_action(
    { name = "SageFsCohortResolveVeto", tool = "resolve_veto", arity = 2,
      desc = "Clear a veto as the conductor; the landing queues again" },
    function(agent, landing_id, cwd) return actions.resolve_args(agent, landing_id, cwd) end,
    "landings"
  )
  register_action(
    { name = "SageFsCohortWithdraw", tool = "withdraw_landing", arity = 2,
      desc = "Withdraw your own landing" },
    function(agent, landing_id, cwd) return actions.withdraw_args(agent, landing_id, cwd) end,
    "landings"
  )

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
