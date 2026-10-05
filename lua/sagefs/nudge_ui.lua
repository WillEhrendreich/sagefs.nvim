-- sagefs/nudge_ui.lua — :SageFsNudge, the editor side of nudging a value
-- REQUIRES vim (in the real deps); the flow itself takes every effect from a `deps`
-- table, so it runs under busted against a fake daemon, buffer and picker.
--
-- The daemon's nudge_value tool changes ONE value in a source file the session owns
-- and writes the file. So the flow is:
--
--   refuse a buffer with unsaved edits   (the daemon writes the file on disk)
--   inspect the file                     (every value: address, text, hash, range, typed value)
--   find the value under the cursor      (sagefs.nudge.locate, by range; a value inside another is offered)
--   set it with the hash inspect gave    (a stale one is refused by the daemon)
--   show the reply, and reload the buffer when the file was written
--
-- undo and redo skip the first steps: they step through what the tool wrote to
-- this file. Every call names the session by its working directory. Nothing polls:
-- one command is two calls (inspect, then set), and a bump is a keypress.
--
-- One flow runs at a time per buffer and the rest wait in order (new_gate): a
-- second command that started before the first one's reload would see the buffer
-- change under it, and a key held down starts many.
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

--- Run one :SageFsNudge command. `on_done` is called exactly once, when the flow is
--- over: written, refused, failed, cancelled or turned away.
---@param deps table { buffer, working_directory, call, notify, select, input, reload }
---@param cmd table from nudge.parse_command
---@param count number|nil
---@param on_done function|nil
function M.execute(deps, cmd, count, on_done)
  count = (count and count > 0) and count or 1
  local over = false
  local function done()
    if over then return end
    over = true
    if on_done then on_done() end
  end
  --- Say something and end.
  local function stop(text, level)
    deps.notify(text, level)
    done()
  end

  local buf = deps.buffer()
  local refusal = nudge.unsaved_refusal(buf)
  if refusal then
    stop(refusal, LEVELS.WARN)
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
    done()
  end

  --- True while the buffer is the one the picture of it was taken from. A reply that
  --- arrives after the user typed describes a buffer that is gone.
  local function unchanged()
    if deps.buffer().tick == buf.tick then return true end
    stop("SageFs nudge: the buffer changed while the daemon was answering, so nothing was written. Run it again.", LEVELS.WARN)
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
        if typed == nil or typed == "" then
          done()
          return
        end
        send_set(item, field, typed)
      end)
    end

    local function choose(list, prompt, k)
      deps.select(list, { prompt = prompt, format_item = format_item }, function(choice)
        if choice then k(choice) else done() end
      end)
    end

    local function nothing_here(reason)
      local text = "SageFs nudge: " .. reason
      if reply.listing == "Truncated" then
        text = text .. string.format(" (The daemon listed %d of %d values in this file, so this one may be past its limit.)",
          reply.shown or #items, reply.total or #items)
      end
      stop(text, LEVELS.WARN)
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
          stop("SageFs nudge: " .. why, LEVELS.WARN)
          return
        end
        send_set(item, "literal", literal)
      end)
    elseif cmd.action == "set" then
      resolve({}, true, function(item) set_item(item, cmd.value, false) end)
    elseif cmd.action == "expr" then
      resolve({}, true, function(item) set_item(item, cmd.value, true) end)
    else
      stop("SageFs nudge: nothing to do for '" .. tostring(cmd.action) .. "'.", LEVELS.WARN)
    end
  end)
end

-- ─── One flow at a time ──────────────────────────────────────────────────────

--- A gate that runs one flow at a time per key and holds the rest, in order.
--- `start(done)` is the flow; it must call done() when it is over (a second call
--- is ignored). A flow that raises is reported and does not wedge the key.
---@param limit number|nil how many may wait behind the running one (default 20)
---@return table gate { submit = fun(key, start): boolean }
function M.new_gate(limit)
  limit = limit or 20
  local running, waiting = {}, {}
  local gate = {}

  local function launch(key, start)
    running[key] = true
    local finished = false
    local function done()
      if finished then return end
      finished = true
      running[key] = nil
      local queue = waiting[key]
      local nextstart = queue and table.remove(queue, 1)
      if nextstart then launch(key, nextstart) end
    end
    local ok, err = pcall(start, done)
    if not ok then
      vim.notify("SageFs nudge failed: " .. tostring(err), LEVELS.ERROR)
      done()
    end
  end

  --- @return boolean accepted false when the queue behind the running flow is full
  function gate.submit(key, start)
    if not running[key] then
      launch(key, start)
      return true
    end
    local queue = waiting[key]
    if not queue then
      queue = {}
      waiting[key] = queue
    end
    if #queue >= limit then return false end
    queue[#queue + 1] = start
    return true
  end

  return gate
end

-- ─── Real dependencies ───────────────────────────────────────────────────────

local client = nil
local gate = M.new_gate()

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
local function real_deps(plugin, buf)
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

--- Run one parsed command in the current buffer. It waits its turn behind a
--- command still running in the same buffer.
function M.run(plugin, helpers, cmd, count)
  local buf = vim.api.nvim_get_current_buf()
  -- The cursor is where it is when the command is typed, not when its turn comes.
  local at = vim.api.nvim_win_get_cursor(0)
  local accepted = gate.submit(buf, function(done)
    local deps = real_deps(plugin, buf)
    local win_buffer = deps.buffer
    deps.buffer = function()
      local snapshot = win_buffer()
      snapshot.row, snapshot.col = math.min(at[1], #snapshot.lines), at[2]
      return snapshot
    end
    M.execute(deps, cmd, count, done)
  end)
  if not accepted then
    vim.notify("SageFs nudge: too many nudges are waiting on the daemon; this one was dropped.", LEVELS.WARN)
  end
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
