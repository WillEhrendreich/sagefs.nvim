-- sagefs/bindings_view.lua — The live bindings view (:SageFsBindings)
--
-- A scratch buffer in a split showing the daemon's live bindings tree for the
-- active session. The model is sagefs.live_bindings (a pure fold over the
-- `live_bindings` SSE snapshots). This module owns the three things you can do
-- from the pane, all of which go to the daemon and come back as a new snapshot
-- on the event stream (so the tree is never patched from an HTTP answer):
--
--   click   <CR> on a "not evaluated" getter runs that one getter
--   mode    m switches Safe / Everything / Off for this session
--   refresh r asks for the current snapshot (there is no snapshot GET, so it
--           re-posts the current mode, which makes the daemon walk and push)
--
-- The controller (new_controller) takes its HTTP and UI as deps, so it runs
-- under busted against a fake HTTP layer. The buffer and window code at the
-- bottom is exercised in headless Neovim against the dev daemon.

local lb = require("sagefs.live_bindings")

local M = {}

local LEVELS = (vim and vim.log and vim.log.levels) or { INFO = 1, WARN = 2, ERROR = 3 }

-- A click runs a getter under a 5 s deadline on the daemon; leave room around it.
local CLICK_TIMEOUT_S = 30
local MODE_TIMEOUT_S = 30

--- The mode after `mode` when you press the mode key repeatedly.
function M.next_mode(mode)
  for i, m in ipairs(lb.MODES) do
    if m == mode then return lb.MODES[(i % #lb.MODES) + 1] end
  end
  return lb.MODES[1]
end

-- ─── Controller ──────────────────────────────────────────────────────────────

---@param deps { http: function, base_url: function, session_id: function, notify: function, on_change: function, confirm: function }
function M.new_controller(deps)
  local ctl = { view = lb.new_view(deps.session_id and deps.session_id() or nil) }
  local view = ctl.view

  local function changed()
    if deps.on_change then deps.on_change() end
  end

  local function sid_or_warn()
    local sid = deps.session_id and deps.session_id() or nil
    if not sid then
      deps.notify("No active session. Try :SageFsCreateSession.", LEVELS.WARN)
      return nil
    end
    view.session_id = sid
    return sid
  end

  local function send(req, timeout, callback)
    deps.http({
      method = req.method,
      url = deps.base_url() .. req.path,
      body = req.body,
      timeout = timeout,
      callback = callback,
    })
  end

  --- Run one "not evaluated" getter (the click).
  function ctl.click(row)
    if not row then return end
    if row.action ~= "click" then
      deps.notify("Nothing to run on this row.", LEVELS.INFO)
      return
    end
    if not lb.click_meaningful(view.mode) then
      view.notice = string.format("Nothing to run: the mode is %s. Press m to change it.", tostring(view.mode))
      changed()
      return
    end
    local sid = sid_or_warn()
    if not sid then return end
    local req = lb.build_click_request(sid, row.binding, row.path)
    send(req, CLICK_TIMEOUT_S, function(ok, raw)
      local r = lb.parse_click_response(ok, raw)
      if not r.ok then
        view.notice = "Click failed: " .. r.error
      else
        -- the new tree arrives as a live_bindings event; only the line is ours
        view.containment = r.containment
        view.notice = r.notice
      end
      changed()
    end)
  end

  --- Switch the walk mode. Everything runs your getters after every eval, so it asks first.
  function ctl.set_mode(mode)
    local sid = sid_or_warn()
    if not sid then return end
    local function go()
      send(lb.build_mode_request(sid, mode), MODE_TIMEOUT_S, function(ok, raw)
        local r = lb.parse_mode_response(ok, raw)
        if r.ok then
          view.mode = r.mode
          -- the daemon drops the last click's line when the mode changes
          view.containment = ""
          view.notice = nil
        else
          view.notice = "Mode not changed: " .. r.error
        end
        changed()
      end)
    end
    if lb.mode_needs_confirmation(mode) then
      deps.confirm("Switch to Everything? " .. lb.mode_blurb(mode), function(yes)
        if yes then go() end
      end)
    else
      go()
    end
  end

  --- Read the mode (and the click's containment line) without changing anything.
  function ctl.read_mode(then_)
    local sid = sid_or_warn()
    if not sid then return end
    send(lb.build_read_mode_request(sid), MODE_TIMEOUT_S, function(ok, raw)
      local r = lb.parse_mode_response(ok, raw)
      if r.ok then
        view.mode = r.mode
        view.containment = r.containment
        view.notice = nil
        changed()
        if then_ then then_(r) end
      else
        view.notice = r.error
        changed()
      end
    end)
  end

  --- Ask the daemon for the current snapshot. There is no snapshot GET: the
  --- daemon pushes one whenever the mode is set, so re-post the mode we just read.
  function ctl.refresh()
    ctl.read_mode(function(read)
      local sid = sid_or_warn()
      if not sid then return end
      send(lb.build_mode_request(sid, read.mode), MODE_TIMEOUT_S, function(ok, raw)
        local r = lb.parse_mode_response(ok, raw)
        if r.ok then
          view.mode = r.mode
          view.containment = ""
        else
          view.notice = "Refresh failed: " .. r.error
        end
        changed()
      end)
    end)
  end

  return ctl
end

-- ─── The buffer and window ───────────────────────────────────────────────────

local pane = nil -- { buf, win, ctl, rows, plugin }
local ns = nil

local HIGHLIGHTS = {
  SageFsBindingsHeader = "Title",
  SageFsBindingsContainment = "DiagnosticInfo",
  SageFsBindingsNotice = "DiagnosticWarn",
  SageFsBindingsHeld = "DiagnosticHint",
  SageFsBindingsFailed = "DiagnosticError",
}

function M.define_highlights()
  for group, link in pairs(HIGHLIGHTS) do
    pcall(vim.api.nvim_set_hl, 0, group, { link = link, default = true })
  end
end

local function pane_open()
  return pane and pane.buf and vim.api.nvim_buf_is_valid(pane.buf)
end

--- Redraw the pane from the plugin's current snapshot and the controller's view.
function M.redraw()
  if not pane_open() then return end
  local plugin = pane.plugin
  local view = pane.ctl.view
  local sid = plugin.active_session and plugin.active_session.id or nil
  view.session_id = sid
  local snapshot = lb.get(plugin.live_bindings_state, sid)
  local rendered = lb.render(snapshot, view)
  pane.rows = rendered.rows

  local win = pane.win and vim.api.nvim_win_is_valid(pane.win) and pane.win or nil
  local cursor = win and vim.api.nvim_win_get_cursor(win) or nil

  vim.bo[pane.buf].modifiable = true
  vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, rendered.lines)
  vim.bo[pane.buf].modifiable = false
  vim.bo[pane.buf].modified = false

  ns = ns or vim.api.nvim_create_namespace("sagefs_bindings_view")
  vim.api.nvim_buf_clear_namespace(pane.buf, ns, 0, -1)
  for _, h in ipairs(rendered.highlights) do
    pcall(vim.api.nvim_buf_set_extmark, pane.buf, ns, h.line - 1, 0, {
      end_row = h.line, end_col = 0, hl_group = h.group, hl_eol = true,
    })
  end

  if win and cursor then
    local last = vim.api.nvim_buf_line_count(pane.buf)
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(cursor[1], last), cursor[2] })
  end
