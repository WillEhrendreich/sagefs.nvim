-- sagefs/hygiene_view.lua: :SageFsHygiene
-- REQUIRES vim: the impure shell around hygiene.lua and mcp_client.lua
--
-- get_workspace_hygiene has no REST route, so the text is fetched with an MCP
-- tools/call, the same way cohort_view reads get_cohort_status. The window is a
-- scratch split the way :SageFsCohort's is, with `q` to close it and `r` to read
-- the plan again.
--
-- Read-only, on purpose. The daemon also has tidy_workspace, which reclaims what
-- the plan calls safe; it needs the plan id and confirm=true, because reclaiming
-- deletes other people's worktrees. A keystroke in an editor is not that
-- decision, so this command reads the plan and says what it would take, and
-- never calls the tool that removes anything.
--
-- An older daemon answers with an error or with something else entirely. That is
-- shown, in its own words, with a note that the daemon is older: see
-- hygiene.lua. Nothing here raises for it.

local hygiene = require("sagefs.hygiene")
local mcp_client = require("sagefs.mcp_client")

local M = {}

local BUF_NAME = "sagefs://hygiene"
local NS = "sagefs_hygiene"

local client = nil
local port_fn = function() return 37749 end
local bufnr = nil

local function namespace()
  return vim.api.nvim_create_namespace(NS)
end

local function get_client()
  if not client then client = mcp_client.connect(port_fn()) end
  return client
end

--- The line under the heading that begins each group gets a little weight, so
--- the reply's shape is visible without being the only thing that is.
local function highlight(buf, lines)
  local ns = namespace()
  local in_group = false
  for i, text in ipairs(lines) do
    local group
    if not in_group and text:find("^(%d+ %a[%w%s]*)$") then
      group = "Title"
      in_group = true
    elseif in_group and text:match("^%s+%S") and not text:match("^%s+%S+ x%d+, ") then
      group = nil
      in_group = false
    end
    if text:find("read%-only") or text:find("^To reclaim") then group = "SageFsReloadPending" end
    if text:find("no get_workspace_hygiene") then group = "SageFsReloadWarn" end
    if group then pcall(vim.api.nvim_buf_add_highlight, buf, ns, group, i - 1, 0, #text) end
  end
end

--- Replace the window's contents.
---@param lines string[]
local function write(lines)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.api.nvim_buf_clear_namespace(bufnr, namespace(), 0, -1)
  highlight(bufnr, lines)
end

--- The editor-facing pieces, injected so the flow is plain Lua under busted.
---@return { write: fun(lines: string[]), cwd: fun():string, notify: fun(msg: string, level: number|nil) }
local function default_ui()
  return {
    write = write,
    cwd = function() return vim.fn.getcwd() end,
    notify = function(msg, level) vim.notify("SageFs: " .. msg, level or vim.log.levels.INFO) end,
  }
end

--- Ask the daemon for the plan and show it. Every path here writes a window: a
--- plan, a refusal, or the words for an older daemon. `ok` is false for a
--- transport failure and for a daemon that refused the call; both are the
--- daemon's words, and neither raises here.
---@param deps table|nil { client: table|nil, ui: table|nil }
function M.refresh(deps)
  deps = deps or {}
  local ui = deps.ui or default_ui()
  local c = deps.client or get_client()
  c.call_tool("get_workspace_hygiene", { working_directory = hygiene.working_directory(ui.cwd) }, function(_ok, text)
    local shown = hygiene.render(text)
    ui.write(shown.lines)
    ui.notify(hygiene.summary_line(text), shown.present and vim.log.levels.INFO or vim.log.levels.WARN)
  end)
end

--- Open (or focus) the hygiene window and read the plan.
function M.open()
  local win
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == bufnr then win = w break end
    end
  end
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
      vim.bo[bufnr].filetype = "sagefs-hygiene"
      vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = bufnr, silent = true, desc = "SageFs: close the hygiene view" })
      vim.keymap.set("n", "r", function() M.refresh() end, { buffer = bufnr, silent = true, desc = "SageFs: read the hygiene plan again" })
    end
    vim.cmd("botright 18split")
    vim.api.nvim_win_set_buf(0, bufnr)
  end
  write({ "reading the hygiene plan..." })
  M.refresh()
end

--- Register :SageFsHygiene.
---@param port function returns the daemon port
function M.register(port)
  port_fn = port or port_fn
  vim.api.nvim_create_user_command("SageFsHygiene", function() M.open() end, {
    desc = "Show what agents left behind and the dry-run plan of what could be reclaimed",
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("SageFsHygieneView", { clear = true }),
    callback = function() if client then client.close() end end,
  })
end

return M