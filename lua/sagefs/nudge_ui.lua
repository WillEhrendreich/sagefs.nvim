-- sagefs/nudge_ui.lua — :SageFsNudge, the editor side of nudging a value
-- REQUIRES vim (in the real deps); the flow itself takes every effect from a `deps`
-- table, so it runs under busted against a fake daemon, buffer and picker.
--
-- The daemon's nudge_value tool changes ONE value in a source file the session owns
-- and writes the file. So the flow is:
--
--   refuse a buffer with unsaved edits   (the daemon writes the file on disk)
--   inspect the file                     (every value: address, text, hash)
--   find the value under the cursor      (sagefs.nudge.locate; ties are offered)
--   set it with the hash inspect gave    (a stale one is refused by the daemon)
--   show the reply, and reload the buffer when the file was written
--
-- undo and redo skip the first steps: they step through what the tool wrote to
-- this file. Every call names the session by its working directory. Nothing polls:
-- one command is two calls (inspect, then set), and a bump is a keypress.
--
-- The daemon's own words for a refusal (its rule and next action) are shown as
-- they came. Only what the editor can know is added here.

local nudge = require("sagefs.nudge")

local M = {}

local LEVELS = (vim and vim.log and vim.log.levels) or { INFO = 1, WARN = 2, ERROR = 3 }

local WROTE_THE_FILE = { Written = true, Undone = true, Redone = true }

-- ─── The flow ────────────────────────────────────────────────────────────────

local function format_item(item)
  return string.format("%s  =  %s", item.address, (item.text:gsub("\n", " ")))
end