end

local function row_at_cursor()
  if not pane_open() or not pane.win or not vim.api.nvim_win_is_valid(pane.win) then return nil end
  local lnum = vim.api.nvim_win_get_cursor(pane.win)[1]
  return pane.rows and pane.rows[lnum] or nil
end

local function pick_mode()
  local ctl = pane.ctl
  vim.ui.select(lb.MODES, {
    prompt = "Live values mode (now " .. tostring(ctl.view.mode or "?") .. ")",
    format_item = function(mode) return mode .. ": " .. lb.mode_blurb(mode) end,
  }, function(mode)
    if mode then ctl.set_mode(mode) end
  end)
end

--- Open the pane (or focus it) and ask the daemon for what it has.
---@param plugin table  the plugin module (for the active session and the snapshots)
---@param helpers table { base_url: function, notify: function }
function M.open(plugin, helpers)
  plugin.live_bindings_state = plugin.live_bindings_state or lb.new()
  if pane_open() then
    local win = vim.fn.bufwinid(pane.buf)
    if win ~= -1 then vim.api.nvim_set_current_win(win) end
    pane.plugin = plugin
    M.redraw()
    return pane
  end

  M.define_highlights()
  vim.cmd("botright 18new")
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "sagefs-bindings"
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].signcolumn = "no"
  pcall(vim.api.nvim_buf_set_name, buf, "sagefs://bindings")

  local ctl = M.new_controller({
    http = require("sagefs.transport").http_json,
    base_url = helpers.base_url,
    session_id = function() return plugin.active_session and plugin.active_session.id or nil end,
    notify = helpers.notify,
    on_change = function() M.redraw() end,
    confirm = function(prompt, cb)
      vim.ui.select({ "Yes", "No" }, { prompt = prompt }, function(choice) cb(choice == "Yes") end)
    end,
  })
  pane = { buf = buf, win = win, ctl = ctl, rows = {}, plugin = plugin }

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "SageFs bindings: " .. desc })
  end
  map("<CR>", function() ctl.click(row_at_cursor()) end, "run the getter on this row")
  map("<Tab>", function()
    local row = row_at_cursor()
    if row and row.expandable then
      require("sagefs.live_bindings").toggle(ctl.view, row.key)
      M.redraw()
    end
  end, "fold or unfold")
  map("m", pick_mode, "switch the walk mode")
  map("r", function() ctl.refresh() end, "refresh from the daemon")
  map("q", function() pcall(vim.api.nvim_win_close, win, true) end, "close")

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf, once = true, callback = function() pane = nil end,
  })

  M.redraw()
  -- Show what the daemon has. With a snapshot already folded, only read the mode.
  local sid = plugin.active_session and plugin.active_session.id or nil
  if sid then
    if lb.get(plugin.live_bindings_state, sid) then ctl.read_mode() else ctl.refresh() end
  end
  return pane
end

--- Called from the SSE handler after a snapshot was folded.
function M.on_snapshot()
  if pane_open() then M.redraw() end
end

--- Close the pane if it is open (tests, :SageFsDisconnect style cleanups).
function M.close()
  if pane_open() and pane.win and vim.api.nvim_win_is_valid(pane.win) then
    pcall(vim.api.nvim_win_close, pane.win, true)
  end
  pane = nil
end

return M
