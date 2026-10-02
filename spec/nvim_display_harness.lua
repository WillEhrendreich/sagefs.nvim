-- spec/nvim_display_harness.lua — headless-Neovim specs for how results and
-- sessions appear (render placement, :SageFsResult, :SageFsHelp, the hint).
-- Usage: nvim --headless --clean -u NONE -l spec/nvim_display_harness.lua
-- Self-contained like spec/nvim_harness.lua (no busted); exits non-zero on failure.

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
-- absolute: several specs :cd into temp checkouts and modules load lazily
local plugin_root = vim.fn.fnamemodify(script_dir .. "..", ":p"):gsub("[/\\]$", "")
vim.opt.rtp:prepend(plugin_root)
package.path = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;" .. package.path

local passed, failed, errors = 0, 0, {}
local suite = ""
local function describe(name, fn) suite = name; fn(); suite = "" end
local function it(name, fn)
  local label = suite ~= "" and (suite .. " > " .. name) or name
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write("  ✓ " .. label .. "\n")
  else
    failed = failed + 1
    errors[#errors + 1] = { label = label, err = tostring(err) }
    io.write("  ✖ " .. label .. "\n    " .. tostring(err) .. "\n")
  end
end
local function ok_(v, msg) if not v then error(msg or ("expected truthy, got " .. tostring(v)), 2) end end
local function eq(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", msg or "eq", tostring(expected), tostring(actual)), 2)
  end
end

local model = require("sagefs.model")
local render = require("sagefs.render")

local function make_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

--- A `;;`-terminated cell of `n` lines (lines 1..n, `;;` on line n).
local function tall_cell_lines(n)
  local lines = {}
  for i = 1, n - 1 do lines[i] = "let v" .. i .. " = " .. i end
  lines[n] = "v1;;"
  return lines
end

local function result_of(n_lines)
  local out = {}
  for i = 1, n_lines do out[i] = "res" .. i end
  return table.concat(out, "\n")
end

local function evaluated(buf, id, output, meta)
  local state = model.new()
  meta = meta or {}
  meta.buf = buf
  state = model.set_cell_state(state, id, "running", nil, meta)
  state = model.set_cell_state(state, id, "success", output, meta)
  return state
end

--- marks that draw result text: { row0, virt_lines = n, virt_text = string|nil, last = string|nil }
local function result_marks(buf)
  local out = {}
  local marks = vim.api.nvim_buf_get_extmarks(buf, render.get_namespace(), 0, -1, { details = true })
  for _, m in ipairs(marks) do
    local d = m[4] or {}
    local vl = d.virt_lines
    local is_codelens = vl and vl[1] and vl[1][1] and vl[1][1][1] == "▶ Eval"
    if not is_codelens and (d.virt_text or vl) then
      local last
      if vl and vl[#vl] and vl[#vl][1] then last = vl[#vl][1][1] end
      out[#out + 1] = {
        row0 = m[2],
        virt_lines = vl and #vl or 0,
        virt_text = d.virt_text and d.virt_text[1] and d.virt_text[1][1] or nil,
        last = last,
      }
    end
  end
  return out
end

io.write("\n═══ sagefs.nvim display specs (headless Neovim) ═══\n\n")

describe("result placement in a real window", function()
  it("shows the result of a cell taller than the window, anchored where the user evaluated", function()
    local buf = make_buffer(tall_cell_lines(120))
    vim.api.nvim_win_set_cursor(0, { 10, 0 })
    vim.cmd("normal! zt")
    local state = evaluated(buf, 1, result_of(5), { end_line = 120, anchor_line = 10 })
    render.render_all(buf, state)
    local top, bot = vim.fn.line("w0"), vim.fn.line("w$")
    local marks = result_marks(buf)
    ok_(#marks >= 1, "a result is drawn")
    for _, m in ipairs(marks) do
      ok_(m.row0 + 1 >= top and m.row0 + 1 <= bot,
        string.format("result on line %d is outside the window %d..%d", m.row0 + 1, top, bot))
    end
    eq(9, marks[1].row0, "anchored on the evaluated line (10)")
  end)

  it("keeps a short result on the cell's last line, as before", function()
    local buf = make_buffer({ "let a = 1", "a + 1;;", "", "let b = 2;;" })
    local state = evaluated(buf, 1, "val it: int = 2", { end_line = 2, anchor_line = 1 })
    render.render_all(buf, state)
    local marks = result_marks(buf)
    ok_(#marks >= 1)
    eq(1, marks[1].row0, "cell end line (2)")
  end)

  it("draws a single-line result inline only, without a duplicate virtual line", function()
    local buf = make_buffer({ "let a = 1", "a + 1;;" })
    local state = evaluated(buf, 1, "val it: int = 2", { end_line = 2, anchor_line = 2 })
    render.render_all(buf, state)
    local total_virt_lines = 0
    local inline
    for _, m in ipairs(result_marks(buf)) do
      total_virt_lines = total_virt_lines + m.virt_lines
      inline = inline or m.virt_text
    end
    eq(0, total_virt_lines, "no virtual lines for a one-line result")
    ok_(inline and inline:find("val it: int = 2", 1, true), "inline text carries the result")
  end)

  it("truncates a tall result with an 'N more lines, <key> to expand' footer", function()
    local buf = make_buffer({ "let a = 1", "a + 1;;" })
    local state = evaluated(buf, 1, result_of(80), { end_line = 2, anchor_line = 2 })
    render.render_all(buf, state)
    local m
    for _, mk in ipairs(result_marks(buf)) do if mk.virt_lines > 0 then m = mk end end
    ok_(m, "virtual lines drawn")
    ok_(m.virt_lines <= vim.api.nvim_win_get_height(0), "fits the window")
    ok_(m.last:find("more lines", 1, true) and m.last:find("to expand", 1, true), "footer: " .. tostring(m.last))
    ok_(m.last:find("<leader>rE", 1, true), "footer names the key: " .. tostring(m.last))
  end)

  it("cuts the inline summary to the room on the line instead of running off the edge", function()
    local buf = make_buffer({ "let a = 1", "a + 1;;" })
    local long = "Evaluation failed: " .. string.rep("because of an earlier error ", 12)
    local state = model.new()
    state = model.set_cell_state(state, 1, "running", nil, { buf = buf })
    state = model.set_cell_state(state, 1, "error", long, { buf = buf, end_line = 2, anchor_line = 2 })
    render.render_all(buf, state)
    local width = vim.api.nvim_win_get_width(0)
    for _, m in ipairs(result_marks(buf)) do
      if m.virt_text then
        ok_(vim.fn.strdisplaywidth("a + 1;;" .. m.virt_text) <= width,
          "inline text overflows the window: " .. vim.fn.strdisplaywidth(m.virt_text) .. " > " .. width)
      end
    end
  end)

  it("does not draw another buffer's cell result (cell ids are per buffer, not global)", function()
    local a = make_buffer({ "let a = 1;;" })
    local b = make_buffer({ "let b = 2;;" })
    local state = evaluated(a, 1, "val a: int = 1", { end_line = 1, anchor_line = 1 })
    render.render_all(b, state)
    eq(0, #result_marks(b), "buffer b must not show buffer a's result")
    render.render_all(a, state)
    ok_(#result_marks(a) > 0, "buffer a still shows its own result")
  end)

  it("does not count the previous cell's result lines when they sit above the top of the window", function()
    -- nvim_win_text_height counts the filler above the first row: the 8 virtual
    -- lines under line 40 are NOT on screen when the window starts at line 41,
    -- but they were charged to the next result, which then found "no room" and
    -- was pushed to the top of its cell (seen in a real 14-row terminal).
    local lines = {}
    for i = 1, 39 do lines[i] = "let a" .. i .. " = " .. i end
    lines[40] = "a1;;"
    for i = 41, 99 do lines[i] = "let b" .. i .. " = " .. i end
    lines[100] = "b41;;"
    local buf = make_buffer(lines)
    vim.cmd("resize 12")
    vim.api.nvim_win_set_cursor(0, { 45, 0 })
    vim.cmd("normal! 41Gzt45G")
    eq(41, vim.fn.line("w0"), "window starts at the second cell")
    local state = model.new()
    state = model.set_cell_state(state, 1, "running", nil, { buf = buf })
    state = model.set_cell_state(state, 1, "success", result_of(8), { buf = buf, end_line = 40, anchor_line = 40 })
    state = model.set_cell_state(state, 2, "running", nil, { buf = buf })
    state = model.set_cell_state(state, 2, "success", result_of(3), { buf = buf, end_line = 100, anchor_line = 45 })
    render.render_all(buf, state)
    local second
    for _, m in ipairs(result_marks(buf)) do
      if m.row0 + 1 >= 41 and (m.virt_lines > 0 or m.virt_text) then second = second or m end
    end
    ok_(second, "the second cell's result is drawn in the window")
    eq(44, second.row0, "anchored on the evaluated line (45), not shoved to the top of the cell")
  end)

  it("re-anchors inside the window when the view scrolls away from the first anchor", function()
    local buf = make_buffer(tall_cell_lines(200))
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    vim.cmd("normal! zt")
    local state = evaluated(buf, 1, result_of(3), { end_line = 200, anchor_line = 5 })
    render.render_all(buf, state)
    vim.api.nvim_win_set_cursor(0, { 120, 0 })
    vim.cmd("normal! zt")
    render.render_all(buf, state)
    local top, bot = vim.fn.line("w0"), vim.fn.line("w$")
    for _, m in ipairs(result_marks(buf)) do
      ok_(m.row0 + 1 >= top and m.row0 + 1 <= bot,
        string.format("result on line %d is outside the window %d..%d", m.row0 + 1, top, bot))
    end
  end)
end)

describe("a slow eval says why", function()
  --- Drive eval_cell with a transport where /exec never answers and the
  --- session list says whatever `sessions_reply` says.
  local function slow_eval(sessions_reply)
    local sagefs = require("sagefs")
    sagefs.setup({ auto_connect = false })
    local config = require("sagefs.config")
    config.EVAL_SLOW_AFTER_MS = 80
    config.EVAL_STATUS_POLL_MS = 80
    local transport = require("sagefs.transport")
    local original = transport.http_json
    local notices = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level) notices[#notices + 1] = msg end
    transport.http_json = function(opts)
      if opts.url:find("/api/sessions$") then
        vim.schedule(function() opts.callback(sessions_reply ~= nil, sessions_reply or "") end)
      end
      -- POST /exec: never answers
    end
    local buf = make_buffer({ "let a = 1;;" })
    sagefs.active_session = { id = "s1", name = "Demo", status = "Ready", projects = { "Demo.fsproj" }, working_directory = vim.fn.getcwd() }
    sagefs.eval_cell()
    local cell
    vim.wait(2500, function()
      cell = sagefs.state.cells[1]
      return cell and cell.pending_text ~= nil
    end, 20)
    -- let a draw happen
    vim.wait(100, function() return false end, 20)
    transport.http_json = original
    vim.notify = original_notify
    -- the eval never completes: stop its status watcher polling
    sagefs.state = model.clear_cells(sagefs.state)
    return { buf = buf, cell = cell, notices = notices, sagefs = sagefs }
  end

  local function sessions_json(status)
    return vim.json.encode({ sessions = { {
      id = "s1", status = status, projects = { "Demo.fsproj" }, workingDirectory = vim.fn.getcwd(), evalCount = 0,
    } } })
  end

  it("names a warming session after the bound, from the daemon's own session list", function()
    local r = slow_eval(sessions_json("WarmingUp"))
    ok_(r.cell and r.cell.pending_text, "the running cell carries a status")
    ok_(r.cell.pending_text:find("warming", 1, true), "says warming: " .. tostring(r.cell.pending_text))
    local shown
    for _, m in ipairs(result_marks(r.buf)) do shown = shown or m.virt_text end
    ok_(shown and shown:find("warming", 1, true), "the status is on screen: " .. tostring(shown))
    local said = false
    for _, n in ipairs(r.notices) do if n:find("warming", 1, true) then said = true end end
    ok_(said, "and the message line says so once")
  end)

  it("says the daemon is unreachable when the session probe fails", function()
    local r = slow_eval(nil)
    ok_(r.cell and r.cell.pending_text, "the running cell carries a status")
    ok_(r.cell.pending_text:find("not reachable", 1, true), "says unreachable: " .. tostring(r.cell.pending_text))
  end)

  it("says the eval is simply running when the session is Ready", function()
    local r = slow_eval(sessions_json("Ready"))
    ok_(r.cell and r.cell.pending_text and r.cell.pending_text:find("running", 1, true),
      "says running: " .. tostring(r.cell and r.cell.pending_text))
  end)
end)

describe("routing an eval by working directory", function()
  local function sess(id, dir, status, project)
    return { id = id, name = project or id, status = status or "Ready", projects = { (project or "App") .. ".fsproj" },
      working_directory = dir, eval_count = 0 }
  end

  --- A checkout (has .git) with one F# file, as the current buffer.
  local function checkout_buffer(name)
    local root = vim.fn.tempname() .. "_" .. name
    vim.fn.mkdir(root .. "/.git", "p")
    vim.fn.mkdir(root .. "/src", "p")
    vim.fn.writefile({ "<Project />" }, root .. "/src/App.fsproj")
    vim.cmd("cd " .. vim.fn.fnameescape(root))
    local buf = make_buffer({ "let a = 1;;" })
    vim.api.nvim_buf_set_name(buf, root .. "/src/A.fs")
    return buf, root
  end

  --- Run `guarded()` with a daemon that lists `list`; the user picks `choose(items)` (index or nil).
  local function run(list, active, choose, opts)
    local sagefs = require("sagefs")
    sagefs.setup({ auto_connect = false })
    local originals = { list = sagefs.list_sessions, select = vim.ui.select, notify = vim.notify }
    local record = { evals = 0, listed = 0, selects = {}, notices = {} }
    sagefs.session_overrides = {}
    sagefs.active_session = active
    sagefs.session_list = (opts and opts.cached) or {}
    sagefs.list_sessions = function(cb)
      record.listed = record.listed + 1
      sagefs.session_list = list
      cb({ ok = true, sessions = list })
    end
    vim.ui.select = function(items, o, on_choice)
      record.selects[#record.selects + 1] = { items = items, prompt = o and o.prompt }
      local idx = choose and choose(items)
      on_choice(idx and items[idx] or nil, idx)
    end
    vim.notify = function(msg) record.notices[#record.notices + 1] = msg end
    local created
    local original_create = sagefs.discover_and_create
    sagefs.discover_and_create = function(dir) created = dir end
    local guarded = sagefs.smart_eval_with_session_check(function() record.evals = record.evals + 1 end)
    guarded()
    if opts and opts.twice then guarded() end
    sagefs.list_sessions = originals.list
    vim.ui.select = originals.select
    vim.notify = originals.notify
    sagefs.discover_and_create = original_create
    record.created = created
    record.active = sagefs.active_session
    return record
  end

  it("does not evaluate in another directory's session; offers to create one for THIS directory", function()
    local _, root = checkout_buffer("a")
    local other = sess("other001", "/somewhere/else", "Ready", "Elsewhere")
    local r = run({ other }, other, function() return nil end)
    eq(0, r.evals, "no eval was sent")
    eq(1, #r.selects, "the user is asked")
    local joined = table.concat(r.selects[1].items, "\n")
    ok_(joined:find("Create a session for " .. root, 1, true), "offers to create here: " .. joined)
    ok_(joined:find("other001", 1, true) and joined:find("/somewhere/else", 1, true), "names the existing session and its directory: " .. joined)
    local said = false
    for _, n in ipairs(r.notices) do
      if n:find("No active session for this directory", 1, true) and n:find("nothing was sent", 1, true) then said = true end
    end
    ok_(said, "says nothing was sent: " .. table.concat(r.notices, " | "))
  end)

  it("creates the session for this directory when the user picks that", function()
    local _, root = checkout_buffer("b")
    local r = run({ sess("other001", "/somewhere/else") }, nil, function(items) return 1 end)
    eq(root, r.created, "discover_and_create called for the checkout root")
    eq(0, r.evals)
  end)

  it("evaluates in another directory's session only after an explicit choice, and remembers it", function()
    checkout_buffer("c")
    local other = sess("other001", "/somewhere/else", "Ready", "Elsewhere")
    local r = run({ other }, nil, function(items)
      for i, item in ipairs(items) do if item:find("Evaluate in", 1, true) then return i end end
    end, { twice = true })
    eq(2, r.evals, "evaluated both times")
    eq(1, #r.selects, "asked once: the choice is remembered for this directory")
    eq("other001", r.active.id)
  end)

  it("switches to the session that belongs to this directory without asking", function()
    local _, root = checkout_buffer("d")
    local mine = sess("mine0001", root, "Ready", "App")
    local other = sess("other001", "/somewhere/else")
    local r = run({ other, mine }, other, nil)
    eq(1, r.evals, "evaluated")
    eq(0, #r.selects, "no prompt")
    eq("mine0001", r.active.id, "routed to this directory's session")
  end)

  it("skips the network when the active session already belongs to this directory", function()
    local _, root = checkout_buffer("e")
    local mine = sess("mine0001", root, "Ready", "App")
    local r = run({ mine }, mine, nil, { cached = { mine } })
    eq(1, r.evals)
    eq(0, r.listed, "no round trip")
  end)

  it("does not route a worktree to the main checkout's session", function()
    local root = vim.fn.tempname() .. "_main"
    local wt = root .. "/.claude/worktrees/agent-x"
    vim.fn.mkdir(root .. "/.git", "p")
    vim.fn.mkdir(wt .. "/src", "p")
    vim.fn.writefile({ "gitdir: " .. root .. "/.git/worktrees/agent-x" }, wt .. "/.git")
    vim.fn.writefile({ "<Project />" }, wt .. "/src/App.fsproj")
    vim.cmd("cd " .. vim.fn.fnameescape(wt))
    local buf = make_buffer({ "let a = 1;;" })
    vim.api.nvim_buf_set_name(buf, wt .. "/src/A.fs")
    local main_session = sess("main0001", root, "Ready", "App")
    local r = run({ main_session }, main_session, function() return nil end)
    eq(0, r.evals, "the main checkout's session is not the worktree's")
    ok_(table.concat(r.selects[1].items, "\n"):find("Create a session for " .. wt, 1, true), "offers a session for the worktree")
  end)
end)

describe("startup offers a session for this directory on a shared daemon", function()
  it("prompts even though the daemon already has another session", function()
    local root = vim.fn.tempname() .. "_startup"
    vim.fn.mkdir(root .. "/.git", "p")
    vim.fn.writefile({ "<Project />" }, root .. "/App.fsproj")
    vim.cmd("cd " .. vim.fn.fnameescape(root))
    local sagefs = require("sagefs")
    sagefs.setup({ auto_connect = false })
    local original_select = vim.ui.select
    local prompts = {}
    vim.ui.select = function(items, o, cb) prompts[#prompts + 1] = { items = items, prompt = o.prompt }; cb(nil) end
    sagefs.active_session = nil
    local list = { { id = "other001", name = "Elsewhere", status = "Ready", projects = { "E.fsproj" }, working_directory = "/elsewhere", eval_count = 0 } }
    sagefs.offer_session_for_startup({ ok = true, sessions = list })
    vim.ui.select = original_select
    eq(1, #prompts, "asked once")
    ok_(prompts[1].prompt:find("no session", 1, true) or prompts[1].prompt:find("No session", 1, true), "prompt: " .. prompts[1].prompt)
    ok_(prompts[1].prompt:find("1 other", 1, true), "prompt says other sessions exist: " .. prompts[1].prompt)
    ok_(table.concat(prompts[1].items, "\n"):find("App.fsproj", 1, true), "explicit project choice")
  end)

  it("stays quiet when a session already belongs to this directory", function()
    local root = vim.fn.tempname() .. "_startup2"
    vim.fn.mkdir(root .. "/.git", "p")
    vim.fn.writefile({ "<Project />" }, root .. "/App.fsproj")
    vim.cmd("cd " .. vim.fn.fnameescape(root))
    local sagefs = require("sagefs")
    sagefs.setup({ auto_connect = false })
    vim.cmd("enew") -- a fresh buffer: the previous test's file must not decide where we are
    local original_select = vim.ui.select
    local asked = 0
    vim.ui.select = function(_, _, cb) asked = asked + 1; cb(nil) end
    sagefs.active_session = nil
    sagefs.offer_session_for_startup({ ok = true, sessions = {
      { id = "mine0001", name = "App", status = "Ready", projects = { "App.fsproj" }, working_directory = root, eval_count = 0 },
    } })
    vim.ui.select = original_select
    eq(0, asked)
  end)
end)

describe("switching sessions", function()
  it("makes the switched session the one evals go to (it used to keep the old active id)", function()
    local sagefs = require("sagefs")
    sagefs.setup({ auto_connect = false })
    local transport = require("sagefs.transport")
    local original = transport.http_json
    local list = vim.json.encode({ sessions = {
      { id = "s1", status = "Ready", projects = { "A.fsproj" }, workingDirectory = "/a" },
      { id = "s2", status = "Ready", projects = { "B.fsproj" }, workingDirectory = "/b" },
    } })
    transport.http_json = function(opts)
      if opts.url:find("/api/sessions/switch", 1, true) then
        opts.callback(true, vim.json.encode({ success = true, sessionId = "s2", message = "ok" }))
      elseif opts.url:find("/api/sessions$") then
        opts.callback(true, list)
      end
    end
    local original_notify = vim.notify
    vim.notify = function() end
    sagefs.active_session = { id = "s1", status = "Ready", projects = { "A.fsproj" }, working_directory = "/a" }
    sagefs.switch_session("s2")
    transport.http_json = original
    vim.notify = original_notify
    eq("s2", sagefs.active_session and sagefs.active_session.id, "active session after switch")
    eq("Ready", sagefs.active_session.status, "and it is the full record from the list")
  end)
end)

describe(":SageFsHelp and the first-run hint", function()
  it("registers :SageFsHelp", function()
    require("sagefs").setup({ auto_connect = false })
    ok_(vim.api.nvim_get_commands({})["SageFsHelp"], "SageFsHelp is a command")
  end)

  it("every registered :SageFs* command has a description (the help is built from them)", function()
    require("sagefs").setup({ auto_connect = false })
    local missing = {}
    for name, c in pairs(vim.api.nvim_get_commands({})) do
      if name:match("^SageFs") and (c.desc == nil or c.desc == "") then
        missing[#missing + 1] = name
      end
    end
    table.sort(missing)
    ok_(#missing == 0, "commands without a description: " .. table.concat(missing, ", "))
  end)

  it(":SageFsHelp lists every registered command, generated from the live table", function()
    require("sagefs").setup({ auto_connect = false })
    vim.api.nvim_create_user_command("SageFsZzzProbe", function() end, { desc = "A probe added after setup" })
    vim.cmd("SageFsHelp")
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    local text = table.concat(lines, "\n")
    for name in pairs(vim.api.nvim_get_commands({})) do
      if name:match("^SageFs") then
        ok_(text:find(":" .. name .. " ", 1, true), "help is missing :" .. name)
      end
    end
    ok_(text:find("A probe added after setup", 1, true), "and shows its description")
    vim.api.nvim_del_user_command("SageFsZzzProbe")
    vim.cmd("close")
  end)

  it("shows the hint once on the first F# buffer and never again", function()
    local marker = vim.fn.tempname()
    local sagefs = require("sagefs")
    sagefs.setup({ auto_connect = false, hint_marker_path = marker })
    local function float_count()
      local n = 0
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then n = n + 1 end
      end
      return n
    end
    local before = float_count()
    local buf = make_buffer({ "let a = 1" })
    vim.bo[buf].filetype = "fsharp"
    vim.wait(2500, function() return float_count() > before end, 20)
    ok_(float_count() > before, "the hint is on screen")
    ok_(vim.fn.filereadable(marker) == 1, "and remembered")
    -- dismissed by moving
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    vim.wait(500, function() return float_count() == before end, 20)
    eq(before, float_count(), "any move dismisses it")
    -- second F# buffer: no hint
    local buf2 = make_buffer({ "let b = 2" })
    vim.bo[buf2].filetype = "fsharp"
    vim.wait(1800, function() return float_count() > before end, 20)
    eq(before, float_count(), "never again")
    os.remove(marker)
  end)
end)

describe("warmup events from other sessions", function()
  --- Push raw SSE events through the real dispatch pipeline (stub only
  --- transport.connect_sse, as spec/nvim_harness.lua does for §5.4).
  local function push(sagefs, events)
    local transport = require("sagefs.transport")
    local original = transport.connect_sse
    local captured
    transport.connect_sse = function(_url, opts)
      captured = opts.on_events
      return { start = function() end, stop = function() end }
    end
    sagefs.start_sse()
    transport.connect_sse = original
    captured(events)
  end

  it("do not notify or move this editor's warmup state when our session is Ready", function()
    local sagefs = require("sagefs")
    sagefs.setup({ auto_connect = false })
    sagefs.active_session = { id = "mine0001", status = "Ready" }
    sagefs.warmup_phase = nil
    local notices = {}
    local original_notify = vim.notify
    vim.notify = function(msg) notices[#notices + 1] = msg end
    -- legacy shape (no session id) and the 0.6 state shape (with one) for ANOTHER session
    push(sagefs, {
      { type = "warmup_progress", data = vim.json.encode({ Phase = "creating_fsi", Step = 1, Total = 4 }) },
      { type = "state", data = vim.json.encode({ warmupProgress = true, sessionId = "other001", step = 2, total = 4 }) },
      { type = "warmup_progress", data = vim.json.encode({ Phase = "loading_assemblies", Step = 3, Total = 4 }) },
    })
    vim.notify = original_notify
    eq(0, #notices, "no messages: " .. table.concat(notices, " | "))
    eq(nil, sagefs.warmup_phase, "warmup phase untouched")
  end)

  it("still show our own session's warmup progress, and never an empty 'Warming up:'", function()
    local sagefs = require("sagefs")
    sagefs.setup({ auto_connect = false })
    sagefs.active_session = { id = "mine0001", status = "WarmingUp" }
    local notices = {}
    local original_notify = vim.notify
    vim.notify = function(msg) notices[#notices + 1] = msg end
    push(sagefs, {
      { type = "warmup_progress", data = vim.json.encode({ Phase = "creating_fsi", Step = 1, Total = 4 }) },
      -- the 0.6 state-shaped progress event carries no phase: it must not announce "Warming up:" with nothing after it
      { type = "state", data = vim.json.encode({ warmupProgress = true, sessionId = "mine0001", step = 2, total = 4 }) },
    })
    vim.notify = original_notify
    eq(1, #notices, "one message: " .. table.concat(notices, " | "))
    ok_(notices[1]:find("Creating FSI session", 1, true), notices[1])
    for _, n in ipairs(notices) do ok_(not n:match("Warming up:%s*$"), "empty label: " .. n) end
  end)
end)

describe("fault and ready messages from other sessions", function()
  local function run(active, events)
    local sagefs = require("sagefs")
    sagefs.setup({ auto_connect = false })
    sagefs.active_session = active
    sagefs.warmup_expected_until = nil
    local notices = {}
    local original_notify = vim.notify
    vim.notify = function(msg) notices[#notices + 1] = msg end
    local transport = require("sagefs.transport")
    local original = transport.connect_sse
    local captured
    transport.connect_sse = function(_url, opts)
      captured = opts.on_events
      return { start = function() end, stop = function() end }
    end
    sagefs.start_sse()
    transport.connect_sse = original
    captured(events)
    vim.notify = original_notify
    return notices
  end

  it("does not announce another session's fault (a faulted agent session is not this editor's problem)", function()
    local notices = run({ id = "mine0001", status = "Ready" }, {
      { type = "state", data = vim.json.encode({ sessionFaulted = "other001", error = "McpAnalysis.fs(105,93): error FS0039" }) },
    })
    eq(0, #notices, "no message: " .. table.concat(notices, " | "))
  end)

  it("still announces a fault in the active session", function()
    local notices = run({ id = "mine0001", status = "Ready" }, {
      { type = "state", data = vim.json.encode({ sessionFaulted = "mine0001", error = "runtime 99 missing" }) },
    })
    eq(1, #notices)
    ok_(notices[1]:find("runtime 99 missing", 1, true), notices[1])
  end)

  it("does not announce another session becoming ready", function()
    local notices = run({ id = "mine0001", status = "Ready" }, {
      { type = "warmup_completed", data = vim.json.encode({ session_id = "other001", project_count = 2 }) },
    })
    eq(0, #notices, "no message: " .. table.concat(notices, " | "))
  end)

  it("still announces the active session becoming ready", function()
    local notices = run({ id = "mine0001", status = "WarmingUp" }, {
      { type = "warmup_completed", data = vim.json.encode({ session_id = "mine0001", project_count = 2 }) },
    })
    eq(1, #notices)
  end)
end)

describe("the statusline after our session finishes warming", function()
  it("drops the warmup text and shows the session as Ready (it stuck on 'Ready!' and '(Starting)')", function()
    local sagefs = require("sagefs")
    sagefs.setup({ auto_connect = false })
    local transport = require("sagefs.transport")
    local original_http = transport.http_json
    transport.http_json = function(opts)
      if opts.url:find("/api/sessions$") then
        opts.callback(true, vim.json.encode({ sessions = { {
          id = "mine0001", status = "Ready", projects = { "App.fsproj" }, workingDirectory = vim.fn.getcwd(),
        } } }))
      end
    end
    local original_connect = transport.connect_sse
    local captured
    transport.connect_sse = function(_url, opts)
      captured = opts.on_events
      return { start = function() end, stop = function() end }
    end
    local original_notify = vim.notify
    vim.notify = function() end
    sagefs.active_session = { id = "mine0001", name = "App", status = "Starting", projects = { "App.fsproj" }, working_directory = vim.fn.getcwd() }
    sagefs.start_sse()
    captured({ { type = "warmup_progress", data = vim.json.encode({ Phase = "finalizing", Step = 4, Total = 4 }) } })
    ok_(sagefs.statusline():find("Ready!", 1, true), "mid-warmup the statusline says so: " .. sagefs.statusline())
    captured({ { type = "warmup_completed", data = vim.json.encode({ session_id = "mine0001", project_count = 1 }) } })
    vim.wait(150, function() return false end, 10) -- the session list is re-read on the next tick
    transport.http_json = original_http
    transport.connect_sse = original_connect
    vim.notify = original_notify
    eq(nil, sagefs.warmup_phase, "warmup phase cleared")
    local line = sagefs.statusline()
    ok_(not line:find("Ready!", 1, true), "no leftover warmup text: " .. line)
    ok_(line:find("(Ready)", 1, true), "the session reads Ready: " .. line)
  end)
end)

io.write(string.format("\n═══ Results: %d passed, %d failed ═══\n", passed, failed))
for _, e in ipairs(errors) do io.write("  ✖ " .. e.label .. "\n    " .. e.err .. "\n") end
if failed > 0 then vim.cmd("cquit 1") else vim.cmd("qa!") end
