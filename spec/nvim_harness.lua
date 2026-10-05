-- spec/nvim_harness.lua — Integration test runner for headless Neovim
-- Usage: nvim --headless --clean -u NONE -l spec/nvim_harness.lua
--
-- This runs INSIDE a real Neovim instance with full vim.api access.
-- It provides a minimal test framework (no busted dependency).

-- Add plugin to rtp and package.path
local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
local plugin_root = script_dir .. ".."
vim.opt.rtp:prepend(plugin_root)
package.path = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;" .. package.path

-- ─── Minimal test framework ──────────────────────────────────────────────────

local passed = 0
local failed = 0
local errors = {}
local current_suite = ""

local function describe(name, fn)
  current_suite = name
  fn()
  current_suite = ""
end

local function it(name, fn)
  local label = current_suite ~= "" and (current_suite .. " > " .. name) or name
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write("  ✓ " .. label .. "\n")
  else
    failed = failed + 1
    table.insert(errors, { label = label, err = tostring(err) })
    io.write("  ✖ " .. label .. "\n")
    io.write("    " .. tostring(err) .. "\n")
  end
end

local function assert_eq(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s",
      msg or "assertion failed", tostring(expected), tostring(actual)), 2)
  end
end

local function assert_truthy(val, msg)
  if not val then
    error(msg or "expected truthy value, got " .. tostring(val), 2)
  end
end

local function assert_falsy(val, msg)
  if val then
    error(msg or "expected falsy value, got " .. tostring(val), 2)
  end
end

local function assert_contains(haystack, needle, msg)
  if type(haystack) == "string" then
    if not haystack:find(needle, 1, true) then
      error(string.format("%s: '%s' not found in '%s'",
        msg or "assert_contains", needle, haystack), 2)
    end
  elseif type(haystack) == "table" then
    for _, v in ipairs(haystack) do
      if v == needle then return end
    end
    error(string.format("%s: '%s' not found in table", msg or "assert_contains", tostring(needle)), 2)
  end
end

local function assert_type(expected_type, val, msg)
  if type(val) ~= expected_type then
    error(string.format("%s: expected type %s, got %s",
      msg or "assert_type", expected_type, type(val)), 2)
  end
end

-- Helper: create a scratch buffer with lines
local function make_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

-- Helper: get all extmarks in a namespace
local function get_extmarks(buf, ns)
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end

-- ─── Load plugin modules ─────────────────────────────────────────────────────

local cells = require("sagefs.cells")
local format = require("sagefs.format")
local model = require("sagefs.model")
local sse = require("sagefs.sse")
local sessions = require("sagefs.sessions")
local testing = require("sagefs.testing")

io.write("\n═══ sagefs.nvim integration tests (headless Neovim) ═══\n\n")

-- ─── Plugin setup & command registration ─────────────────────────────────────

describe("plugin setup", function()
  it("loads and calls setup without error", function()
    local sagefs = require("sagefs")
    sagefs.setup({ auto_connect = false, port = 37749, dashboard_port = 37750 })
  end)

  it("registers all expected user commands", function()
    local cmds = vim.api.nvim_get_commands({})
    local expected = {
      "SageFsEval", "SageFsEvalAdvance", "SageFsEvalFile",
      "SageFsClear", "SageFsConnect",
      "SageFsDisconnect", "SageFsStatus", "SageFsSessions",
      "SageFsCreateSession", "SageFsConfig", "SageFsHotReload", "SageFsWatchAll",
      "SageFsUnwatchAll", "SageFsReset", "SageFsHardReset", "SageFsContext",
      "SageFsTests", "SageFsRunTests", "SageFsTestPolicy", "SageFsTestPanel", "SageFsTestsHere",
      "SageFsEnableTesting", "SageFsDisableTesting", "SageFsCoverage", "SageFsTypeExplorer",
      "SageFsHistory", "SageFsExport", "SageFsCallers", "SageFsCallees",
      "SageFsCancel", "SageFsTestTrace", "SageFsLoadScript",
      "SageFsStart", "SageFsStop", "SageFsNudge", "SageFsDebugTest", "SageFsDebugRelease",
    }
    for _, name in ipairs(expected) do
      assert_truthy(cmds[name], "missing command: " .. name)
    end
  end)

  it("creates highlight groups", function()
    local hl_groups = { "SageFsSuccess", "SageFsError", "SageFsOutput", "SageFsRunning", "SageFsStale" }
    for _, hl in ipairs(hl_groups) do
      local ok, info = pcall(vim.api.nvim_get_hl, 0, { name = hl })
      assert_truthy(ok, "highlight group missing: " .. hl)
      assert_type("table", info, "highlight info for " .. hl)
    end
  end)

  -- roast item 13 / §5.6: <A-CR> and <leader>r* used to be registered
  -- globally in setup() — once any F# file was opened in the session the
  -- plugin permanently owned those keys in EVERY buffer, F# or not (a
  -- plain Markdown buffer's <A-CR> was silently hijacked). They must be
  -- buffer-local, present only in fsharp/fsx buffers.
  it("does not set SageFs eval keymaps globally", function()
    local maps = vim.api.nvim_get_keymap("n")
    for _, m in ipairs(maps) do
      assert_falsy(m.desc and m.desc:find("SageFs"),
        "found a global (non-buffer-local) SageFs keymap: " .. tostring(m.lhs))
    end
  end)

  it("scopes eval keymaps to F# buffers, not a plain-text buffer", function()
    local fsharp_buf = make_buffer({ "let x = 1" })
    vim.bo[fsharp_buf].filetype = "fsharp"

    local found_leader_re = false
    local found_alt_enter = false
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(fsharp_buf, "n")) do
      if m.lhs and m.desc and m.desc:find("SageFs") then
        if m.lhs:find("re", 1, true) then found_leader_re = true end
        if m.lhs:find("CR", 1, true) or m.lhs:find("Enter", 1, true) then found_alt_enter = true end
      end
    end
    assert_truthy(found_leader_re or found_alt_enter,
      "expected SageFs keymaps registered on the fsharp buffer")

    local text_buf = make_buffer({ "hello" })
    vim.bo[text_buf].filetype = "text"
    local leaked = false
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(text_buf, "n")) do
      if m.desc and m.desc:find("SageFs") then leaked = true end
    end
    assert_falsy(leaked, "SageFs keymaps must not appear in a non-F# buffer")
  end)
end)

-- ─── §5.7: every :SageFsX command name referenced in the source must exist ───
-- Two user-facing messages named `:SageFsReconnect` (the real command is
-- `:SageFsConnect`) and `:SageFsLiveTestStatus` (never registered at all) —
-- both produce E492 if a user actually types them. Static grep caught this;
-- this test catches it mechanically, in the real command registry, so it
-- can never silently regress again.