--- Run one :SageFsNudge command.
---@param deps table { buffer, working_directory, call, notify, select, input, reload }
---@param cmd table from nudge.parse_command
---@param count number|nil
function M.execute(deps, cmd, count)
  count = (count and count > 0) and count or 1
  local buf = deps.buffer()
  local refusal = nudge.unsaved_refusal(buf)
  if refusal then
    deps.notify(refusal, LEVELS.WARN)
    return
  end
  local working_directory = deps.working_directory()

  local function args(extra)
    extra.file = buf.name
    extra.working_directory = working_directory
    return nudge.build_args(extra)
  end

  local function finish(reply)
    local text, level = nudge.describe(reply)
    deps.notify(text, level)
    if WROTE_THE_FILE[reply.outcome] then deps.reload() end
  end

  --- True while the buffer is the one the picture of it was taken from. A reply that
  --- arrives after the user typed describes a buffer that is gone.
  local function unchanged()
    local now = deps.buffer()
    if now.tick == buf.tick then return true end
    deps.notify("SageFs nudge: the buffer changed while the daemon was answering, so nothing was written. Run it again.", LEVELS.WARN)
    return false
  end

  if cmd.action == "undo" or cmd.action == "redo" then
    deps.call(args({ action = cmd.action }), finish)
    return
  end

  deps.call(args({ action = "inspect" }), function(reply)
    if reply.outcome ~= "Inspected" then
      finish(reply)
      return
    end
    if not unchanged() then return end
    local items = reply.items

    local function send_set(item, field, value)
      if not unchanged() then return end
      local extra = { action = "set", address = item.address, seen = item.hash }
      extra[field] = value
      deps.call(args(extra), finish)
    end

    --- Set `item` to `given`, or to what the user types (starting from its text).
    local function set_item(item, given, as_expression)
      local field = (as_expression or item.kind == "Formula") and "expression" or "literal"
      if given and given ~= "" then
        send_set(item, field, given)
        return
      end
      deps.input({
        prompt = field == "expression" and ("Expression for " .. item.address .. ": ") or ("Value for " .. item.address .. ": "),
        default = item.text,
      }, function(typed)
        if typed == nil or typed == "" then return end
        send_set(item, field, typed)
      end)
    end

    local function choose(list, prompt, k)
      deps.select(list, { prompt = prompt, format_item = format_item }, function(choice)
        if choice then k(choice) end
      end)
    end

    local function nothing_here(reason)
      local text = "SageFs nudge: " .. reason
      if reply.listing == "Truncated" then
        text = text .. string.format(" (The daemon listed %d of %d values in this file, so this one may be past its limit.)",
          reply.shown or #items, reply.total or #items)
      end
      deps.notify(text, LEVELS.WARN)
    end

    --- The value the cursor means: found, chosen from the ties, or (when `offer_all`)
    --- chosen from every value in the file.
    local function resolve(opts, offer_all, k)
      local found = nudge.locate(items, buf.lines, buf.row, buf.col, opts)
      if found.kind == "one" then
        k(found.item)
      elseif found.kind == "many" then
        choose(found.items, "Nudge which value?", k)
      elseif offer_all and #items > 0 then
        choose(items, "No value under the cursor. Nudge which one?", k)
      else
        nothing_here(found.reason)
      end
    end

    if cmd.action == "list" then
      choose(items, "Values in this file", function(item) set_item(item, nil, false) end)
    elseif cmd.action == "up" or cmd.action == "down" then
      resolve({ knob_only = true }, false, function(item)
        local literal, why = nudge.bump(item, cmd.action == "up" and 1 or -1, count, cmd.step)
        if not literal then
          deps.notify("SageFs nudge: " .. why, LEVELS.WARN)
          return
        end
        send_set(item, "literal", literal)
      end)
    elseif cmd.action == "set" then
      resolve({}, true, function(item) set_item(item, cmd.value, false) end)
    elseif cmd.action == "expr" then
      resolve({}, true, function(item) set_item(item, cmd.value, true) end)
    end
  end)
end

-- ─── Real dependencies ───────────────────────────────────────────────────────

local client = nil

local function get_client(plugin)
  if not client then client = require("sagefs.mcp_client").connect(plugin.config.port) end
  return client
end

--- Read the file again from disk, keeping the cursor, after the daemon wrote it.
--- A buffer the user has started editing since is left alone and said so: reading
--- the file would throw those edits away.
local function reload_buffer(buf, notify)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if vim.bo[buf].modified then
    notify("SageFs nudge: the daemon wrote the file, but this buffer has edits since, so it was not reloaded. :edit! loads the daemon's version.", LEVELS.WARN)
    return
  end
  local saved = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do saved[win] = vim.api.nvim_win_get_cursor(win) end
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent! edit") end)
  for win, pos in pairs(saved) do pcall(vim.api.nvim_win_set_cursor, win, pos) end
end

--- Deps backed by Neovim, for the buffer the command ran in.
local function real_deps(plugin, helpers)
  local buf = vim.api.nvim_get_current_buf()
  local notify = function(msg, level) vim.notify(msg, level or LEVELS.INFO) end
  return {
    buffer = function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      return {
        name = vim.api.nvim_buf_get_name(buf),
        modified = vim.bo[buf].modified,
        lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
        row = cursor[1],
        col = cursor[2],
        tick = vim.api.nvim_buf_get_changedtick(buf),
      }
    end,
    working_directory = function() return nudge.working_directory(plugin.active_session, vim.fn.getcwd()) end,
    call = function(call_args, cb)
      get_client(plugin).call_tool(nudge.TOOL, call_args, function(ok, text)
        vim.schedule(function() cb(nudge.parse_reply(ok, text)) end)
      end)
    end,
    notify = notify,
    select = function(list, opts, cb) vim.ui.select(list, opts, cb) end,
    input = function(opts, cb) vim.ui.input(opts, cb) end,
    reload = function() reload_buffer(buf, notify) end,
  }
end

--- Run one parsed command in the current buffer.
function M.run(plugin, helpers, cmd, count)
  M.execute(real_deps(plugin, helpers), cmd, count)
end

-- ─── Registration ────────────────────────────────────────────────────────────

local function complete(arglead, cmdline)
  local rest = (cmdline or ""):match("^[%s%d,%.%$%%']*%a+!?%s+(.*)$")
  if rest == nil or rest:find("%s") then return {} end
  local out = {}
  for _, action in ipairs(nudge.ACTIONS) do
    if action:sub(1, #arglead) == arglead then table.insert(out, action) end
  end
  return out
end

---@param create_user_command function|nil defaults to nvim_create_user_command
function M.register(plugin, helpers, create_user_command)
  create_user_command = create_user_command or vim.api.nvim_create_user_command

  create_user_command("SageFsNudge", function(cmd)
    local parsed = nudge.parse_command(cmd.args or "")
    if parsed.error then
      helpers.notify(parsed.error, LEVELS.WARN)
      return
    end
    M.run(plugin, helpers, parsed, cmd.count)
  end, {
    nargs = "*",
    count = 0,
    complete = complete,
    desc = "Nudge the value under the cursor in the daemon's session: up|down [step] (a count repeats), set [value], expr [expression], undo, redo, list",
  })

  if vim and vim.api and vim.api.nvim_create_autocmd and create_user_command == vim.api.nvim_create_user_command then
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("SageFsNudge", { clear = true }),
      callback = function() if client then client.close() end end,
    })
  end
end

--- Buffer-local maps, all under <leader>rk (k for knob). A count repeats a bump:
--- 5<leader>rk+ is five steps.
function M.register_keymaps(plugin, helpers, bufnr)
  local function map(lhs, cmd, desc, counted)
    vim.keymap.set("n", lhs, function()
      M.run(plugin, helpers, cmd, counted and vim.v.count1 or 1)
    end, { desc = desc, silent = true, buffer = bufnr })
  end
  map("<leader>rk+", { action = "up" }, "SageFs: nudge the value under the cursor up (a count repeats)", true)
  map("<leader>rk-", { action = "down" }, "SageFs: nudge the value under the cursor down (a count repeats)", true)
  map("<leader>rks", { action = "set" }, "SageFs: set the value under the cursor to a typed literal")
  map("<leader>rke", { action = "expr" }, "SageFs: replace the value under the cursor with an expression")
  map("<leader>rku", { action = "undo" }, "SageFs: undo the last nudge in this file")
  map("<leader>rkr", { action = "redo" }, "SageFs: redo the nudge that was undone")
  map("<leader>rkl", { action = "list" }, "SageFs: list the values in this file and nudge one")

  local ok, wk = pcall(require, "which-key")
  if ok and wk.add then
    wk.add({ { "<leader>rk", group = "SageFs nudge", buffer = bufnr } })
  end
end

return M
