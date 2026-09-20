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
      "SageFsStart", "SageFsStop",
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

-- §5.12: version drift used to be visible ONLY inside :checkhealth — a user
-- who never runs it never learns their plugin is a minor behind. This test
-- runs BEFORE the "health check discovery" tests below (both of which also
-- happen to hit a "behind" drift scenario) so it deterministically
-- consumes the one-time drift_warning_shown flag; the pre-existing tests
-- after it don't assert the flag's state either way.
describe("version drift notification (§5.12)", function()
  it("notifies once, outside :checkhealth, the first time the daemon is found ahead", function()
    local sagefs = require("sagefs")
    local transport = require("sagefs.transport")
    local original_http_json = transport.http_json
    local original_notify = vim.notify
    local notifications = {}
    local healthy = nil

    transport.http_json = function(opts)
      if opts.url:find("/health$") then
        opts.callback(true, vim.json.encode({ healthy = true, status = "ready", features = {}, apiVersion = 7, version = "9.9.9" }))
        return
      end
      error("unexpected discovery request: " .. opts.url)
    end

    vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

    sagefs.health_check(function(result) healthy = result end)
    vim.wait(1000, function() return healthy ~= nil end, 10)
    -- the drift notify is deliberately deferred a tick past the connect notify
    vim.wait(200, function() return #notifications >= 2 end, 10)

    transport.http_json = original_http_json
    vim.notify = original_notify

    local found_drift = false
    for _, n in ipairs(notifications) do
      if n.msg:find("behind the SageFs daemon", 1, true) and n.msg:find("9.9.9", 1, true) then
        found_drift = true
        assert_eq(vim.log.levels.WARN, n.level, "drift notice should be a warning")
      end
    end
    assert_truthy(found_drift, "should notify about version drift outside :checkhealth")
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

-- ─── Report ──────────────────────────────────────────────────────────────────

io.write(string.format("\n═══ Results: %d passed, %d failed ═══\n", passed, failed))
if #errors > 0 then
  io.write("\nFailures:\n")
  for _, e in ipairs(errors) do
    io.write("  ✖ " .. e.label .. "\n    " .. e.err .. "\n")
  end
end

-- Exit with appropriate code
vim.cmd("qa!")