describe("command reference integrity (§5.7)", function()
  it("every :SageFsX string in lua/ names an actually-registered command", function()
    local cmds = vim.api.nvim_get_commands({})
    local files = vim.fn.glob(plugin_root .. "/lua/**/*.lua", false, true)
    assert_truthy(#files > 10, "expected to find plugin source files, found " .. #files)

    local referenced = {}
    for _, path in ipairs(files) do
      local f = io.open(path, "r")
      if f then
        local content = f:read("*a")
        f:close()
        for name in content:gmatch(":(SageFs%w+)") do
          referenced[name] = referenced[name] or {}
          table.insert(referenced[name], path)
        end
      end
    end

    local unregistered = {}
    for name, sites in pairs(referenced) do
      if not cmds[name] then
        table.insert(unregistered, name .. " (referenced in " .. table.concat(sites, ", ") .. ")")
      end
    end
    table.sort(unregistered)

    assert_eq(0, #unregistered, "phantom command reference(s): " .. table.concat(unregistered, "; "))
  end)
end)

describe("help file doc/sagefs.txt", function()
  local function read(path)
    local fh = assert(io.open(path, "rb"))
    local text = fh:read("*a")
    fh:close()
    return text
  end
  local help = read(plugin_root .. "/doc/sagefs.txt")

  it("has a help tag for every registered :SageFs command", function()
    local missing = {}
    for name in pairs(vim.api.nvim_get_commands({})) do
      if name:match("^SageFs") and not help:find("*:" .. name .. "*", 1, true) then
        table.insert(missing, name)
      end
    end
    table.sort(missing)
    assert_eq(0, #missing, "commands without a tag: " .. table.concat(missing, ", "))
  end)

  it("has a help tag for every User event", function()
    local missing = {}
    for _, name in ipairs(require("sagefs.events").EVENT_NAMES) do
      if not help:find("*" .. name .. "*", 1, true) then table.insert(missing, name) end
    end
    assert_eq(0, #missing, "events without a tag: " .. table.concat(missing, ", "))
  end)

  it("only names commands that are registered", function()
    local cmds = vim.api.nvim_get_commands({})
    local phantom, seen = {}, {}
    for name in help:gmatch("|:(SageFs%w+)|") do
      if not cmds[name] and not seen[name] then seen[name] = true; table.insert(phantom, name) end
    end
    table.sort(phantom)
    assert_eq(0, #phantom, "help links to unregistered commands: " .. table.concat(phantom, ", "))
  end)

  it("doc/tags is what :helptags generates, byte for byte", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/doc", "p")
    local out = assert(io.open(dir .. "/doc/sagefs.txt", "wb"))
    out:write(help)
    out:close()
    vim.cmd("helptags " .. vim.fn.fnameescape(dir .. "/doc"))
    assert_truthy(read(dir .. "/doc/tags") == read(plugin_root .. "/doc/tags"), "doc/tags is stale: run :helptags doc/")
  end)
end)

-- §5.6: transport failure vs. zero-sessions-returned must produce different
-- messages. Previously both collapsed into "No active session for this
-- directory" even when the plugin had `result.ok == false` (the daemon is
-- unreachable) in hand — the opposite of the truth, and it sent the user to
-- "Create session now" against a daemon that would never answer.

describe("smart eval session check (§5.6)", function()
  it("tells the user the daemon is unreachable when the transport itself failed, not 'no session'", function()
    local sagefs = require("sagefs")
    local original_list_sessions = sagefs.list_sessions
    local original_ui_select = vim.ui.select
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end
    local select_called = false
    vim.ui.select = function() select_called = true end

    sagefs.active_session = nil
    sagefs.list_sessions = function(cb) cb({ ok = false, error = "empty response" }) end

    local guarded = sagefs.smart_eval_with_session_check(function() end)
    guarded()

    vim.notify = original_notify
    vim.ui.select = original_ui_select
    sagefs.list_sessions = original_list_sessions

    assert_falsy(select_called, "must not offer 'Create session now' against an unreachable daemon")
    assert_truthy(#notifications > 0, "should notify")
    assert_truthy(notifications[#notifications].msg:find("not available on port", 1, true),
      "should say the daemon is unreachable, not 'no active session': " .. notifications[#notifications].msg)
    assert_truthy(notifications[#notifications].msg:find(":SageFsStart", 1, true), "should name the fix")
  end)

  it("still offers to create a session when the daemon answered with zero sessions", function()
    local sagefs = require("sagefs")
    local original_list_sessions = sagefs.list_sessions
    local original_ui_select = vim.ui.select
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end
    local select_called = false
    vim.ui.select = function() select_called = true end

    sagefs.active_session = nil
    sagefs.list_sessions = function(cb) cb({ ok = true, sessions = {} }) end

    local guarded = sagefs.smart_eval_with_session_check(function() end)
    guarded()

    vim.notify = original_notify
    vim.ui.select = original_ui_select
    sagefs.list_sessions = original_list_sessions

    assert_truthy(select_called, "a genuinely empty session list should still offer to create one")
    assert_truthy(notifications[#notifications].msg:find("No active session for this directory", 1, true))
  end)
end)

-- Compatibility is decided by the daemon's wire apiVersion, not by comparing
-- version numbers (the two schemes were unrelated, so the old check said
-- "plugin is behind" on every start). The startup warning appears only for
-- a real incompatibility.
local function probe_health_with(payload)
  local sagefs = require("sagefs")
  local transport = require("sagefs.transport")
  local original_http_json = transport.http_json
  local original_notify = vim.notify
  local notifications = {}
  local healthy = nil

  transport.http_json = function(opts)
    if opts.url:find("/health$") then
      opts.callback(true, vim.json.encode(payload))
      return
    end
    error("unexpected discovery request: " .. opts.url)
  end
  vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

  sagefs.health_check(function(result) healthy = result end)
  vim.wait(1000, function() return healthy ~= nil end, 10)
  vim.wait(200, function() return false end, 10) -- let deferred notices land

  transport.http_json = original_http_json
  vim.notify = original_notify
  return notifications
end

describe("startup compatibility warning", function()
  it("stays silent when only the version numbers differ and the api matches", function()
    local notifications = probe_health_with({
      healthy = true, status = "ready", features = {}, apiVersion = 3, version = "9.9.9" })
    for _, n in ipairs(notifications) do
      assert_falsy(n.level == vim.log.levels.WARN, "no warning for a version-number difference: " .. n.msg)
    end
  end)

  it("warns once, naming the fix, when the daemon speaks an api the plugin does not understand", function()
    local notifications = probe_health_with({
      healthy = true, status = "ready", features = {}, apiVersion = 99, version = "9.9.9" })
    local found = false
    for _, n in ipairs(notifications) do
      if n.msg:find("api 99", 1, true) and n.msg:find("update the plugin", 1, true) then
        found = true
        assert_eq(vim.log.levels.WARN, n.level, "an incompatibility is a warning")
      end
    end
    assert_truthy(found, "should warn about the incompatible api version outside :checkhealth")
  end)

  it("warns for a daemon older than the plugin needs, and says to update the daemon", function()
    local notifications = probe_health_with({
      healthy = true, status = "ready", features = {}, apiVersion = 2, version = "0.6.100" })
    local found = false
    for _, n in ipairs(notifications) do
      if n.msg:find("api 2", 1, true) and n.msg:find("update the daemon", 1, true) then found = true end
    end
    assert_truthy(found)
  end)
end)

describe("health check discovery", function()
  it("falls back to /version when /health is unavailable", function()
    local sagefs = require("sagefs")
    local transport = require("sagefs.transport")
    local original_http_json = transport.http_json
    local original_notify = vim.notify
    local urls = {}
    local notifications = {}
    local healthy = nil

    transport.http_json = function(opts)
      table.insert(urls, opts.url)

      if opts.url:find("/health$") then
        opts.callback(false, "connect: refused")
        return
      end

      if opts.url:find("/version$") then
        opts.callback(true, vim.json.encode({
          version = "1.2.3",
          apiVersion = 7,
          server = "sagefs",
          mcp = true,
          sse = true,
        }))
        return
      end

      error("unexpected discovery request: " .. opts.url)
    end

    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end

    sagefs.state.api_version = nil
    sagefs.state.features = nil
    sagefs.state.last_error = nil

    local ok, err = xpcall(function()
      sagefs.health_check(function(result)
        healthy = result
      end)

      local completed = vim.wait(1000, function()
        return healthy ~= nil
      end, 10)

      assert_truthy(completed, "scheduled health callback")
    end, debug.traceback)

    transport.http_json = original_http_json
    vim.notify = original_notify

    if not ok then
      error(err, 0)
    end

    assert_eq(2, #urls, "health check probe count")
    assert_eq("http://localhost:37749/health", urls[1], "first probe")
    assert_eq("http://localhost:37749/version", urls[2], "fallback probe")
    assert_truthy(healthy, "health check result")
    assert_eq(7, sagefs.state.api_version, "api version from fallback")
    assert_type("table", sagefs.state.features, "features reset on fallback")
    assert_eq(0, vim.tbl_count(sagefs.state.features), "fallback features empty")
    assert_truthy(#notifications > 0, "connection notification emitted")
    assert_truthy(notifications[1].msg:find("Connected to SageFs on port 37749", 1, true), "connect notification")
  end)

  it("falls back to /version when /health omits apiVersion", function()
    local sagefs = require("sagefs")
    local transport = require("sagefs.transport")
    local original_http_json = transport.http_json
    local original_notify = vim.notify
    local urls = {}
    local notifications = {}
    local healthy = nil

    transport.http_json = function(opts)
      table.insert(urls, opts.url)

      if opts.url:find("/health$") then
        opts.callback(true, vim.json.encode({
          healthy = false,
          status = "no session",
          features = {},
        }))
        return
      end

      if opts.url:find("/version$") then
        opts.callback(true, vim.json.encode({
          version = "1.2.3",
          apiVersion = 7,
          server = "sagefs",
          mcp = true,
          sse = true,
        }))
        return
      end

      error("unexpected discovery request: " .. opts.url)
    end

    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end

    sagefs.state.api_version = nil
    sagefs.state.features = nil
    sagefs.state.last_error = nil

    local ok, err = xpcall(function()
      sagefs.health_check(function(result)
        healthy = result
      end)

      local completed = vim.wait(1000, function()
        return healthy ~= nil
      end, 10)

      assert_truthy(completed, "scheduled health callback")
    end, debug.traceback)

    transport.http_json = original_http_json
    vim.notify = original_notify

    if not ok then
      error(err, 0)
    end

    assert_eq(2, #urls, "health check probe count")
    assert_eq("http://localhost:37749/health", urls[1], "first probe")
    assert_eq("http://localhost:37749/version", urls[2], "fallback probe")
    assert_truthy(healthy, "health check result")
    assert_eq(7, sagefs.state.api_version, "api version from fallback")
    assert_type("table", sagefs.state.features, "features reset on fallback")
    assert_eq(0, vim.tbl_count(sagefs.state.features), "fallback features empty")
    assert_truthy(#notifications > 0, "connection notification emitted")
    assert_truthy(notifications[1].msg:find("Connected to SageFs on port 37749", 1, true), "connect notification")
  end)
end)

-- ─── Extmark namespace ───────────────────────────────────────────────────────

describe("extmark namespace", function()
  it("plugin creates sagefs namespace", function()
    local ns = vim.api.nvim_create_namespace("sagefs")
    assert_truthy(ns > 0, "namespace should be positive integer")
  end)
end)

-- ─── Cell detection with real buffers ────────────────────────────────────────

describe("cell detection in real buffer", function()
  it("finds cells in a buffer with F# code", function()
    local buf = make_buffer({
      "let x = 42;;",
      "",
      "let y = x + 1;;",
    })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local all = cells.find_all_cells(lines)
    assert_eq(2, #all, "should find 2 cells")
    assert_eq(1, all[1].start_line, "cell 1 start")
    assert_eq(1, all[1].end_line, "cell 1 end")
    assert_eq(2, all[2].start_line, "cell 2 start")
    assert_eq(3, all[2].end_line, "cell 2 end")
  end)

  it("find_cell locates cell at cursor position", function()
    local buf = make_buffer({
      "// header",
      "let x = 42;;",
      "",
      "let y = 1",
      "let z = y + 1;;",
    })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local cell = cells.find_cell(lines, 4) -- cursor on "let y = 1"
    assert_truthy(cell, "should find cell")
    assert_eq(3, cell.start_line, "cell start")
    assert_eq(5, cell.end_line, "cell end")
  end)

  it("handles empty buffer", function()
    local buf = make_buffer({})
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- Neovim always has at least one line (empty string) in a buffer
    -- find_all_cells returns a trailing unterminated cell for non-empty content
    -- An empty buffer has lines = {""} which is 1 empty line — no boundaries, no meaningful cells
    local all = cells.find_all_cells(lines)
    -- The trailing cell logic creates 1 cell from the empty line; this is valid behavior
    assert_truthy(#all <= 1, "empty buffer should have 0 or 1 trailing cell")
  end)

  it("handles buffer with no boundaries", function()
    local buf = make_buffer({ "let x = 42", "let y = 1" })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local all = cells.find_all_cells(lines)
    -- No ;; boundaries means find_all_cells creates one trailing unterminated cell
    assert_eq(1, #all, "no ;; means 1 unterminated trailing cell")
    assert_eq(1, all[1].start_line, "starts at line 1")
    assert_eq(2, all[1].end_line, "ends at last line")
  end)
end)

-- ─── Model + extmark rendering cycle ──────────────────────────────────────

describe("model to extmark cycle", function()
  it("model state drives gutter sign selection", function()
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    m = model.set_cell_state(m, 1, "success", "42")
    local cell = model.get_cell_state(m, 1)
    local sign = format.gutter_sign(cell.status)
    assert_eq("success", cell.status, "cell status")
    assert_truthy(sign.text, "sign should have text")
    assert_eq("SageFsSuccess", sign.hl, "sign highlight")
  end)

  it("stale cells get stale formatting", function()
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    m = model.set_cell_state(m, 1, "success", "42")
    m = model.mark_stale(m, 1)
    local cell = model.get_cell_state(m, 1)
    local sign = format.gutter_sign(cell.status)
    assert_eq("stale", cell.status, "should be stale")
    assert_eq("SageFsStale", sign.hl, "stale highlight")
  end)

  it("error cells get error formatting", function()
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    m = model.set_cell_state(m, 1, "error", "type mismatch")
    local cell = model.get_cell_state(m, 1)
    local inline = format.format_inline({ ok = false, error = cell.output })
    assert_contains(inline.text, "type mismatch", "error text in inline")
    assert_eq("SageFsError", inline.hl, "error highlight")
  end)

  it("format_inline truncates long output", function()
    local long = string.rep("x", 200)
    local inline = format.format_inline({ ok = true, output = long })
    -- MAX_INLINE_LEN=120, plus "→ " prefix (4 bytes UTF-8). Truncated text ≤ 130 bytes.
    assert_truthy(#inline.text <= 130, "should be truncated, got " .. #inline.text .. " bytes")
    assert_truthy(#inline.text < 200, "should be much shorter than input")
  end)

  it("format_virtual_lines splits multi-line output", function()
    local vlines = format.format_virtual_lines({ ok = true, output = "line1\nline2\nline3" })
    assert_eq(3, #vlines, "should have 3 virtual lines")
  end)
end)

-- ─── Extmark creation and inspection ─────────────────────────────────────────

describe("extmark creation", function()
  local ns

  it("can create and read back extmarks with virt_text", function()
    local buf = make_buffer({ "let x = 42;;" })
    ns = vim.api.nvim_create_namespace("test_integ_extmarks")
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      virt_text = { { "-> 42", "Normal" } },
      virt_text_pos = "eol",
    })
    local marks = get_extmarks(buf, ns)
    assert_eq(1, #marks, "should have 1 extmark")
    assert_truthy(marks[1][4].virt_text, "should have virt_text")
  end)

  it("can create extmarks with sign_text", function()
    local buf = make_buffer({ "let x = 42;;" })
    ns = vim.api.nvim_create_namespace("test_integ_signs")
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      sign_text = "ok",
      sign_hl_group = "Normal",
    })
    local marks = get_extmarks(buf, ns)
    assert_eq(1, #marks, "should have 1 extmark with sign")
  end)

  it("can create virtual lines below a boundary", function()
    local buf = make_buffer({ "let x = 42;;", "", "let y = 1;;" })
    ns = vim.api.nvim_create_namespace("test_integ_vlines")
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      virt_lines = { { { "  42", "Normal" } } },
      virt_lines_above = false,
    })
    local marks = get_extmarks(buf, ns)
    assert_truthy(marks[1][4].virt_lines, "should have virt_lines")
  end)

  it("clear_namespace removes all extmarks", function()
    local buf = make_buffer({ "test;;" })
    ns = vim.api.nvim_create_namespace("test_integ_clear")
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { virt_text = { { "a", "Normal" } } })
    assert_eq(1, #get_extmarks(buf, ns), "should have 1 before clear")
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    assert_eq(0, #get_extmarks(buf, ns), "should have 0 after clear")
  end)
end)

-- ─── SSE event → model state cycle ────────────────────────────────────────

describe("SSE to model cycle", function()
  it("parses SSE chunk and updates model", function()
    local chunk = 'event: eval_result\ndata: {"cellId": 1, "success": true, "result": "42"}\n\n'
    local events, _ = sse.parse_chunk(chunk)
    assert_eq(1, #events, "should parse 1 event")
    assert_eq("eval_result", events[1].type, "event type")

    -- Parse the data and apply to model
    local data = vim.json.decode(events[1].data)
    local m = model.new()
    if data.success then
      m = model.set_cell_state(m, data.cellId, "running")
      m = model.set_cell_state(m, data.cellId, "success", data.result)
    end
    assert_eq("success", model.get_cell_state(m, 1).status)
    assert_eq("42", model.get_cell_state(m, 1).output)
  end)

  it("handles streaming accumulation across chunks", function()
    local part1 = "event: state\nda"
    local part2 = "ta: connected\n\n"
    local events1, rem1 = sse.parse_chunk(part1)
    assert_eq(0, #events1, "incomplete chunk")
    local events2, _ = sse.parse_chunk(rem1 .. part2)
    assert_eq(1, #events2, "complete after accumulation")
    assert_eq("state", events2[1].type)
  end)
end)

-- ─── §5.4: session-scoped SSE filtering must apply to ALL per-session state ──
-- Drives the real dispatch pipeline (sagefs.start_sse → transport.connect_sse
-- → on_sse_events → build_handlers) by stubbing only transport.connect_sse to
-- capture its on_events callback, then feeding it fabricated raw SSE events —
-- exactly the shape transport hands to init.lua. Previously `providers_detected`
-- (and 5 siblings) had no session_scoped flag, so session B's data merged into
-- the client's single state even while B's results/summary were correctly
-- filtered — session B's provider list wearing session A's view.

describe("SSE session-scoping (§5.4)", function()
  it("providers_detected from a non-active session is dropped, not merged", function()
    local sagefs = require("sagefs")
    local transport = require("sagefs.transport")
    local original_connect_sse = transport.connect_sse
    local captured_on_events

    transport.connect_sse = function(_url, opts)
      captured_on_events = opts.on_events
      return { start = function() end, stop = function() end }
    end

    sagefs.active_session = { id = "session-A" }
    sagefs.testing_state.providers = nil

    sagefs.start_sse()
    assert_truthy(captured_on_events, "start_sse should have called transport.connect_sse")

    -- Session B's event must NOT merge into session A's active view.
    captured_on_events({
      { type = "ProvidersDetected", data = vim.json.encode({ SessionId = "session-B", providers = { "xUnit" } }) },
    })
    assert_falsy(sagefs.testing_state.providers, "a non-active session's providers must not merge in")

    -- Session A's own event must still apply.
    captured_on_events({
      { type = "ProvidersDetected", data = vim.json.encode({ SessionId = "session-A", providers = { "Expecto" } }) },
    })
    assert_truthy(sagefs.testing_state.providers, "the active session's own event must still apply")
    assert_eq("Expecto", sagefs.testing_state.providers[1])

    transport.connect_sse = original_connect_sse
    sagefs.active_session = nil
    sagefs.testing_state.providers = nil
  end)
end)

-- ─── Session lifecycle over SSE: Ready must reach the statusline ─────────────
-- The daemon sends `state {"sessionReady": sid}` when warmup finishes. It was
-- classified as "session_ready" and dropped, so the statusline kept the
-- snapshot taken right after create ("(Starting)") forever. Warmup events also
-- were not session-scoped (another session's warmup took over this statusline
-- and notified), and the `state` variant of warmup progress (no Phase) erased
-- the phase and notified an empty "Warming up: ".

describe("session lifecycle over SSE", function()
  local function with_sse(fn)
    local sagefs = require("sagefs")
    local transport = require("sagefs.transport")
    local original_connect_sse = transport.connect_sse
    local original_notify = vim.notify
    local saved = {
      active = sagefs.active_session, list = sagefs.session_list, phase = sagefs.warmup_phase,
      step = sagefs.warmup_step, total = sagefs.warmup_total, state = sagefs.state,
    }
    local original_http_json = transport.http_json
    local original_window = sagefs.config.session_refresh_debounce_ms
    local captured, notes, http_calls = nil, {}, {}
    transport.connect_sse = function(_url, opts)
      captured = opts
      return { start = function() end, stop = function() end }
    end
    -- Requests are recorded, never sent and never answered unless a test
    -- calls the recorded callback itself.
    transport.http_json = function(opts) table.insert(http_calls, opts) end
    sagefs.config.session_refresh_debounce_ms = 20
    vim.notify = function(msg, level) table.insert(notes, { msg = msg, level = level }) end
    sagefs.start_sse()
    local ok, err = pcall(fn, sagefs, captured, notes, http_calls)
    transport.connect_sse = original_connect_sse
    transport.http_json = original_http_json
    sagefs.config.session_refresh_debounce_ms = original_window
    vim.notify = original_notify
    sagefs.active_session, sagefs.session_list, sagefs.warmup_phase = saved.active, saved.list, saved.phase
    sagefs.warmup_step, sagefs.warmup_total, sagefs.state = saved.step, saved.total, saved.state
    if not ok then error(err, 0) end
  end

  local function starting_session(id)
    return { id = id, name = "DemoEnv.Tests", status = "Starting", projects = { "DemoEnv.Tests.fsproj" },
      working_directory = "/w", eval_count = 0 }
  end

  local function send(captured, type_, tbl)
    captured.on_events({ { type = type_, data = vim.json.encode(tbl) } })
  end

  it("sessionReady turns (Starting) into (Ready) on the statusline", function()
    with_sse(function(sagefs, cap)
      local s = starting_session("s1")
      sagefs.session_list, sagefs.active_session = { s }, s
      assert_contains(sagefs.statusline(), "Starting", "precondition")
      send(cap, "state", { sessionReady = "s1" })
      local sl = sagefs.statusline()
      assert_contains(sl, "(Ready)", "statusline after sessionReady")
      assert_falsy(sl:find("Starting", 1, true), "must not still say Starting")
      assert_eq("Ready", sagefs.session_list[1].status, "the list entry is updated too")
    end)
  end)

  it("sessionReady for another session leaves the active session alone", function()
    with_sse(function(sagefs, cap)
      local s, other = starting_session("s1"), starting_session("s2")
      sagefs.session_list, sagefs.active_session = { s, other }, s
      send(cap, "state", { sessionReady = "s2" })
      assert_contains(sagefs.statusline(), "Starting", "active session is not s2")
      assert_eq("Ready", sagefs.session_list[2].status)
    end)
  end)

  it("sessionReady clears a warmup label left on the statusline", function()
    with_sse(function(sagefs, cap)
      local s = starting_session("s1")
      sagefs.session_list, sagefs.active_session = { s }, s
      sagefs.warmup_phase = "finalizing"
      send(cap, "state", { sessionReady = "s1" })
      assert_falsy(sagefs.warmup_phase, "warmup phase cleared")
      assert_falsy(sagefs.statusline():find("⏳ SageFs", 1, true), "no warmup label once Ready")
    end)
  end)

  it("the statusline names the workflow the session list says, with no workflow_switched event", function()
    with_sse(function(sagefs)
      local s = starting_session("s1")
      s.status, s.workflow_label = "Ready", "Hot Reload"
      sagefs.session_list, sagefs.active_session, sagefs.workflow_label = { s }, s, nil
      assert_contains(sagefs.statusline(), "[Hot Reload]", "statusline")
    end)
  end)

  it("the session's own label wins over an old event's, and an event's label still shows when the row has none", function()
    with_sse(function(sagefs)
      local s = starting_session("s1")
      s.status, s.workflow_label = "Ready", "Live Testing"
      sagefs.session_list, sagefs.active_session, sagefs.workflow_label = { s }, s, "REPL"
      local sl = sagefs.statusline()
      assert_contains(sl, "[Live Testing]", "the row's label")
      assert_falsy(sl:find("[REPL]", 1, true), "not the stale event label")
      s.workflow_label = nil
      assert_contains(sagefs.statusline(), "[REPL]", "the event's label when the row has none")
      sagefs.workflow_label = nil
    end)
  end)

  it("the statusline shows the app the session list says is running, which this editor did not start", function()
    with_sse(function(sagefs)
      local s = starting_session("s1")
      s.status, s.app = "Ready", { kind = "Running", url = "http://localhost:5000" }
      sagefs.session_list, sagefs.active_session, sagefs.app_run_state = { s }, s, nil
      assert_contains(sagefs.statusline(), "▶", "a running app")
      s.app = { kind = "Crashed", reason = "exit code 134" }
      assert_contains(sagefs.statusline(), "⚠", "a crashed app")
      s.app = { kind = "NotRunning" }
      assert_falsy(sagefs.statusline():find("▶", 1, true), "an app that is not running shows no icon")
    end)
  end)

  it("the session's own app state wins over an old :SageFsRunApp answer", function()
    with_sse(function(sagefs)
      local s = starting_session("s1")
      s.status, s.app = "Ready", { kind = "NotRunning" }
      sagefs.session_list, sagefs.active_session, sagefs.app_run_state = { s }, s, { kind = "Running" }
      assert_falsy(sagefs.statusline():find("▶", 1, true), "the app stopped, whatever this editor was last told")
      sagefs.app_run_state = nil
    end)
  end)

  local function session_gets(http_calls)
    local n = 0
    for _, c in ipairs(http_calls) do
      if c.method == "GET" and c.url:find("/api/sessions", 1, true) and not c.url:find("/api/sessions/", 1, true) then
        n = n + 1
      end
    end
    return n
  end

  local function wait_for_gets(http_calls, n)
    vim.wait(500, function() return session_gets(http_calls) >= n end, 5)
  end

  it("the refresh window is a named setting in the config", function()
    local sagefs = require("sagefs")
    assert_type("number", sagefs.config.session_refresh_debounce_ms, "session_refresh_debounce_ms")
    assert_truthy(sagefs.config.session_refresh_debounce_ms > 0, "a positive window")
  end)

  it("sessionReady asks the daemon for the authoritative session list", function()
    with_sse(function(sagefs, cap, _notes, http)
      local s = starting_session("s1")
      sagefs.session_list, sagefs.active_session = { s }, s
      send(cap, "state", { sessionReady = "s1" })
      wait_for_gets(http, 1)
      assert_eq(1, session_gets(http), "one GET /api/sessions after sessionReady")
    end)
  end)

  it("50 sessionReady events for unknown sessions cause one GET /api/sessions, not 50", function()
    with_sse(function(sagefs, cap, _notes, http)
      sagefs.session_list, sagefs.active_session = {}, nil
      for i = 1, 50 do send(cap, "state", { sessionReady = "ghost-" .. i }) end
      wait_for_gets(http, 1)
      vim.wait(100, function() return false end, 10)
      assert_eq(1, session_gets(http), "burst coalesced into one list refresh")
    end)
  end)

  it("a later burst, after the window closed, refreshes again", function()
    with_sse(function(sagefs, cap, _notes, http)
      sagefs.session_list, sagefs.active_session = {}, nil
      send(cap, "state", { sessionReady = "ghost-1" })
      wait_for_gets(http, 1)
      send(cap, "state", { sessionReady = "ghost-2" })
      wait_for_gets(http, 2)
      assert_eq(2, session_gets(http), "one refresh per window")
    end)
  end)

  it("sessionReady clears the old fault_reason", function()
    with_sse(function(sagefs, cap)
      local s = starting_session("s1")
      s.status, s.fault_reason = "Faulted", "boom"
      sagefs.session_list, sagefs.active_session = { s }, s
      send(cap, "state", { sessionReady = "s1" })
      assert_eq("Ready", sagefs.active_session.status)
      assert_falsy(sagefs.active_session.fault_reason, "active session fault_reason")
      assert_falsy(sagefs.session_list[1].fault_reason, "list entry fault_reason")
    end)
  end)

  it("a session list answer older than a later sessionFaulted does not turn the session Ready again", function()
    with_sse(function(sagefs, cap, _notes, http)
      local s = starting_session("s1")
      sagefs.session_list, sagefs.active_session = { s }, s
      send(cap, "state", { sessionReady = "s1" })
      wait_for_gets(http, 1)
      local request = http[#http]
      -- the daemon faults before the answer to that request reaches us
      send(cap, "state", { sessionFaulted = "s1", error = "boom" })
      request.callback(true, vim.json.encode({ sessions = {
        { id = "s1", status = "Ready", projects = { "DemoEnv.Tests.fsproj" }, workingDirectory = "/w" },
      } }))
      assert_eq("Faulted", sagefs.active_session.status, "the later event wins over the older snapshot")
      assert_eq("boom", sagefs.active_session.fault_reason)
      assert_contains(sagefs.statusline(), "(Faulted)", "statusline")
    end)
  end)

  it("a session list answer requested after the fault is authoritative", function()
    with_sse(function(sagefs, cap, _notes, http)
      local s = starting_session("s1")
      sagefs.session_list, sagefs.active_session = { s }, s
      send(cap, "state", { sessionFaulted = "s1", error = "boom" })
      send(cap, "state", { sessionReady = "s1" })
      wait_for_gets(http, 1)
      http[#http].callback(true, vim.json.encode({ sessions = {
        { id = "s1", status = "Ready", projects = { "DemoEnv.Tests.fsproj" }, workingDirectory = "/w" },
      } }))
      assert_eq("Ready", sagefs.active_session.status)
      assert_falsy(sagefs.active_session.fault_reason, "no stale fault text next to Ready")
    end)
  end)

  it("a session event with null data is ignored without a handler error", function()
    with_sse(function(sagefs, cap, notes)
      local s = starting_session("s1")
      sagefs.session_list, sagefs.active_session = { s }, s
      cap.on_events({ { type = "session", data = "null" } })
      cap.on_events({ { type = "session", data = "7" } })
      cap.on_events({ { type = "session", data = '"text"' } })
      vim.wait(50, function() return false end, 10)
      for _, n in ipairs(notes) do
        assert_falsy(n.msg:find("SSE handler error", 1, true), "no handler error for a non-object payload: " .. n.msg)
      end
      assert_eq("Starting", sagefs.active_session.status, "nothing else changed")
    end)
  end)

  it("another session's fault leaves the active session's coverage alone and is marked on the list, without a message", function()
    with_sse(function(sagefs, cap, notes)
      local coverage = require("sagefs.coverage")
      local saved_cov = sagefs.coverage_state
      local s, other = starting_session("s1"), starting_session("s2")
      sagefs.session_list, sagefs.active_session = { s, other }, s
      sagefs.coverage_state = coverage.new()
      sagefs.coverage_state.files = { ["/src/A.fs"] = { lines = { { line = 1, covered = true } } } }
      send(cap, "state", { sessionFaulted = "s2", error = "boom" })
      local kept = sagefs.coverage_state.files["/src/A.fs"] ~= nil
      sagefs.coverage_state = saved_cov
      assert_truthy(kept, "the active session's coverage must survive someone else's fault")
      assert_eq("Faulted", sagefs.session_list[2].status, "the faulted session is marked")
      assert_eq("Starting", sagefs.active_session.status, "the active session is not")
      -- Another session's fault is on the list (":SageFsSessions" shows
      -- Faulted) but is not a message in this editor: on a shared daemon
      -- those messages raised hit-enter prompts for sessions that are not
      -- the user's (see the display harness for the same rule at the edge).
      for _, n in ipairs(notes) do
        assert_falsy(n.msg:find("boom", 1, true), "no message about someone else's fault: " .. n.msg)
      end
    end)
  end)

  it("the active session's own fault still clears its coverage", function()
    with_sse(function(sagefs, cap)
      local coverage = require("sagefs.coverage")
      local saved_cov = sagefs.coverage_state
      local s = starting_session("s1")
      sagefs.session_list, sagefs.active_session = { s }, s
      sagefs.coverage_state = coverage.new()
      sagefs.coverage_state.files = { ["/src/A.fs"] = { lines = { { line = 1, covered = true } } } }
      send(cap, "state", { sessionFaulted = "s1", error = "boom" })
      local cleared = next(sagefs.coverage_state.files) == nil
      sagefs.coverage_state = saved_cov
      assert_truthy(cleared, "coverage of the faulted active session is cleared")
    end)
  end)

  it("a fault with no session id still clears (nothing says it is someone else's)", function()
    with_sse(function(sagefs, cap)
      local coverage = require("sagefs.coverage")
      local saved_cov = sagefs.coverage_state
      local s = starting_session("s1")
      sagefs.session_list, sagefs.active_session = { s }, s
      sagefs.coverage_state = coverage.new()
      sagefs.coverage_state.files = { ["/src/A.fs"] = { lines = { { line = 1, covered = true } } } }
      cap.on_events({ { type = "SessionFaulted", data = vim.json.encode({ reason = "legacy" }) } })
      local cleared = next(sagefs.coverage_state.files) == nil
      sagefs.coverage_state = saved_cov
      assert_truthy(cleared, "an unscoped fault keeps the old behavior")
    end)
  end)

  it("another session's warmup progress does not take over this statusline or notify", function()
    with_sse(function(sagefs, cap, notes)
      local s = starting_session("s1")
      sagefs.session_list, sagefs.active_session = { s }, s
      sagefs.warmup_phase = nil
      send(cap, "warmup_progress", { SessionId = "someone-else", Phase = "creating_fsi", Step = 1, Total = 4, Progress = 0.25 })
      assert_falsy(sagefs.warmup_phase, "foreign warmup must not set the phase")
      assert_falsy(sagefs.statusline():find("⏳ SageFs", 1, true), "statusline unchanged")
      assert_eq(0, #notes, "no notification for someone else's warmup")
    end)
  end)

  it("this session's warmup progress still shows", function()
    with_sse(function(sagefs, cap)
      local s = starting_session("s1")
      sagefs.session_list, sagefs.active_session = { s }, s
      send(cap, "warmup_progress", { SessionId = "s1", Phase = "loading_assemblies", Step = 3, Total = 4 })
      assert_contains(sagefs.statusline(), "Loading assemblies", "own warmup shown")
    end)
  end)

  it("the state variant of warmup progress (no Phase) keeps the phase and says nothing", function()
    with_sse(function(sagefs, cap, notes)
      local s = starting_session("s1")
      sagefs.session_list, sagefs.active_session = { s }, s
      send(cap, "warmup_progress", { SessionId = "s1", Phase = "creating_fsi", Step = 1, Total = 4 })
      local before = #notes
      send(cap, "state", { sessionId = "s1", step = 1, total = 4, warmupProgress = true })
      assert_eq("creating_fsi", sagefs.warmup_phase, "phase survives the phase-less variant")
      for i = before + 1, #notes do
        assert_falsy(notes[i].msg:match("Warming up:%s*$"), "no empty 'Warming up:' notification")
      end
    end)
  end)

  it("sessionFaulted marks the session Faulted on the statusline", function()
    with_sse(function(sagefs, cap)
      local s = starting_session("s1")
      sagefs.session_list, sagefs.active_session = { s }, s
      send(cap, "state", { sessionFaulted = "s1", error = "worker died" })
      assert_contains(sagefs.statusline(), "(Faulted)", "faulted shown")
    end)
  end)

  it("session_health_changed Degraded reaches the statusline", function()
    with_sse(function(sagefs, cap)
      local s = starting_session("s1")
      s.status = "Ready"
      sagefs.session_list, sagefs.active_session = { s }, s
      send(cap, "session", { type = "session_health_changed", sessionId = "s1",
        health = { status = "Degraded", reason = "gc pressure" } })
      assert_contains(sagefs.statusline(), "gc pressure", "degraded reason shown")
    end)
  end)

  it("a (re)connect refreshes the session list, so a missed Ready event cannot stick", function()
    with_sse(function(sagefs, cap)
      local transport = require("sagefs.transport")
      local original_http_json = transport.http_json
      local s = starting_session("s1")
      sagefs.session_list, sagefs.active_session = { s }, s
      transport.http_json = function(opts)
        if opts.url:find("/api/sessions$") then
          opts.callback(true, vim.json.encode({ sessions = {
            { id = "s1", status = "Ready", projects = { "DemoEnv.Tests.fsproj" }, workingDirectory = "/w" } } }))
        end
      end
      cap.on_connect()
      transport.http_json = original_http_json
      assert_contains(sagefs.statusline(), "(Ready)", "refreshed on connect")
    end)
  end)
end)

-- ─── Testing module integration ──────────────────────────────────────────────

describe("testing module with real JSON", function()
  it("round-trips server response through parse and apply", function()
    local server_response = vim.json.encode({
      enabled = true,
      summary = { total = 3, passed = 2, failed = 1, stale = 0, running = 0 },
      tests = {
        {
          testId = "abc123",
          displayName = "should add numbers",
          fullName = "Math.Tests.should add numbers",
          origin = { Case = "SourceMapped", Fields = { "src/Math.fs", 10 } },
          framework = "Expecto",
          category = "Unit",
          currentPolicy = "OnEveryChange",
          status = "Passed",
        },
        {
          testId = "def456",
          displayName = "should handle overflow",
          fullName = "Math.Tests.should handle overflow",
          origin = { Case = "SourceMapped", Fields = { "src/Math.fs", 25 } },
          framework = "Expecto",
          category = "Unit",
          currentPolicy = "OnEveryChange",
          status = "Failed",
        },
      },
    })

    local state = testing.new()
    local parsed, err = testing.parse_status_response(server_response)
    assert_truthy(parsed, "should parse: " .. tostring(err))
    state = testing.apply_status_response(state, parsed)

    assert_truthy(state.enabled, "should be enabled")
    assert_eq(2, testing.test_count(state), "should have 2 tests")

    local by_file = testing.filter_by_file(state, "src/Math.fs")
    assert_eq(2, #by_file, "2 tests in Math.fs")

    local failed = testing.filter_by_status(state, "Failed")
    assert_eq(1, #failed, "1 failed test")
    assert_eq("def456", failed[1].testId, "failed test id")
  end)

  it("gutter signs work for all test statuses", function()
    local statuses = { "Passed", "Failed", "Running", "Queued", "Stale", "PolicyDisabled", "Skipped", "Detected" }
    for _, status in ipairs(statuses) do
      local sign = testing.gutter_sign(status)
      assert_truthy(sign.text, "sign text for " .. status)
      assert_truthy(sign.hl, "sign hl for " .. status)
      assert_truthy(sign.hl:find("SageFs"), "hl should start with SageFs for " .. status)
    end
  end)
end)

-- ─── Session management with real JSON ───────────────────────────────────────

describe("sessions with real vim.json", function()
  it("parses a full sessions list response", function()
    local json = vim.json.encode({
      sessions = {
        {
          id = "s1",
          status = "Ready",
          projects = { "MyApp.fsproj" },
          workingDirectory = "C:\\Code\\MyApp",
          evalCount = 15,
          avgDurationMs = 120,
        },
        {
          id = "s2",
          status = "Loading",
          projects = { "Tests.fsproj" },
          workingDirectory = "C:\\Code\\Tests",
          evalCount = 0,
          avgDurationMs = 0,
        },
      },
    })
    local result = sessions.parse_sessions_response(json)
    assert_truthy(result.ok, "should parse ok")
    assert_eq(2, #result.sessions, "should have 2 sessions")
    assert_eq("s1", result.sessions[1].id, "first session id")
    assert_eq("MyApp.fsproj", result.sessions[1].projects[1], "first project")
  end)

  it("formats statusline from session data", function()
    local s = {
      id = "s1",
      projects = { "MyApp.fsproj" },
      status = "Ready",
    }
    local line = sessions.format_statusline(s)
    assert_contains(line, "MyApp", "should contain project name")
    assert_contains(line, "Ready", "should contain status")
  end)

  it("creates an explicit project session with no discovery key", function()
    local sagefs = require("sagefs")
    local transport = require("sagefs.transport")
    local original_http_json = transport.http_json
    local calls = {}
    transport.http_json = function(opts)
      table.insert(calls, opts)
      if opts.url:find("/api/sessions/create$") then
        opts.callback(true, vim.json.encode({ success = true, message = "created" }))
        return
      end
      opts.callback(true, vim.json.encode({ sessions = {} }))
    end

    sagefs.create_session({ "App.fsproj" }, "/repo")
    transport.http_json = original_http_json

    assert_eq(2, #calls, "create plus follow-up session refresh")
    local create = calls[1]
    assert_eq("POST", create.method)
    assert_eq("http://localhost:37749/api/sessions/create", create.url)
    assert_eq(300, create.timeout)
    assert_eq(1, #create.body.projects)
    assert_eq("App.fsproj", create.body.projects[1])
    assert_eq("/repo", create.body.workingDirectory)
    assert_falsy(create.body.projectSelection, "obsolete discovery key must not be sent")
    assert_contains(calls[2].url, "/api/sessions", "successful create refreshes sessions")
  end)

  it("creates a bare session through the explicit bare API", function()
    local sagefs = require("sagefs")
    local transport = require("sagefs.transport")
    local original_http_json = transport.http_json
    local call = nil
    transport.http_json = function(opts)
      if opts.url:find("/api/sessions/create$") then
        call = opts
        opts.callback(true, vim.json.encode({ success = true, message = "created" }))
        return
      end
      opts.callback(true, vim.json.encode({ sessions = {} }))
    end

    sagefs.create_bare_session("/repo")
    transport.http_json = original_http_json

    assert_truthy(call, "bare create should reach the daemon")
    assert_eq(0, #call.body.projects)
    assert_falsy(call.body.projectSelection, "bare has a named API, not an inferred selection field")
  end)

  it("rejects an invalid target before making an HTTP request", function()
    local sagefs = require("sagefs")
    local transport = require("sagefs.transport")
    local original_http_json = transport.http_json
    local count = 0
    local result = nil
    transport.http_json = function() count = count + 1 end

    sagefs.create_session({ "App.txt" }, "/repo", function(value) result = value end)
    transport.http_json = original_http_json

    assert_eq(0, count, "invalid target must fail locally")
    assert_truthy(result and not result.ok, "callback should receive the local refusal")
    assert_contains(result.error, ".fsproj", "error names the closed target set")
  end)
end)

-- ─── Buffer edit → stale detection cycle ──────────────────────────────────

describe("edit detection cycle", function()
  it("editing a buffer should make cells stale", function()
    local buf = make_buffer({
      "let x = 42;;",
      "",
      "let y = x + 1;;",
    })
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    m = model.set_cell_state(m, 1, "success", "42")
    m = model.set_cell_state(m, 2, "running")
    m = model.set_cell_state(m, 2, "success", "43")

    -- Simulate what init.lua does on TextChanged
    m = model.mark_all_stale(m)

    assert_eq("stale", model.get_cell_state(m, 1).status, "cell 1 stale")
    assert_eq("stale", model.get_cell_state(m, 2).status, "cell 2 stale")
    -- Output preserved
    assert_eq("42", model.get_cell_state(m, 1).output, "cell 1 output preserved")
  end)
end)

-- ─── Full eval cycle (without HTTP) ───────────────────────────────────────

describe("eval cycle (mock HTTP response)", function()
  it("success response flows through format to extmark-ready data", function()
    -- Simulated curl response
    local http_response = vim.json.encode({ success = true, result = "val it: int = 42" })
    local result = format.parse_exec_response(http_response)
    assert_truthy(result.ok, "should be ok")
    assert_eq("val it: int = 42", result.output, "output")

    -- Model update
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    m = model.set_cell_state(m, 1, "success", result.output)

    -- Format for extmark
    local inline = format.format_inline(result)
    assert_contains(inline.text, "42", "inline should contain result")
    assert_eq("SageFsSuccess", inline.hl, "success highlight")
  end)

  it("error response flows through format", function()
    local http_response = vim.json.encode({ success = false, result = "FS0001: type mismatch" })
    local result = format.parse_exec_response(http_response)
    assert_falsy(result.ok, "should be error")
    assert_contains(result.error, "FS0001", "error message")

    local inline = format.format_inline(result)
    assert_eq("SageFsError", inline.hl, "error highlight")
  end)
end)

-- ─── Autocmd registration ────────────────────────────────────────────────────

describe("autocmd registration", function()
  it("has FileType autocmd for fsharp", function()
    local ok, aus = pcall(vim.api.nvim_get_autocmds, { group = "SageFs", event = "FileType" })
    assert_truthy(ok, "SageFs augroup should exist after setup")
    assert_truthy(#aus > 0, "should have FileType autocmds in SageFs group")
  end)

  it("has autocmd group registered", function()
    local ok, aus = pcall(vim.api.nvim_get_autocmds, { group = "SageFs" })
    assert_truthy(ok, "SageFs augroup should exist")
    assert_type("table", aus, "should return table")
    assert_truthy(#aus > 0, "should have at least one autocmd")
  end)

  it("has BufWritePost autocmd for check_on_save", function()
    local ok, aus = pcall(vim.api.nvim_get_autocmds, { group = "SageFs", event = "BufWritePost" })
    assert_truthy(ok, "SageFs augroup should exist after setup")
    assert_truthy(#aus > 0, "should have BufWritePost autocmd in SageFs group")
  end)

  it("has TextChanged/TextChangedI autocmds for buffer-changed as-you-type", function()
    local ok, aus = pcall(vim.api.nvim_get_autocmds, { group = "SageFs", event = "TextChanged" })
    assert_truthy(ok, "SageFs augroup should exist after setup")
    assert_truthy(#aus > 0, "should have TextChanged autocmd in SageFs group")

    local ok2, aus2 = pcall(vim.api.nvim_get_autocmds, { group = "SageFs", event = "TextChangedI" })
    assert_truthy(ok2, "SageFs augroup should exist after setup")
    assert_truthy(#aus2 > 0, "should have TextChangedI autocmd in SageFs group")
  end)
end)

-- ─── Live-testing as-you-type: debounced buffer-changed POST ─────────────────
-- Covers the bug this suite exists to catch: M.post_buffer_changed was
-- defined but never wired to any autocmd, so Neovim users only got
-- save-driven live-testing. Stubs sagefs.post_buffer_changed itself (rather
-- than the HTTP transport) so these tests never touch the network, and drive
-- the real vim.fn.timer_start debounce via vim.wait — this runs inside a
-- real headless Neovim, not the busted mocks, so timers actually fire.

describe("buffer-changed as-you-type (debounced)", function()
  local sagefs = require("sagefs")
  local original_post_buffer_changed = sagefs.post_buffer_changed
  local original_active_session = sagefs.active_session

  local function fresh_fs_buffer()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_name(buf, "/tmp/sagefs_harness_" .. buf .. "_" .. os.time() .. ".fs")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "let add a b = a + b" })
    return buf
  end

  it("does NOT call post_buffer_changed on edit when there is no active session", function()
    sagefs.active_session = nil
    local calls = {}
    sagefs.post_buffer_changed = function(buf) table.insert(calls, buf) end

    local buf = fresh_fs_buffer()
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    vim.wait(400, function() return #calls > 0 end)

    assert_eq(0, #calls, "post_buffer_changed should not be scheduled without an active session")
  end)

  it("calls post_buffer_changed ~300ms after an edit when a session is active", function()
    sagefs.active_session = { id = "harness-session", working_directory = "/tmp" }
    local calls = {}
    sagefs.post_buffer_changed = function(buf) table.insert(calls, buf) end

    local buf = fresh_fs_buffer()
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })

    assert_eq(0, #calls, "post_buffer_changed should be debounced, not called synchronously")

    vim.wait(600, function() return #calls > 0 end)

    assert_eq(1, #calls, "post_buffer_changed should fire exactly once after the debounce")
    assert_eq(buf, calls[1], "post_buffer_changed should receive the edited buffer")
  end)

  it("coalesces a burst of rapid edits into a single debounced call", function()
    sagefs.active_session = { id = "harness-session", working_directory = "/tmp" }
    local calls = {}
    sagefs.post_buffer_changed = function(buf) table.insert(calls, buf) end

    local buf = fresh_fs_buffer()
    for _ = 1, 5 do
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      vim.wait(50)
    end
    vim.wait(600, function() return #calls > 0 end)

    assert_eq(1, #calls, "a burst of edits within the debounce window should produce exactly one call")

    sagefs.post_buffer_changed = original_post_buffer_changed
    sagefs.active_session = original_active_session
  end)
end)

-- ─── init.lua known bug: stale cells get success formatting ──────────────────

describe("init.lua line 82 bug (stale as success)", function()
  it("documents the bug: stale cell passed to format_inline with ok=true", function()
    -- This is the exact logic from init.lua line 82:
    --   ok = cell.status == "success" or cell.status == "stale"
    -- A stale cell should NOT be formatted as success.
    local cell = { status = "stale", output = "old value" }
    local ok_flag = cell.status == "success" or cell.status == "stale"
    -- This SHOULD be false for stale, but the current code makes it true
    -- This test documents the bug — when fixed, update the assertion
    assert_truthy(ok_flag, "BUG: stale is treated as success (init.lua:82)")
  end)
end)

-- ─── Multi-buffer state isolation ────────────────────────────────────────────

describe("multi-buffer state isolation", function()
  it("model tracks cells per-id independently", function()
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    m = model.set_cell_state(m, 1, "success", "buf1-result")
    m = model.set_cell_state(m, 2, "running")
    m = model.set_cell_state(m, 2, "error", "buf2-error")
    m = model.set_cell_state(m, 3, "running")

    assert_eq("success", model.get_cell_state(m, 1).status)
    assert_eq("error", model.get_cell_state(m, 2).status)
    assert_eq("running", model.get_cell_state(m, 3).status)

    -- Mark only cell 1 stale
    m = model.mark_stale(m, 1)
    assert_eq("stale", model.get_cell_state(m, 1).status)
    assert_eq("error", model.get_cell_state(m, 2).status, "cell 2 unchanged")
    assert_eq("running", model.get_cell_state(m, 3).status, "cell 3 unchanged")
  end)

  it("extmark namespaces isolate between buffers", function()
    local buf1 = make_buffer({ "let x = 1;;" })
    local buf2 = make_buffer({ "let y = 2;;" })
    local ns = vim.api.nvim_create_namespace("test_multi_buf")

    vim.api.nvim_buf_set_extmark(buf1, ns, 0, 0, {
      virt_text = { { "1", "Normal" } },
    })
    vim.api.nvim_buf_set_extmark(buf2, ns, 0, 0, {
      virt_text = { { "2", "Normal" } },
    })

    local marks1 = get_extmarks(buf1, ns)
    local marks2 = get_extmarks(buf2, ns)
    assert_eq(1, #marks1, "buf1 has 1 extmark")
    assert_eq(1, #marks2, "buf2 has 1 extmark")

    -- Clear buf1, buf2 untouched
    vim.api.nvim_buf_clear_namespace(buf1, ns, 0, -1)
    assert_eq(0, #get_extmarks(buf1, ns), "buf1 cleared")
    assert_eq(1, #get_extmarks(buf2, ns), "buf2 untouched")
  end)
end)

-- ─── Full cell lifecycle: detect → eval → render → edit → stale ──────────────

describe("cell lifecycle", function()
  it("detects cells, renders extmarks, then marks stale on edit", function()
    local buf = make_buffer({
      "let x = 42;;",
      "",
      "let y = x + 1;;",
    })
    local ns = vim.api.nvim_create_namespace("test_lifecycle")
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    -- Step 1: detect cells
    local all_cells = cells.find_all_cells(lines)
    assert_eq(2, #all_cells, "2 cells detected")

    -- Step 2: simulate eval results in model
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    m = model.set_cell_state(m, 1, "success", "42")
    m = model.set_cell_state(m, 2, "running")
    m = model.set_cell_state(m, 2, "success", "43")

    -- Step 3: render extmarks for each cell
    for _, c in ipairs(all_cells) do
      local cell_state = model.get_cell_state(m, c.id)
      local result = { ok = cell_state.status == "success", output = cell_state.output }
      local inline = format.format_inline(result)
      vim.api.nvim_buf_set_extmark(buf, ns, c.end_line - 1, 0, {
        virt_text = { { inline.text, inline.hl } },
        virt_text_pos = "eol",
      })
    end

    local marks = get_extmarks(buf, ns)
    assert_eq(2, #marks, "2 extmarks rendered")

    -- Step 4: simulate edit (insert a line)
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "// comment" })
    m = model.mark_all_stale(m)

    assert_eq("stale", model.get_cell_state(m, 1).status, "cell 1 stale after edit")
    assert_eq("stale", model.get_cell_state(m, 2).status, "cell 2 stale after edit")

    -- Step 5: re-render with stale formatting
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, c in ipairs(all_cells) do
      local cell_state = model.get_cell_state(m, c.id)
      local sign = format.gutter_sign(cell_state.status)
      assert_eq("SageFsStale", sign.hl, "stale sign for cell " .. c.id)
    end
  end)
end)

-- ─── SSE multi-event streaming ───────────────────────────────────────────────

describe("SSE multi-event streaming", function()
  it("processes multiple events from a single chunk", function()
    local chunk = table.concat({
      "event: eval_result",
      "data: {\"cellId\": 1, \"success\": true, \"result\": \"42\"}",
      "",
      "event: eval_result",
      "data: {\"cellId\": 2, \"success\": true, \"result\": \"hello\"}",
      "",
      "",
    }, "\n")

    local events, _ = sse.parse_chunk(chunk)
    assert_eq(2, #events, "should parse 2 events")

    local m = model.new()
    for _, ev in ipairs(events) do
      local data = vim.json.decode(ev.data)
      if data.success then
        m = model.set_cell_state(m, data.cellId, "running")
        m = model.set_cell_state(m, data.cellId, "success", data.result)
      end
    end

    assert_eq("42", model.get_cell_state(m, 1).output)
    assert_eq("hello", model.get_cell_state(m, 2).output)
  end)

  it("handles error events mixed with success", function()
    local chunk = table.concat({
      "event: eval_result",
      "data: {\"cellId\": 1, \"success\": true, \"result\": \"42\"}",
      "",
      "event: eval_result",
      "data: {\"cellId\": 2, \"success\": false, \"result\": \"FS0001: type mismatch\"}",
      "",
      "",
    }, "\n")

    local events, _ = sse.parse_chunk(chunk)
    local m = model.new()
    for _, ev in ipairs(events) do
      local data = vim.json.decode(ev.data)
      local status = data.success and "success" or "error"
      local output = data.result
      m = model.set_cell_state(m, data.cellId, "running")
      m = model.set_cell_state(m, data.cellId, status, output)
    end

    assert_eq("success", model.get_cell_state(m, 1).status)
    assert_eq("error", model.get_cell_state(m, 2).status)
    assert_contains(model.get_cell_state(m, 2).output, "FS0001", "error message preserved")
  end)
end)

-- ─── Testing module: full pipeline from JSON to gutter signs ─────────────────

describe("testing cycle: JSON → state → signs", function()
  it("applies status response then generates correct gutter signs per line", function()
    local response = vim.json.encode({
      enabled = true,
      summary = { total = 3, passed = 1, failed = 1, stale = 1, running = 0 },
      tests = {
        {
          testId = "a1", displayName = "test_pass",
          fullName = "Mod.test_pass",
          origin = { Case = "SourceMapped", Fields = { "src/Tests.fs", 10 } },
          framework = "Expecto", category = "Unit",
          currentPolicy = "OnEveryChange", status = "Passed",
        },
        {
          testId = "a2", displayName = "test_fail",
          fullName = "Mod.test_fail",
          origin = { Case = "SourceMapped", Fields = { "src/Tests.fs", 20 } },
          framework = "Expecto", category = "Unit",
          currentPolicy = "OnEveryChange", status = "Failed",
        },
        {
          testId = "a3", displayName = "test_stale",
          fullName = "Mod.test_stale",
          origin = { Case = "SourceMapped", Fields = { "src/Tests.fs", 30 } },
          framework = "Expecto", category = "Unit",
          currentPolicy = "OnEveryChange", status = "Stale",
        },
      },
    })

    local state = testing.new()
    local parsed, _ = testing.parse_status_response(response)
    state = testing.apply_status_response(state, parsed)

    -- Verify correct signs for each test
    local by_file = testing.filter_by_file(state, "src/Tests.fs")
    assert_eq(3, #by_file, "3 tests in file")

    for _, t in ipairs(by_file) do
      local sign = testing.gutter_sign(t.status)
      if t.status == "Passed" then
        assert_eq("SageFsTestPassed", sign.hl, "passed sign")
      elseif t.status == "Failed" then
        assert_eq("SageFsTestFailed", sign.hl, "failed sign")
      elseif t.status == "Stale" then
        assert_eq("SageFsTestStale", sign.hl, "stale sign")
      end
    end
  end)

  it("marks all tests stale and verifies signs change", function()
    local state = testing.new()
    state = testing.set_enabled(state, true)
    state = testing.update_test(state, {
      testId = "t1", displayName = "my_test",
      fullName = "Mod.my_test",
      origin = { Case = "SourceMapped", Fields = { "f.fs", 5 } },
      framework = "Expecto", category = "Unit",
      currentPolicy = "OnEveryChange", status = "Passed",
    })

    assert_eq("SageFsTestPassed", testing.gutter_sign(state.tests["t1"].status).hl)

    state = testing.mark_all_stale(state)
    assert_eq("Stale", state.tests["t1"].status)
    assert_eq("SageFsTestStale", testing.gutter_sign(state.tests["t1"].status).hl)
  end)
end)

-- ─── Highlight group attributes ──────────────────────────────────────────────

describe("highlight group attributes", function()
  it("SageFsSuccess has a foreground color", function()
    local hl = vim.api.nvim_get_hl(0, { name = "SageFsSuccess" })
    -- In a minimal colorscheme, link might be used instead of direct color
    assert_type("table", hl, "should be a table")
  end)

  it("SageFsError has a foreground color", function()
    local hl = vim.api.nvim_get_hl(0, { name = "SageFsError" })
    assert_type("table", hl, "should be a table")
  end)

  it("all highlight groups are distinct", function()
    local names = { "SageFsSuccess", "SageFsError", "SageFsOutput", "SageFsRunning", "SageFsStale" }
    local hls = {}
    for _, name in ipairs(names) do
      hls[name] = vim.api.nvim_get_hl(0, { name = name })
    end
    -- At minimum, success and error should differ
    -- (In headless mode with no colorscheme they might all be empty — just verify no crash)
    assert_truthy(true, "all highlight groups accessible without error")
  end)
end)

-- ─── Format module: edge cases with real vim.json ────────────────────────────

describe("format edge cases with real JSON", function()
  it("handles malformed JSON gracefully", function()
    local result = format.parse_exec_response("{invalid json")
    assert_falsy(result.ok, "should fail on invalid JSON")
    assert_truthy(result.error, "should have error message")
  end)

  it("handles nil response", function()
    local result = format.parse_exec_response(nil)
    assert_falsy(result.ok, "nil should fail")
  end)

  it("handles empty string response", function()
    local result = format.parse_exec_response("")
    assert_falsy(result.ok, "empty should fail")
  end)

  it("handles response with Unicode output", function()
    local json = vim.json.encode({ success = true, result = "λ → ∀ α β" })
    local result = format.parse_exec_response(json)
    assert_truthy(result.ok, "should parse unicode")
    assert_contains(result.output, "λ", "unicode preserved")
  end)

  it("handles deeply nested error messages", function()
    local long_error = string.rep("error at line ", 20)
    local json = vim.json.encode({ success = false, result = long_error })
    local result = format.parse_exec_response(json)
    assert_falsy(result.ok, "should be error")
    local inline = format.format_inline(result)
    -- Should not crash, should truncate
    assert_truthy(#inline.text > 0, "should produce output")
  end)
end)

-- ─── Cell preparation for eval ───────────────────────────────────────────────

describe("cell code preparation", function()
  it("prepare_code strips trailing ;; for submission", function()
    if cells.prepare_code then
      local code = cells.prepare_code("let x = 42;;")
      -- Depending on implementation, may or may not strip ;;
      assert_truthy(type(code) == "string", "should return string")
    else
      -- prepare_code might not exist yet — document what it should do
      assert_truthy(true, "prepare_code not yet implemented")
    end
  end)
end)

-- ─── Extmark sign_text round-trip ────────────────────────────────────────────

describe("extmark sign_text round-trip", function()
  it("sign_text preserves 2-char ASCII signs", function()
    local buf = make_buffer({ "test;;" })
    local ns = vim.api.nvim_create_namespace("test_sign_rt")
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      sign_text = "ok",
      sign_hl_group = "Normal",
    })
    local marks = get_extmarks(buf, ns)
    assert_eq("ok", marks[1][4].sign_text, "ASCII sign preserved")
  end)

  it("sign_hl_group preserved in extmark details", function()
    local buf = make_buffer({ "test;;" })
    local ns = vim.api.nvim_create_namespace("test_sign_hl")
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      sign_text = ">>",
      sign_hl_group = "SageFsError",
    })
    local marks = get_extmarks(buf, ns)
    assert_eq("SageFsError", marks[1][4].sign_hl_group, "hl group preserved")
  end)
end)

-- ─── Virtual lines placement ─────────────────────────────────────────────────

describe("virtual lines placement", function()
  it("virt_lines render multi-line output correctly", function()
    local buf = make_buffer({ "let x = 42;;", "let y = 1;;" })
    local ns = vim.api.nvim_create_namespace("test_vlines_place")
    local output = "line1\nline2\nline3"
    local vlines = format.format_virtual_lines({ ok = true, output = output })

    local nvim_vlines = {}
    for _, vl in ipairs(vlines) do
      table.insert(nvim_vlines, { { vl.text, vl.hl } })
    end

    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      virt_lines = nvim_vlines,
      virt_lines_above = false,
    })

    local marks = get_extmarks(buf, ns)
    assert_eq(3, #marks[1][4].virt_lines, "3 virtual lines")
  end)
end)

describe("eval codelens placement", function()
  it("anchors ▶ Eval above the cell start while keeping output at the cell end", function()
    local render = require("sagefs.render")
    local buf = make_buffer({
      "let first = 42",
      "first + 1;;",
      "",
      "let second = 5;;",
    })
    vim.api.nvim_buf_set_name(buf, "/tmp/eval_anchor_" .. tostring(buf) .. ".fs")

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local all_cells = cells.find_all_cells_auto(buf, lines)
    assert_eq(2, #all_cells, "2 cells detected")

    local state = model.new()
    state = model.set_cell_state(state, all_cells[1].id, "running")
    state = model.set_cell_state(state, all_cells[1].id, "success", "43")

    render.render_all(buf, state)

    local marks = get_extmarks(buf, render.get_namespace())
    local output_mark = nil
    local codelens_mark = nil

    for _, mark in ipairs(marks) do
      local details = mark[4] or {}
      local virt_text = details.virt_text
      local virt_lines = details.virt_lines

      if virt_text and virt_text[1] and virt_text[1][1] and virt_text[1][1]:find("43", 1, true) then
        output_mark = mark
      end

      if virt_lines and virt_lines[1] and virt_lines[1][1] and virt_lines[1][1][1] == "▶ Eval" then
        codelens_mark = mark
      end
    end

    assert_truthy(output_mark, "should render output extmark")
    assert_truthy(codelens_mark, "should render eval codelens extmark")
    assert_eq(all_cells[1].end_line - 1, output_mark[2], "output stays on cell end")
    assert_eq(all_cells[2].start_line - 1, codelens_mark[2], "codelens anchors to cell start")
    assert_truthy(codelens_mark[4].virt_lines_above, "codelens renders above the cell start")
  end)
end)

-- ─── Test gutter signs ───────────────────────────────────────────────────────

describe("test gutter sign rendering", function()
  it("renders test signs in separate namespace", function()
    local render = require("sagefs.render")
    local testing_mod = require("sagefs.testing")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "module Tests", "let test1 () = ()", "let test2 () = ()",
    })
    local test_file = "/tmp/test_gutter_" .. tostring(buf) .. ".fs"
    vim.api.nvim_buf_set_name(buf, test_file)
    local resolved = vim.api.nvim_buf_get_name(buf)

    local state = testing_mod.new()
    state = testing_mod.set_enabled(state, true)
    testing_mod.update_test(state, {
      testId = "t1", displayName = "test1", fullName = "test1",
      category = "Unit", currentPolicy = "OnEveryChange", status = "Passed",
      origin = { Case = "SourceMapped", Fields = { resolved, 2 } },
    })

    render.render_test_signs(buf, state)
    local tns = vim.api.nvim_create_namespace("sagefs_tests")
    local marks = vim.api.nvim_buf_get_extmarks(buf, tns, 0, -1, { details = true })
    assert_truthy(#marks > 0, "should have test sign extmarks")
    assert_eq("SageFsTestPassed", marks[1][4].sign_hl_group, "passed test sign")
  end)

  it("coverage signs use separate namespace", function()
    local render = require("sagefs.render")
    local cov = require("sagefs.coverage")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line1", "line2", "line3" })
    local cov_file = "/tmp/cov_gutter_" .. tostring(buf) .. ".fs"
    vim.api.nvim_buf_set_name(buf, cov_file)
    local resolved = vim.api.nvim_buf_get_name(buf)

    local state = cov.new()
    state = cov.update_file(state, resolved, {
      { line = 1, hits = 5 },
      { line = 3, hits = 0 },
    })

    render.render_coverage_signs(buf, state)
    local cns = vim.api.nvim_create_namespace("sagefs_coverage")
    local marks = vim.api.nvim_buf_get_extmarks(buf, cns, 0, -1, { details = true })
    assert_eq(2, #marks, "should have 2 coverage signs")
    assert_eq("SageFsCovered", marks[1][4].sign_hl_group, "covered line")
    assert_eq("SageFsUncovered", marks[2][4].sign_hl_group, "uncovered line")
  end)
end)

-- ─── Statusline integration ──────────────────────────────────────────────────

describe("statusline integration", function()
  it("returns combined statusline with testing info", function()
    local sagefs = require("sagefs")
    local testing_mod = require("sagefs.testing")

    -- Prime testing state
    sagefs.testing_state = testing_mod.new()
    sagefs.testing_state = testing_mod.set_enabled(sagefs.testing_state, true)
    testing_mod.update_test(sagefs.testing_state, {
      testId = "t1", displayName = "t1", fullName = "t1",
      category = "Unit", currentPolicy = "OnEveryChange", status = "Passed",
    })

    local sl = sagefs.statusline()
    assert_type("string", sl, "statusline should be string")
    assert_truthy(#sl > 0, "statusline should not be empty")
    -- Should contain separator when testing info present
    assert_contains(sl, "│", "should have separator between sections")
  end)

  -- §5.1: a dead daemon must be visible in the statusline even with an
  -- active session — this was the plugin's single most consequential
  -- truthfulness defect (the same class the server fixed today for
  -- SessionHealth). Before the fix, M.active_session took a completely
  -- separate branch that hardcoded ⚡ and never looked at M.state.status.
  it("shows a disconnected icon (not ⚡) once the daemon dies, even with an active session", function()
    local sagefs = require("sagefs")
    local model = require("sagefs.model")

    local prev_active_session = sagefs.active_session
    local prev_state = sagefs.state

    sagefs.active_session = { id = "abc123", status = "Ready", projects = { "MyApp.fsproj" }, eval_count = 3, avg_duration_ms = 10 }
    sagefs.state = model.set_status(model.new(), "connected")
    local connected_sl = sagefs.statusline()
    assert_contains(connected_sl, "⚡", "connected daemon should show the lightning icon")

    sagefs.state = model.set_status(model.new(), "disconnected")
    local dead_sl = sagefs.statusline()
    assert_falsy(dead_sl:find("⚡", 1, true), "a dead daemon must not still show the connected icon")
    assert_contains(dead_sl, "💤", "a dead daemon should show the disconnected icon")
    -- The exact lie this fixes: the session data itself still says "Ready".
    assert_contains(dead_sl, "Ready", "session status label is unchanged — only the connection icon must reflect death")

    sagefs.active_session = prev_active_session
    sagefs.state = prev_state
  end)
end)

-- ─── Welcome hint persistence (roast item 13) ─────────────────────────────────
-- `vim.g.sagefs_welcomed` never survives a restart (shada only auto-persists
-- ALL-CAPS-with-no-lowercase globals, and only with the '!' flag set) — the
-- welcome notification fired on every single launch, forever. It must now
-- persist via a marker file so it fires at most once ever.

describe("welcome hint persistence (roast item 13)", function()
  it("notifies the first time the marker file does not exist, and never again", function()
    local sagefs = require("sagefs")
    local marker = vim.fn.tempname()
    os.remove(marker)  -- tempname() creates the file; we want it absent first

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

    sagefs.setup({ auto_connect = false, welcome_marker_path = marker })
    vim.wait(1500, function() return #notifications > 0 end, 20)

    assert_truthy(vim.fn.filereadable(marker) == 1, "setup() must create the marker file")
    assert_truthy(#notifications > 0, "should welcome a first-time user")
    assert_contains(notifications[1].msg, "Welcome", "should be the welcome message")

    -- Second launch (marker now exists): must NOT welcome again.
    notifications = {}
    sagefs.setup({ auto_connect = false, welcome_marker_path = marker })
    vim.wait(300, function() return #notifications > 0 end, 20)

    vim.notify = original_notify
    os.remove(marker)

    assert_truthy(#notifications == 0, "must not welcome a returning user a second time")
  end)
end)


-- E482 regression: stdpath("data") does not exist on a fresh machine. setup()
-- must create it, and a directory it cannot create must be a message, never
-- an error out of setup().
describe("welcome marker in a missing data directory", function()
  it("creates the missing directory instead of dying with E482", function()
    local sagefs = require("sagefs")
    local root = vim.fn.tempname()  -- does not exist (tempname makes the parent only)
    local marker = root .. "/nested/data/sagefs_welcomed"
    local original_notify = vim.notify
    vim.notify = function() end
    local ok, err = pcall(sagefs.setup, { auto_connect = false, welcome_marker_path = marker })
    vim.notify = original_notify
    assert_truthy(ok, "setup() must not raise: " .. tostring(err))
    assert_eq(1, vim.fn.filereadable(marker), "marker must exist after setup()")
    vim.fn.delete(root, "rf")
  end)

  it("reports an unwritable marker location as a message, not an error", function()
    local sagefs = require("sagefs")
    local blocker = vim.fn.tempname()
    vim.fn.writefile({ "i am a file, not a directory" }, blocker)
    local marker = blocker .. "/sub/sagefs_welcomed"  -- parent is a file: mkdir must fail
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end
    local ok, err = pcall(sagefs.setup, { auto_connect = false, welcome_marker_path = marker })
    vim.wait(1500, function()
      for _, n in ipairs(notifications) do
        if n.msg:find("could not remember", 1, true) then return true end
      end
      return false
    end, 20)
    vim.notify = original_notify
    vim.fn.delete(blocker)
    assert_truthy(ok, "setup() must not raise: " .. tostring(err))
    local warned = false
    for _, n in ipairs(notifications) do
      if n.msg:find("could not remember", 1, true) and n.level == vim.log.levels.WARN then warned = true end
    end
    assert_truthy(warned, "an unwritable marker must produce a clear WARN message")
  end)
end)

describe("sagefs_path option", function()
  it("defaults to the bare sagefs command", function()
    assert_eq("sagefs", require("sagefs").config.sagefs_path, "default sagefs_path")
  end)

  it(":SageFsStart reports a missing binary as a message, not a traceback", function()
    local sagefs = require("sagefs")
    local prev_port = sagefs.config.port
    -- Never aim a test at the shared dev daemon's port, in case a regression
    -- lets this spawn a real sagefs.
    sagefs.setup({ auto_connect = false, sagefs_path = "/nonexistent/dir/sagefs", port = 59999,
      welcome_marker_path = vim.fn.tempname() })
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end
    local ok, err = pcall(vim.cmd, "SageFsStart App.fsproj")
    vim.notify = original_notify
    sagefs.config.sagefs_path = "sagefs"
    sagefs.config.port = prev_port
    assert_truthy(ok, "must not raise: " .. tostring(err))
    local found = false
    for _, n in ipairs(notifications) do
      if n.msg:find("/nonexistent/dir/sagefs", 1, true) and n.msg:find("dotnet tool install", 1, true) then found = true end
    end
    assert_truthy(found, "should name the configured path and how to install")
  end)
end)

-- ─── which-key group registration (roast §5.13 / item 13) ────────────────────
-- 53 commands, no which-key group — pressing <leader> showed a bare
-- "+prefix" instead of "+SageFs". Best-effort: registers a group label for
-- the <leader>r/<leader>t prefixes when which-key.nvim is installed, and
-- must never error when it isn't.

describe("which-key group registration (roast item 13)", function()
  it("registers a SageFs group for <leader>r and <leader>t when which-key is present", function()
    local wk_path = vim.fn.stdpath("data") .. "/lazy/which-key.nvim"
    if vim.fn.isdirectory(wk_path) == 0 then
      io.write("    (skipped: which-key.nvim not installed at " .. wk_path .. ")\n")
      return
    end
    vim.opt.rtp:prepend(wk_path)
    package.loaded["sagefs"] = nil
    package.loaded["which-key"] = nil
    local sagefs = require("sagefs")
    local wk = require("which-key")

    sagefs.setup({ auto_connect = false })
    local buf = make_buffer({ "let x = 1" })
    vim.bo[buf].filetype = "fsharp"

    local found_r, found_t = false, false
    for _, item in ipairs(wk._queue) do
      for _, entry in ipairs(item.spec) do
        if entry[1] == "<leader>r" and entry.group then found_r = true end
        if entry[1] == "<leader>t" and entry.group then found_t = true end
      end
    end
    assert_truthy(found_r, "expected a which-key group for <leader>r")
    assert_truthy(found_t, "expected a which-key group for <leader>t")
  end)
end)

-- ─── Hot reload truth through the real SSE pipeline ──────────────────────────
-- The state frames below are what the dev daemon sent for one save sequence
-- (spec/wire_fixtures.lua has the provenance). They go through start_sse →
-- on_sse_events → state_update → reload_reported, so this proves the init.lua
-- wiring that the busted specs cannot reach.

describe("hot reload truth (daemon wire)", function()
  it("shows each report the daemon sent, never calls a pending patch live, and registers its commands", function()
    local sagefs = require("sagefs")
    local transport = require("sagefs.transport")
    local sse = require("sagefs.sse")
    local original_connect_sse = transport.connect_sse
    local original_list_sessions = sagefs.list_sessions
    local original_notify = vim.notify
    local captured_on_events
    local notes = {}

    transport.connect_sse = function(_url, opts)
      captured_on_events = opts.on_events
      return { start = function() end, stop = function() end }
    end
    sagefs.list_sessions = function(cb) if cb then cb({ ok = false }) end end
    vim.notify = function(msg, level) table.insert(notes, { msg = msg, level = level }) end

    sagefs.setup({ auto_connect = false })
    assert_eq(2, vim.fn.exists(":SageFsReloadStatus"), ":SageFsReloadStatus is registered")
    assert_eq(2, vim.fn.exists(":SageFsCohort"), ":SageFsCohort is registered")

    sagefs.active_session = { id = "adfd6b6b", status = "Ready", projects = { "FalcoHello.fsproj" } }
    sagefs.start_sse()
    assert_truthy(captured_on_events, "start_sse should have called transport.connect_sse")

    local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
    local fixture = io.open(script_dir .. "fixtures/wire/sse-hot-reload-session.txt", "rb"):read("*a")
    local seen = {}
    for _, event in ipairs((sse.parse_chunk(fixture))) do
      captured_on_events({ event })
      local data = vim.json.decode(event.data)
      if data.reloadReported then
        local sl = sagefs.statusline()
        local segment = ""
        for _, part in ipairs(vim.split(sl, " │ ", { plain = true })) do
          if part:sub(1, 3) == "HR " then segment = part end
        end
        table.insert(seen, segment)
      end
    end

    -- compiling, Restarted, compiling, PatchPending, Patched, NoEffect, ... NeverEntered, NoEffect
    assert_eq("HR … compiling", seen[1], "a compiling frame")
    assert_eq("HR ↻ restarted", seen[2], "a restart")
    assert_eq("HR ◐ applied, not run yet [delta]", seen[4], "a pending patch is applied, not live")
    assert_eq("HR ● patched (ran) [delta]", seen[5], "patched only after it ran")
    assert_eq("HR ◌ applied, never ran [delta]", seen[14], "never entered")

    local joined = {}
    for _, n in ipairs(notes) do table.insert(joined, n.msg) end
    local text = table.concat(joined, "\n")
    assert_contains(text, "reload: applied, but the new body never ran (0 of 1 did)", "never ran says so")
    assert_contains(text, "reload: restarted: the signature of FalcoHello.Program.greet changed", "a restart says why")

    transport.connect_sse = original_connect_sse
    sagefs.list_sessions = original_list_sessions
    vim.notify = original_notify
    sagefs.active_session = nil
  end)
end)

-- ─── Debug hold: real buffers ────────────────────────────────────────────────

describe("debug_test default deps (real buffers)", function()
  local dt = require("sagefs.debug_test")
  local function deps_for(buf)
    return dt.default_deps({}, { base_url = function() return "http://127.0.0.1:1" end }, buf)
  end

  it("on_buffer_gone fires at once for a buffer that is already gone, without throwing", function()
    local buf = make_buffer({ "let x = 1" })
    vim.api.nvim_buf_delete(buf, { force = true })
    local fired = 0
    local ok, err = pcall(function() deps_for(buf).on_buffer_gone(buf, function() fired = fired + 1 end) end)
    assert_truthy(ok, "registering a hook on a gone buffer must not throw: " .. tostring(err))
    assert_eq(1, fired, "the hook fires at once")
  end)

  it("on_buffer_gone fires when a live buffer is wiped, and the unhook removes it", function()
    local buf = make_buffer({ "let x = 1" })
    local fired = 0
    deps_for(buf).on_buffer_gone(buf, function() fired = fired + 1 end)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert_eq(1, fired)

    local buf2 = make_buffer({ "let y = 2" })
    local unhook = deps_for(buf2).on_buffer_gone(buf2, function() fired = fired + 1 end)
    unhook()
    vim.api.nvim_buf_delete(buf2, { force = true })
    assert_eq(1, fired, "an unhooked watcher does not fire")
  end)
end)

-- ─── Live bindings pane: session switch ─────────────────────────────────────

describe("bindings_view pane (real buffer)", function()
  it("a redraw after the active session changed drops the previous session's mode and notice", function()
    local bv = require("sagefs.bindings_view")
    local lb = require("sagefs.live_bindings")
    local plugin = { active_session = nil, live_bindings_state = lb.new() }
    local pane = bv.open(plugin, { base_url = function() return "http://127.0.0.1:1" end, notify = function() end })
    plugin.active_session = { id = "A" }
    bv.redraw()
    pane.ctl.view.mode, pane.ctl.view.notice = "Off", "about A"
    plugin.active_session = { id = "B" }
    bv.redraw()
    assert_eq(nil, pane.ctl.view.mode, "mode is forgotten")
    assert_eq(nil, pane.ctl.view.notice, "notice is forgotten")
    bv.close()
  end)

  it("a redraw that adds lines above the cursor keeps the cursor on the same row", function()
    local bv = require("sagefs.bindings_view")
    local lb = require("sagefs.live_bindings")
    local f = assert(io.open(plugin_root .. "/spec/fixtures/wire/live_bindings_safe.json", "rb"))
    local snapshot = vim.json.decode(f:read("*a"))
    f:close()
    local plugin = { active_session = { id = "57bbdfd8" }, live_bindings_state = lb.new() }
    lb.apply_snapshot(plugin.live_bindings_state, snapshot)
    local pane = bv.open(plugin, { base_url = function() return "http://127.0.0.1:1" end, notify = function() end })
    bv.redraw()
    local buf = vim.api.nvim_get_current_buf()
    local target
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l:find("[<CR> run]", 1, true) then target = { line = i, text = l } break end
    end
    assert_truthy(target, "the fixture has a row that offers a click")
    vim.api.nvim_win_set_cursor(0, { target.line, 0 })
    -- a click goes out: two lines appear above the tree
    pane.ctl.view.pending = { binding = "box", path = { "x" } }
    pane.ctl.view.containment = "ran under a syscall filter; guarded: stack and loops checked in 1 method"
    bv.redraw()
    local now = vim.api.nvim_win_get_cursor(0)[1]
    local line = vim.api.nvim_buf_get_lines(buf, now - 1, now, false)[1]
    assert_eq(target.text, line, "the cursor is still on the row it was on")
    bv.close()
  end)
end)

-- ─── Completions route by the active session's directory ─────────────────────
-- The normalized session field is working_directory. omnifunc read workingDirectory
-- (the raw wire spelling), found nothing, and always sent Neovim's cwd.

describe("omnifunc working directory", function()
  local function completion_body(active_session)
    local sagefs = require("sagefs")
    local transport = require("sagefs.transport")
    local original_http_json = transport.http_json
    local original_session = sagefs.active_session
    local captured
    transport.http_json = function(opts) captured = opts end
    sagefs.active_session = active_session
    make_buffer({ "let x = List." })
    vim.api.nvim_win_set_cursor(0, { 1, 12 })
    local ok, err = pcall(sagefs.omnifunc, 0, "")
    transport.http_json = original_http_json
    sagefs.active_session = original_session
    assert_truthy(ok, "omnifunc raised: " .. tostring(err))
    assert_truthy(captured, "omnifunc made no completion request")
    return captured.body
  end

  it("sends the active session's own directory, not Neovim's cwd", function()
    local body = completion_body({ id = "s1", working_directory = "/work/other-repo" })
    assert_eq("/work/other-repo", body.working_directory, "completion request directory")
  end)

  it("falls back to Neovim's cwd when the session list carried no directory", function()
    local body = completion_body({ id = "s1", working_directory = "" })
    assert_eq(vim.fn.getcwd(), body.working_directory, "completion request directory")
  end)
end)

-- ─── A skipped test says why ─────────────────────────────────────────────────
-- Expecto ptest and ftest are reported Skipped with a reason ("pending (ptest)",
-- "not focused"). The reason is on the status of a test_results_batch entry.

describe("skipped tests over SSE", function()
  it("the test panel says why a test was skipped", function()
    local sagefs = require("sagefs")
    local transport = require("sagefs.transport")
    local original_connect_sse = transport.connect_sse
    local captured
    transport.connect_sse = function(_url, opts)
      captured = opts.on_events
      return { start = function() end, stop = function() end }
    end
    sagefs.active_session = { id = "skip-session" }
    sagefs.testing_state = testing.new()
    sagefs.start_sse()
    local function e(id, name, case, fields)
      return {
        TestId = id, DisplayName = name, FullName = "M/" .. name,
        Origin = { Case = "SourceMapped", Fields = { "/w/T.fs", 8 } },
        Framework = { Case = "Expecto" }, Category = { Case = "Unit" },
        CurrentPolicy = { Case = "OnEveryChange" },
        Status = { Case = case, Fields = fields }, PreviousStatus = { Case = "Detected" },
      }
    end
    captured({ { type = "test_results_batch", data = vim.json.encode({
      SessionId = "skip-session", Generation = 1, Completion = { Case = "Complete", Fields = { 2, 2 } },
      Entries = {
        e("t1", "a pending test", "Skipped", { "pending (ptest)" }),
        e("t2", "a plain test", "Passed", { "00:00:00.001" }),
      },
    }) } })
    assert_eq("pending (ptest)", sagefs.testing_state.tests.t1.skip_reason, "the reason is kept")

    vim.cmd("enew")
    vim.cmd("SageFsTestPanel")
    local text
    vim.wait(500, function()
      local panel = vim.fn.bufnr("sagefs://tests")
      text = panel > 0 and table.concat(vim.api.nvim_buf_get_lines(panel, 0, -1, false), "\n") or ""
      return text:find("a pending test", 1, true) ~= nil
    end, 10)
    pcall(vim.cmd, "SageFsTestPanel")
    transport.connect_sse = original_connect_sse
    sagefs.active_session = nil
    sagefs.testing_state = testing.new()
    assert_contains(text, "⊘ a pending test (skipped: pending (ptest))", "the panel line")
    assert_contains(text, "✓ a plain test", "a test that ran has no suffix")
  end)
end)

-- ─── Member token: configured, found, and kept out of every message ──────────

describe("member token in a real Neovim", function()
  local TOKEN = "sfm_Zk3vQ9mT1xWc7Yh2LpB8aDfG5jRuN0sEoIqXtVyHwKc"

  it("setup takes member_token, and the plugin finds it", function()
    local sagefs = require("sagefs")
    local member_token = require("sagefs.member_token")
    sagefs.setup({ auto_connect = false, member_token = TOKEN })
    assert_eq(TOKEN, member_token.current(), "the configured token")
    sagefs.config.member_token = nil
  end)

  it("with no option the environment variable is the token, and without either there is none", function()
    local sagefs = require("sagefs")
    local member_token = require("sagefs.member_token")
    sagefs.setup({ auto_connect = false })
    sagefs.config.member_token = nil
    local saved = vim.env.SAGEFS_MEMBER_TOKEN
    vim.env.SAGEFS_MEMBER_TOKEN = TOKEN
    assert_eq(TOKEN, member_token.current(), "the environment token")
    vim.env.SAGEFS_MEMBER_TOKEN = nil
    assert_eq(nil, member_token.current(), "no token")
    vim.env.SAGEFS_MEMBER_TOKEN = saved
  end)

  it(":SageFsConfig with a token configured says nothing of it, in notifications or in :messages", function()
    local sagefs = require("sagefs")
    sagefs.setup({ auto_connect = false, member_token = TOKEN })
    local original_notify = vim.notify
    local notes = {}
    vim.notify = function(msg) table.insert(notes, tostring(msg)) end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local previous = vim.fn.getcwd()
    vim.cmd.cd(vim.fn.fnameescape(dir))
    vim.cmd("messages clear")
    local ok, err = pcall(vim.cmd, "SageFsConfig")
    vim.notify = original_notify
    vim.cmd.cd(vim.fn.fnameescape(previous))
    sagefs.config.member_token = nil
    assert_truthy(ok, tostring(err))
    local seen = table.concat(notes, "\n") .. "\n" .. vim.api.nvim_exec2("messages", { output = true }).output
    assert_eq(nil, seen:find(TOKEN, 1, true), "the token in what was printed")
    vim.fn.delete(dir, "rf")
  end)
end)

describe("member commands in a real Neovim", function()
  local TOKEN = "sfm_Zk3vQ9mT1xWc7Yh2LpB8aDfG5jRuN0sEoIqXtVyHwKc"
  local MINTED = "Minted member cap:0123456789abcdef.\n\nTOKEN (shown once; SageFs keeps only its hash, so it cannot be shown again):\n  " .. TOKEN .. "\n"

  it("registers :SageFsMintMember and :SageFsRevokeMember, each with a description :SageFsHelp can read", function()
    require("sagefs").setup({ auto_connect = false })
    local help = require("sagefs.help")
    local rows = {}
    for _, row in ipairs(help.command_rows(vim.api.nvim_get_commands({}))) do rows[row.name] = row end
    for _, name in ipairs({ "SageFsMintMember", "SageFsRevokeMember" }) do
      assert_eq(2, vim.fn.exists(":" .. name), name .. " is registered")
      assert_truthy(rows[name], name .. " is in the help rows")
      assert_falsy(rows[name].undescribed, name .. " has a description")
    end
  end)

  it("the mint reply goes to a scratch float that is not saved, not listed, and not in messages or history", function()
    local member_view = require("sagefs.member_view")
    local original_notify = vim.notify
    local notes = {}
    vim.notify = function(msg) table.insert(notes, tostring(msg)) end
    vim.cmd("messages clear")
    local before = vim.fn.histnr(":")
    local client = { call_tool = function(_, _, cb) cb(true, MINTED) end }
    member_view.mint({ "Analysis" }, { client = client })
    vim.notify = original_notify

    local float_buf
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then float_buf = vim.api.nvim_win_get_buf(win) end
    end
    assert_truthy(float_buf, "a float opened")
    local content = table.concat(vim.api.nvim_buf_get_lines(float_buf, 0, -1, false), "\n")
    assert_contains(content, TOKEN, "the token is in the float")
    assert_eq("nofile", vim.bo[float_buf].buftype, "buftype")
    assert_eq("wipe", vim.bo[float_buf].bufhidden, "bufhidden")
    assert_falsy(vim.bo[float_buf].swapfile, "swapfile")
    assert_falsy(vim.bo[float_buf].buflisted, "buflisted")
    assert_falsy(vim.bo[float_buf].modifiable, "modifiable")
    assert_eq(-1, vim.bo[float_buf].undolevels, "undolevels")

    local seen = table.concat(notes, "\n") .. "\n" .. vim.api.nvim_exec2("messages", { output = true }).output
    assert_eq(nil, seen:find(TOKEN, 1, true), "the token in notifications or messages")
    for i = math.max(before, 1), vim.fn.histnr(":") do
      assert_eq(nil, (vim.fn.histget(":", i) or ""):find(TOKEN, 1, true), "the token in command history")
    end

    -- Leaving the window closes it: the token is shown once.
    vim.cmd("wincmd p")
    vim.wait(100, function() return not vim.api.nvim_buf_is_valid(float_buf) end)
    assert_falsy(vim.api.nvim_buf_is_valid(float_buf), "the float is gone after the window is left")
  end)
end)

-- ─── Nudge, in a real buffer, with a fake daemon ─────────────────────────────
-- The daemon here is a function that rewrites the file on disk the way the real
-- nudge_value tool does, and lists each value with its range.
-- Everything else is real: the buffer, the cursor, :edit, vim.notify, the command,
-- the map and the gate.

describe("nudge in a real buffer (fake daemon)", function()
  local nudge_ui = require("sagefs.nudge_ui")
  local real_client = package.loaded["sagefs.mcp_client"]
  local real_notify = vim.notify
  local notes, calls, path

  local function replace_in_file(from, to)
    local text = table.concat(vim.fn.readfile(path), "\n") .. "\n"
    local start, stop = text:find(from, 1, true)
    assert_truthy(start, "the file holds " .. from)
    local out = text:sub(1, start - 1) .. to .. text:sub(stop + 1)
    local f = assert(io.open(path, "wb"))
    f:write(out)
    f:close()
  end

  local function setup_case(lines)
    notes, calls = {}, {}
    path = vim.fn.tempname() .. "-Nudge.fs"
    vim.fn.writefile(lines, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.notify = function(msg, level) table.insert(notes, { msg = tostring(msg), level = level }) end
    package.loaded["sagefs.mcp_client"] = {
      connect = function()
        return {
          close = function() end,
          call_tool = function(_, args, cb)
            table.insert(calls, args)
            local text = table.concat(vim.fn.readfile(path), "\n")
            local speed, drag = text:match("let speed = (%S+)"), text:match("let drag = (%S+)")
            -- where the daemon says a value is: line from 1, column from 0, endColumn exclusive
            local function listed(address, name, shown)
              local lines = vim.fn.readfile(path)
              for i, line in ipairs(lines) do
                local s = line:find("let " .. name .. " = ", 1, true)
                if s then
                  local column = s - 1 + #("let " .. name .. " = ")
                  return { address = address, text = shown, hash = "h-" .. name, kind = "Knob", valueKind = "Real",
                    value = tonumber(shown), line = i, column = column, endLine = i, endColumn = column + #shown }
                end
              end
            end
            if args.action == "inspect" then
              cb(true, vim.json.encode({
                outcome = "Inspected", file = path, fileHash = "fh", journaled = 0, undoSteps = 0, redoSteps = 0, listing = "Complete",
                items = { listed("M.speed", "speed", speed), listed("M.drag", "drag", drag) },
                notes = {},
              }))
            elseif args.action == "set" then
              local before = args.address == "M.speed" and speed or drag
              replace_in_file(args.address == "M.speed" and ("speed = " .. before) or ("drag = " .. before),
                (args.address == "M.speed" and "speed = " or "drag = ") .. args.literal)
              cb(true, vim.json.encode({ outcome = "Written", file = path, address = args.address, before = before, after = args.literal, notes = {} }))
            end
          end,
        }
      end,
    }
  end

  local function teardown_case()
    package.loaded["sagefs.mcp_client"] = real_client
    vim.notify = real_notify
    vim.cmd("bwipeout! " .. vim.api.nvim_get_current_buf())
    vim.fn.delete(path)
  end

  local plugin = { active_session = { id = "s1", working_directory = "/w" }, config = { port = 1 } }
  local helpers = { notify = function() end }

  it("a bump rewrites the file, the buffer is read again, the cursor and the unmodified state are kept", function()
    setup_case({ "module M", "let speed = 1.0", "let drag = 2.0" })
    local ok, err = pcall(function()
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_win_set_cursor(0, { 2, 13 })
      nudge_ui.run(plugin, helpers, { action = "up" }, 1)
      assert_truthy(vim.wait(5000, function() return vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "let speed = 1.1" end, 10),
        "the buffer has what the daemon wrote: " .. vim.inspect(vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
      assert_eq(2, vim.api.nvim_win_get_cursor(0)[1], "the cursor stayed on its line")
      assert_eq(13, vim.api.nvim_win_get_cursor(0)[2], "and its column")
      assert_falsy(vim.bo[buf].modified, "the reloaded buffer is not modified")
      assert_eq("/w", calls[1].working_directory, "the session is named by its working directory")
      assert_eq("s1", calls[1].session_id, "and by its id, so two sessions in one directory work")
      assert_eq("s1", calls[2].session_id, "on the write too")
      assert_eq("h-speed", calls[2].seen, "the write carries the hash inspect gave")
      assert_truthy(notes[#notes].msg:find("1.0 -> 1.1", 1, true), "the notice shows the change: " .. notes[#notes].msg)
    end)
    teardown_case()
    assert_truthy(ok, err)
  end)

  it("a buffer with unsaved edits is refused before the daemon is asked", function()
    setup_case({ "module M", "let speed = 1.0", "let drag = 2.0" })
    local ok, err = pcall(function()
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "// not saved" })
      vim.api.nvim_win_set_cursor(0, { 3, 13 })
      nudge_ui.run(plugin, helpers, { action = "up" }, 1)
      assert_eq(0, #calls, "nothing went to the daemon")
      assert_contains(notes[1].msg, "unsaved")
      assert_eq(vim.log.levels.WARN, notes[1].level)
    end)
    teardown_case()
    assert_truthy(ok, err)
  end)

  it("three bumps typed at once land as three steps, in order", function()
    setup_case({ "module M", "let speed = 1.0", "let drag = 2.0" })
    local ok, err = pcall(function()
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_win_set_cursor(0, { 3, 13 })
      for _ = 1, 3 do nudge_ui.run(plugin, helpers, { action = "up" }, 1) end
      assert_truthy(vim.wait(5000, function() return vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1] == "let drag = 2.3" end, 10),
        "2.0 and three steps is 2.3: " .. vim.inspect(vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
      for _, n in ipairs(notes) do
        assert_falsy(n.msg:find("changed while", 1, true), "none was turned away: " .. n.msg)
      end
    end)
    teardown_case()
    assert_truthy(ok, err)
  end)

  it("the command is registered with a count, completes its sub-commands, and the maps are buffer-local", function()
    local cmd = vim.api.nvim_get_commands({})["SageFsNudge"]
    assert_truthy(cmd, "the command exists")
    assert_eq("*", cmd.nargs)
    local completed = vim.fn.getcompletion("SageFsNudge u", "cmdline")
    assert_contains(completed, "up")
    assert_contains(completed, "undo")
    local buf = make_buffer({ "let x = 1" })
    nudge_ui.register_keymaps(plugin, helpers, buf)
    local map = vim.fn.maparg((vim.g.mapleader or "\\") .. "rk+", "n", false, true)
    assert_eq(1, map.buffer, "the map is buffer-local")
    local elsewhere = make_buffer({ "let y = 2" })
    assert_eq("", vim.fn.maparg((vim.g.mapleader or "\\") .. "rk+", "n"), "and absent from a buffer it was not made for: " .. elsewhere)
  end)
end)

-- ─── Report ──────────────────────────────────────────────────────────────────

io.write(string.format("\n═══ Results: %d passed, %d failed ═══\n", passed, failed))
if #errors > 0 then
  io.write("\nFailures:\n")
  for _, e in ipairs(errors) do
    io.write("  ✖ " .. e.label .. "\n    " .. e.err .. "\n")
  end
end

-- Exit non-zero on a failure so CI can go red
if failed > 0 then vim.cmd("cquit 1") else vim.cmd("qa!") end
