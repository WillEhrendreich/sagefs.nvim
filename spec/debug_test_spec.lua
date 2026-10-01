-- Tests: debugging a failing test through nvim-dap (sagefs.debug_test).
--
-- The daemon holds the test in its host and answers a pid (POST
-- /api/live-testing/debug); a debugger attaches to that pid; the plugin
-- releases it (POST /api/live-testing/debug/continue) and loops while it
-- answers still_running. The hold must never outlive the debugger, so most of
-- this file is about the lifecycle, driven through a fake dap and a fake HTTP
-- layer: no daemon, no Neovim, no netcoredbg.
require("spec.helper")

local dt = require("sagefs.debug_test")
local annotations = require("sagefs.annotations")
local testing = require("sagefs.testing")

before_each(function() dt._reset() end)

local function fixture(name)
  local src = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
  local f = assert(io.open(src .. "fixtures/wire/" .. name, "rb"))
  local text = f:read("*a")
  f:close()
  local ok, data = require("sagefs.util").json_decode(text)
  assert(ok, "fixture " .. name .. " did not decode")
  return data, text
end

-- ─── Fakes ───────────────────────────────────────────────────────────────────

--- A fake nvim-dap: just enough surface for listeners, run, terminate.
local function fake_dap(opts)
  opts = opts or {}
  local dap = {
    adapters = opts.adapters or {},
    listeners = { before = {}, after = {} },
    runs = {},
    terminated = 0,
    disconnected = {},
    run_throws = opts.run_throws,
  }
  function dap.run(config)
    if dap.run_throws then error(dap.run_throws) end
    table.insert(dap.runs, config)
    dap._session = { config = config }
  end
  function dap.session() return dap._session end
  function dap.terminate() dap.terminated = dap.terminated + 1 end
  function dap.disconnect(args) table.insert(dap.disconnected, args or {}) end
  --- Fire every listener registered for (when, event), like nvim-dap does.
  function dap.fire(when, event, session, body)
    local bucket = dap.listeners[when][event]
    if not bucket then return end
    local keys = {}
    for k in pairs(bucket) do table.insert(keys, k) end
    table.sort(keys)
    for _, k in ipairs(keys) do bucket[k](session or dap._session, body) end
  end
  function dap.listener_count()
    local n = 0
    for _, when in pairs(dap.listeners) do
      for _, bucket in pairs(when) do
        for _ in pairs(bucket) do n = n + 1 end
      end
    end
    return n
  end
  return dap
end

local function answer_json(t)
  return vim.json.encode(t)
end

local HELD = {
  status = "held", message = "Attach a .NET debugger to process 31337, then continue to release the test.",
  pid = 31337, ticket = "debug-31337-1", testId = "D39C4D7B318839A9",
  testName = "a negative integer yields None", symbols = "compiled", symbolsNote = "",
  access = "open", accessNote = "", holdMs = 120000, outcome = "", detail = "", durationMs = 0,
}

local function with(base, overrides)
  local out = {}
  for k, v in pairs(base) do out[k] = v end
  for k, v in pairs(overrides) do out[k] = v end
  return out
end

--- Build deps with a scripted HTTP layer. `script` maps a route ("debug" or
--- "continue") to a queue of replies { ok, body_table_or_raw }. A reply that is
--- the string "hang" is never delivered (the request stays in flight).
local function make_env(script, dap_opts)
  local env = {
    calls = {},
    notes = {},
    timers = {},
    exit_hooks = {},
    buffer_hooks = {},
    sync_releases = {},
    pending = {},
  }
  env.dap = dap_opts == false and nil or fake_dap(dap_opts)
  env.deps = {
    base_url = function() return "http://localhost:37749" end,
    session_id = function() return "57bbdfd8" end,
    dap = env.dap,
    find_adapter = function() return "/mason/bin/netcoredbg" end,
    notify = function(msg, level) table.insert(env.notes, { msg = msg, level = level }) end,
    http = function(opts)
      local route = opts.url:match("/debug/continue$") and "continue" or "debug"
      local body = opts.body
      table.insert(env.calls, { route = route, opts = opts, body = body })
      local queue = script[route] or {}
      local reply = table.remove(queue, 1)
      if reply == "hang" then
        table.insert(env.pending, opts)
        return
      end
      if reply then
        local ok, payload = reply[1], reply[2]
        opts.callback(ok, type(payload) == "table" and answer_json(payload) or payload)
      end
    end,
    defer = function(ms, fn)
      local timer = { ms = ms, fn = fn, cancelled = false }
      table.insert(env.timers, timer)
      return function() timer.cancelled = true end
    end,
    release_sync = function(url, body) table.insert(env.sync_releases, { url = url, body = body }) end,
    on_exit = function(fn)
      table.insert(env.exit_hooks, fn)
      return function() env.exit_hooks = {} end
    end,
    on_buffer_gone = function(bufnr, fn)
      table.insert(env.buffer_hooks, { bufnr = bufnr, fn = fn })
      return function() env.buffer_hooks = {} end
    end,
    bufnr = 7,
  }
  function env.continues()
    local n = 0
    for _, c in ipairs(env.calls) do if c.route == "continue" then n = n + 1 end end
    return n
  end
  function env.fire_timers(min_ms)
    for _, t in ipairs(env.timers) do
      if not t.cancelled and (not min_ms or t.ms >= min_ms) then
        t.cancelled = true
        t.fn()
      end
    end
  end
  function env.last_note() return env.notes[#env.notes] end
  function env.all_notes()
    local out = {}
    for _, n in ipairs(env.notes) do table.insert(out, n.msg) end
    return table.concat(out, "\n")
  end
  return env
end

-- ─── Pure: adapter discovery ─────────────────────────────────────────────────

describe("debug_test.find_netcoredbg", function()
  local function probe(present, exepath_hit)
    return {
      exepath = function(name) return exepath_hit or "" end,
      executable = function(path) return present[path] == true end,
      data_dir = "/home/u/.local/share/nvim",
      is_windows = false,
    }
  end

  it("prefers netcoredbg on PATH", function()
    local path, source = dt.find_netcoredbg(probe({}, "/usr/bin/netcoredbg"))
    assert.are.equal("/usr/bin/netcoredbg", path)
    assert.are.equal("PATH", source)
  end)

  it("falls back to the mason bin directory", function()
    local mason = "/home/u/.local/share/nvim/mason/bin/netcoredbg"
    local path, source = dt.find_netcoredbg(probe({ [mason] = true }))
    assert.are.equal(mason, path)
    assert.are.equal("mason", source)
  end)

  it("falls back to the mason package directory when the bin link is missing", function()
    local pkg = "/home/u/.local/share/nvim/mason/packages/netcoredbg/netcoredbg"
    local path, source = dt.find_netcoredbg(probe({ [pkg] = true }))
    assert.are.equal(pkg, path)
    assert.are.equal("mason", source)
  end)

  it("answers nil when nothing is installed, and never installs anything", function()
    assert.is_nil(dt.find_netcoredbg(probe({})))
  end)

  it("looks for the .exe on Windows", function()
    local p = probe({ ["C:/data/mason/bin/netcoredbg.exe"] = true })
    p.is_windows = true
    p.data_dir = "C:/data"
    local path = dt.find_netcoredbg(p)
    assert.are.equal("C:/data/mason/bin/netcoredbg.exe", path)
  end)
end)

-- ─── Pure: wire shapes ───────────────────────────────────────────────────────

describe("debug_test request bodies", function()
  it("asks by test id when the id is known", function()
    local body = dt.build_hold_body({ test_id = "D39C4D7B318839A9" }, "57bbdfd8")
    assert.are.same({ testId = "D39C4D7B318839A9", sessionId = "57bbdfd8" }, body)
  end)

  it("asks by name pattern when only a name is known", function()
    local body = dt.build_hold_body({ pattern = "adds" }, nil)
    assert.are.same({ pattern = "adds" }, body)
  end)

  it("a test id wins over a pattern", function()
    local body = dt.build_hold_body({ test_id = "X", pattern = "adds" }, nil)
    assert.are.same({ testId = "X" }, body)
  end)

  it("builds the continue body from the ticket", function()
    assert.are.same({ ticket = "debug-1-1", sessionId = "s" }, dt.build_continue_body("debug-1-1", "s"))
    assert.are.same({ ticket = "debug-1-1" }, dt.build_continue_body("debug-1-1", nil))
  end)
end)

describe("debug_test.parse_answer", function()
  it("reads the body whatever the HTTP status: a 409 is still an answer", function()
    local _, raw = fixture("debug_continue_released_without_debugger.json")
    local answer = dt.parse_answer(false, raw)
    assert.are.equal("released_without_debugger", answer.status)
    assert.is_truthy(answer.message:find("no debugger was attached", 1, true))
  end)

  it("reads the real held answer", function()
    local _, raw = fixture("debug_held.json")
    local answer = dt.parse_answer(true, raw)
    assert.are.equal("held", answer.status)
    assert.are.equal("debug-301375-1", answer.ticket)
    assert.are.equal(301375, answer.pid)
  end)

  it("turns a transport failure into a dead end that says what happened", function()
    local answer = dt.parse_answer(false, "timeout")
    assert.are.equal("transport_error", answer.status)
    assert.is_truthy(answer.message:find("timeout", 1, true))
  end)

  it("treats a body that is not JSON as a dead end, never a success", function()
    local answer = dt.parse_answer(true, "<html>oops</html>")
    assert.are.equal("transport_error", answer.status)
  end)

  it("treats a status it does not know as a dead end and shows the daemon's words", function()
    local answer = dt.parse_answer(true, answer_json({ status = "brand_new", message = "daemon says hi" }))
    assert.are.equal("brand_new", answer.status)
    assert.are.equal("refused", dt.classify_hold(answer))
    assert.are.equal("refused", dt.classify_continue(answer))
    assert.is_truthy(dt.format_final(answer):find("daemon says hi", 1, true))
  end)
end)

describe("debug_test classification", function()
  it("only held is a hold", function()
    assert.are.equal("held", dt.classify_hold({ status = "held" }))
    for _, s in ipairs({ "hold_already_open", "host_unavailable", "not_discovered", "no_test_matched",
      "ambiguous_test", "no_session", "no_worker", "worker_failed", "bad_request", "attached" }) do
      assert.are.equal("refused", dt.classify_hold({ status = s }), s)
    end
  end)

  it("still_running means ask again, attached means finished, the rest are dead ends", function()
    assert.are.equal("still_running", dt.classify_continue({ status = "still_running" }))
    assert.are.equal("finished", dt.classify_continue({ status = "attached" }))
    for _, s in ipairs({ "no_debugger_within", "released_without_debugger", "no_such_hold", "host_lost",
      "hold_already_open", "bad_request" }) do
      assert.are.equal("refused", dt.classify_continue({ status = s }), s)
    end
  end)

  it("shows the outcome and detail of a finished run", function()
    local text, level = dt.format_final({ status = "attached", outcome = "failed",
      detail = "The match cases were incomplete", durationMs = 12, testName = "t" })
    assert.is_truthy(text:find("failed", 1, true))
    assert.is_truthy(text:find("The match cases were incomplete", 1, true))
    assert.are.equal(vim.log.levels.WARN, level)
    local _, ok_level = dt.format_final({ status = "attached", outcome = "passed", detail = "" })
    assert.are.equal(vim.log.levels.INFO, ok_level)
  end)

  it("shows the daemon's message for a dead end at WARN", function()
    local text, level = dt.format_final({ status = "host_lost", message = "The test host ended." })
    assert.is_truthy(text:find("The test host ended.", 1, true))
    assert.are.equal(vim.log.levels.WARN, level)
  end)

  it("warns about eval symbols and blocked access, and says nothing for the good case", function()
    assert.are.same({}, dt.hold_warnings(HELD))
    local w = dt.hold_warnings(with(HELD, { symbols = "eval", symbolsNote = "no PDB here" }))
    assert.are.equal(1, #w)
    assert.is_truthy(w[1]:find("no PDB here", 1, true))
    local b = dt.hold_warnings(with(HELD, { access = "blocked", accessNote = "set kernel.yama.ptrace_scope" }))
    assert.are.equal(1, #b)
    assert.is_truthy(b[1]:find("ptrace_scope", 1, true))
    assert.are.equal(2, #dt.hold_warnings(with(HELD, { symbols = "eval", access = "blocked" })))
  end)

  it("builds the coreclr attach configuration", function()
    local cfg = dt.dap_config(HELD)
    assert.are.equal("coreclr", cfg.type)
    assert.are.equal("attach", cfg.request)
    assert.are.equal(31337, cfg.processId)
    assert.is_truthy(cfg.name:find("debug-31337-1", 1, true))
    assert.is_truthy(cfg.name:find("a negative integer yields None", 1, true))
  end)

  it("says exactly how to attach by hand", function()
    local text = dt.attach_instruction(HELD)
    assert.is_truthy(text:find("attach to process 31337", 1, true))
    assert.is_truthy(text:find("SageFsDebugRelease", 1, true))
  end)

  it("tells you how to install what is missing", function()
    assert.is_truthy(dt.install_hint("dap"):find("nvim-dap", 1, true))
    local adapter = dt.install_hint("adapter")
    assert.is_truthy(adapter:find("netcoredbg", 1, true))
    assert.is_truthy(adapter:find("MasonInstall", 1, true))
  end)
end)

-- A cheap contract guard, like the VS Code client has: a status the daemon
-- starts to send that this client does not read fails here.
describe("debug_test daemon contract guard", function()
  it("reads every status spelling the daemon source defines", function()
    local path = os.getenv("SAGEFS_REPO") and (os.getenv("SAGEFS_REPO") .. "/SageFs.Core/DebugTestRequest.fs")
      or "/home/will/Work/SageFs/SageFs.Core/DebugTestRequest.fs"
    local f = io.open(path, "rb")
    if not f then return pending("daemon source not present at " .. path) end
    local text = f:read("*a")
    f:close()
    local seen = 0
    for spelling in text:gmatch("DebugStatus%.[%w]+ %-> \"([a-z_]+)\"") do
      seen = seen + 1
      assert.is_true(dt.KNOWN_STATUSES[spelling] == true, "client does not know status " .. spelling)
    end
    assert.is_true(seen >= 16, "expected the sixteen statuses, saw " .. seen)
  end)
end)

-- ─── Pure: failing tests at a line ───────────────────────────────────────────

describe("debug_test.failing_tests_at", function()
  local file = "/tmp/lem/tour-live-testing-passing-04/w/DemoEnv.Tests/DemoEnvTests.fs"

  local function annotation_state()
    local data = fixture("file_annotations_demoenv_tests.json")
    return annotations.handle_file_annotations(annotations.new(), data)
  end

  it("finds the failing test the daemon marked with a DebugTest lens, on its line", function()
    local found = dt.failing_tests_at(testing.new(), annotation_state(), file, 8)
    assert.are.equal(1, #found)
    assert.are.equal("D39C4D7B318839A9", found[1].test_id)
    assert.are.equal("a negative integer yields None", found[1].name)
  end)

  it("finds nothing on a line where every test passes", function()
    assert.are.same({}, dt.failing_tests_at(testing.new(), annotation_state(), file, 32))
  end)

  it("with no line, lists every failing test in the file", function()
    local found = dt.failing_tests_at(testing.new(), annotation_state(), file, nil)
    assert.are.equal(1, #found)
  end)

  it("also reads failing tests straight from the live testing state, without duplicates", function()
    local state = testing.new()
    testing.update_test(state, {
      testId = "D39C4D7B318839A9", displayName = "a negative integer yields None",
      fullName = "x", status = "Failed",
      origin = { Case = "SourceMapped", Fields = { file, 8 } },
    })
    testing.update_test(state, {
      testId = "OTHER", displayName = "also bad", fullName = "y", status = "Failed",
      origin = { Case = "SourceMapped", Fields = { file, 8 } },
    })
    local found = dt.failing_tests_at(state, annotation_state(), file, 8)
    assert.are.equal(2, #found)
    local ids = { found[1].test_id, found[2].test_id }
    table.sort(ids)
    assert.are.same({ "D39C4D7B318839A9", "OTHER" }, ids)
  end)

  it("marks lines that carry a debuggable failure so the hint can be drawn", function()
    local marks = dt.hint_marks(testing.new(), annotation_state(), file)
    assert.are.equal(1, marks[8])
    assert.is_nil(marks[32])
  end)
end)

-- ─── The lifecycle ───────────────────────────────────────────────────────────

describe("debug_test.start, adapter and dap checks come before any hold", function()
  it("does not hold a test when no adapter can be found, and says what to install", function()
    local env = make_env({})
    env.deps.find_adapter = function() return nil end
    dt.start(env.deps, { test_id = "X" })
    assert.are.equal(0, #env.calls)
    assert.is_truthy(env.all_notes():find("MasonInstall netcoredbg", 1, true))
  end)

  it("uses an adapter the user already configured without touching it", function()
    local env = make_env({ debug = { { true, HELD } } }, { adapters = { coreclr = { type = "executable", command = "mine" } } })
    env.deps.find_adapter = function() return nil end
    dt.start(env.deps, { test_id = "X" })
    assert.are.equal(1, #env.calls)
    assert.are.equal("mine", env.dap.adapters.coreclr.command)
  end)

  it("registers a netcoredbg adapter it discovered, only when none is configured", function()
    local env = make_env({ debug = { { true, HELD } } })
    dt.start(env.deps, { test_id = "X" })
    assert.are.equal("/mason/bin/netcoredbg", env.dap.adapters.coreclr.command)
    assert.are.same({ "--interpreter=vscode" }, env.dap.adapters.coreclr.args)
  end)

  it("without nvim-dap, still holds, prints the pid and the attach instruction, and starts no debugger", function()
    local env = make_env({ debug = { { true, HELD } } }, false)
    local run = dt.start(env.deps, { test_id = "X" })
    assert.are.equal(1, #env.calls)
    local notes = env.all_notes()
    assert.is_truthy(notes:find("31337", 1, true))
    assert.is_truthy(notes:find("attach to process 31337", 1, true))
    assert.is_truthy(notes:find("nvim-dap", 1, true))
    assert.are.equal("held", run.state())
    assert.are.equal(0, env.continues())
  end)

  it("the manual release in that mode continues the ticket and reports the result", function()
    local env = make_env({
      debug = { { true, HELD } },
      continue = { { true, { status = "attached", outcome = "failed", detail = "boom" } } },
    }, false)
    local run = dt.start(env.deps, { test_id = "X" })
    run.release()
    assert.are.equal(1, env.continues())
    assert.are.equal("debug-31337-1", env.calls[2].body.ticket)
    assert.are.equal("finished", run.state())
    assert.is_truthy(env.all_notes():find("boom", 1, true))
  end)
end)

describe("debug_test.start, refusals", function()
  for _, status in ipairs({ "hold_already_open", "no_test_matched", "ambiguous_test", "not_discovered",
    "host_unavailable", "no_session", "no_worker", "worker_failed", "bad_request" }) do
    it("shows the daemon's words for " .. status .. " and starts no debugger", function()
      local env = make_env({ debug = { { false, { status = status, message = "words for " .. status } } } })
      local run = dt.start(env.deps, { test_id = "X" })
      assert.are.equal(0, #env.dap.runs)
      assert.are.equal(0, env.continues())
      assert.is_truthy(env.all_notes():find("words for " .. status, 1, true))
      assert.are.equal("finished", run.state())
      assert.are.equal(0, env.dap.listener_count())
    end)
  end

  it("a transport failure on the hold is reported and nothing is attached", function()
    local env = make_env({ debug = { { false, "timeout" } } })
    dt.start(env.deps, { test_id = "X" })
    assert.are.equal(0, #env.dap.runs)
    assert.is_truthy(env.all_notes():find("timeout", 1, true))
  end)
end)

describe("debug_test.start, the happy path", function()
  local env, run

  before_each(function()
    env = make_env({
      debug = { { true, HELD } },
      continue = {
        { true, { status = "still_running" } },
        { true, { status = "still_running" } },
        { true, { status = "attached", outcome = "failed", detail = "The match cases were incomplete", durationMs = 9 } },
      },
    })
    run = dt.start(env.deps, { test_id = "D39C4D7B318839A9" })
  end)

  it("sends the hold request to the debug route with the test and the session", function()
    local call = env.calls[1]
    assert.are.equal("POST", call.opts.method)
    assert.are.equal("http://localhost:37749/api/live-testing/debug", call.opts.url)
    assert.are.same({ testId = "D39C4D7B318839A9", sessionId = "57bbdfd8" }, call.body)
  end)

  it("attaches coreclr to the pid it was handed", function()
    assert.are.equal(1, #env.dap.runs)
    assert.are.equal(31337, env.dap.runs[1].processId)
    assert.are.equal("attach", env.dap.runs[1].request)
  end)

  it("does not release the test until the attach has completed", function()
    assert.are.equal(0, env.continues())
    env.dap.fire("after", "event_initialized")
    assert.are.equal(0, env.continues(), "initialized alone is not enough: breakpoints are not set yet")
    env.dap.fire("after", "configurationDone")
    assert.are.equal(1, env.continues())
  end)

  it("releases after the grace period if the adapter never answers configurationDone", function()
    env.dap.fire("after", "event_initialized")
    assert.are.equal(0, env.continues())
    env.fire_timers()
    assert.are.equal(1, env.continues())
  end)

  it("loops on still_running, then detaches and shows the result", function()
    env.dap.fire("after", "event_initialized")
    env.dap.fire("after", "configurationDone")
    assert.are.equal(3, env.continues())
    assert.are.equal("finished", run.state())
    assert.are.equal(1, #env.dap.disconnected)
    assert.is_false(env.dap.disconnected[1].terminateDebuggee, "detaching must leave the process running")
    assert.is_truthy(env.all_notes():find("The match cases were incomplete", 1, true))
    assert.are.equal(0, env.dap.listener_count(), "listeners are removed when the run is over")
  end)

  it("gives the continue request a timeout longer than the daemon's 20 second wait", function()
    env.dap.fire("after", "event_initialized")
    env.dap.fire("after", "configurationDone")
    for _, c in ipairs(env.calls) do
      if c.route == "continue" then assert.is_true(c.opts.timeout >= 60) end
    end
  end)

  it("sends the same ticket every time", function()
    env.dap.fire("after", "event_initialized")
    env.dap.fire("after", "configurationDone")
    for _, c in ipairs(env.calls) do
      if c.route == "continue" then assert.are.equal("debug-31337-1", c.body.ticket) end
    end
  end)

  it("ignores events from some other debug session", function()
    env.dap.fire("after", "event_initialized", { config = { name = "someone else" } })
    env.dap.fire("after", "configurationDone", { config = { name = "someone else" } })
    assert.are.equal(0, env.continues())
  end)
end)

describe("debug_test.start, the hold is always released", function()
  local function attach_env(extra)
    local script = { debug = { { true, HELD } }, continue = extra or { { true, { status = "released_without_debugger", message = "not attached" } } } }
    local env = make_env(script)
    local run = dt.start(env.deps, { test_id = "X" })
    return env, run
  end

  it("releases once when the debug session terminates before it ever attached", function()
    local env, run = attach_env()
    env.dap.fire("before", "event_terminated")
    assert.are.equal(1, env.continues())
    assert.are.equal("finished", run.state())
    env.dap.fire("before", "event_exited")
    assert.are.equal(1, env.continues(), "a second end event must not release again")
  end)

  it("releases once when the user disconnects before it attached", function()
    local env = attach_env()
    env.dap.fire("after", "disconnect")
    assert.are.equal(1, env.continues())
  end)

  it("releases when dap.run throws, and says why", function()
    local env = make_env({
      debug = { { true, HELD } },
      continue = { { true, { status = "released_without_debugger", message = "not attached" } } },
    }, { run_throws = "adapter exploded" })
    dt.start(env.deps, { test_id = "X" })
    assert.are.equal(1, env.continues())
    assert.is_truthy(env.all_notes():find("adapter exploded", 1, true))
  end)

  it("releases when the debugger never initializes inside the hold window", function()
    local env, run = attach_env()
    assert.are.equal(0, env.continues())
    local watchdog
    for _, t in ipairs(env.timers) do
      if t.ms >= 100000 then watchdog = t end
    end
    assert.is_truthy(watchdog, "a watchdog is armed for the hold window")
    watchdog.fn()
    assert.are.equal(1, env.continues())
    assert.are.equal("finished", run.state())
  end)

  it("stops asking when the debugger goes away while the test is still running", function()
    local env, run = attach_env({
      { true, { status = "still_running" } },
      { true, { status = "still_running" } },
    })
    env.dap.fire("after", "event_initialized")
    env.dap.fire("after", "configurationDone")
    -- the second still_running reply was delivered synchronously by the fake, so
    -- we are two continues in; end the session and make sure there is no third.
    local before = env.continues()
    env.dap.fire("before", "event_terminated")
    assert.are.equal(before, env.continues())
    assert.are.equal("finished", run.state())
  end)

  it("does not poll again after a reply that arrives once the debugger is gone", function()
    local env = make_env({ debug = { { true, HELD } }, continue = { "hang" } })
    local run = dt.start(env.deps, { test_id = "X" })
    env.dap.fire("after", "event_initialized")
    env.dap.fire("after", "configurationDone")
    assert.are.equal(1, env.continues())
    env.dap.fire("before", "event_terminated")
    assert.are.equal(1, env.continues(), "already released: nothing more to send")
    -- the in-flight request now returns still_running
    env.pending[1].callback(true, answer_json({ status = "still_running" }))
    assert.are.equal(1, env.continues(), "must not poll after the session ended")
    assert.are.equal("finished", run.state())
  end)

  it("releases synchronously when Neovim exits with the test still held", function()
    local env = attach_env()
    assert.are.equal(1, #env.exit_hooks)
    env.exit_hooks[1]()
    assert.are.equal(1, #env.sync_releases)
    assert.is_truthy(env.sync_releases[1].url:find("/api/live-testing/debug/continue", 1, true))
    assert.is_truthy(env.sync_releases[1].body:find("debug-31337-1", 1, true))
  end)

  it("does not release twice when Neovim exits after a normal finish", function()
    local env, run = attach_env({ { true, { status = "attached", outcome = "passed", detail = "" } } })
    env.dap.fire("after", "event_initialized")
    env.dap.fire("after", "configurationDone")
    assert.are.equal("finished", run.state())
    for _, hook in ipairs(env.exit_hooks) do hook() end
    assert.are.equal(0, #env.sync_releases)
  end)

  it("does not release synchronously when the release request is already in flight", function()
    local env = make_env({ debug = { { true, HELD } }, continue = { "hang" } })
    dt.start(env.deps, { test_id = "X" })
    env.dap.fire("after", "event_initialized")
    env.dap.fire("after", "configurationDone")
    for _, hook in ipairs(env.exit_hooks) do hook() end
    assert.are.equal(0, #env.sync_releases)
  end)

  it("releases when the buffer the run started from is wiped", function()
    local env, run = attach_env()
    assert.are.equal(7, env.buffer_hooks[1].bufnr)
    env.buffer_hooks[1].fn()
    assert.are.equal(1, env.continues())
    assert.are.equal("finished", run.state())
  end)

  it("abort() is idempotent", function()
    local env, run = attach_env()
    run.abort("test")
    run.abort("test")
    assert.are.equal(1, env.continues())
  end)

  it("unhooks exit and buffer watchers once it is over", function()
    local env, run = attach_env()
    run.abort("test")
    assert.are.equal(0, #env.exit_hooks)
    assert.are.equal(0, #env.buffer_hooks)
  end)
end)

describe("debug_test.start, one debug run at a time", function()
  it("a second start while one is open is refused locally and sends nothing", function()
    local env = make_env({ debug = { { true, HELD } } })
    dt.start(env.deps, { test_id = "X" })
    local calls = #env.calls
    local second = dt.start(env.deps, { test_id = "Y" })
    assert.are.equal(calls, #env.calls)
    assert.is_truthy(env.all_notes():find("already", 1, true))
    assert.is_truthy(second)
  end)

  it("after a run ends, a new one can start", function()
    local env = make_env({
      debug = { { true, HELD }, { true, HELD } },
      continue = { { true, { status = "released_without_debugger", message = "m" } } },
    })
    local run = dt.start(env.deps, { test_id = "X" })
    run.abort("done")
    dt.start(env.deps, { test_id = "Y" })
    local n = 0
    for _, c in ipairs(env.calls) do if c.route == "debug" then n = n + 1 end end
    assert.are.equal(2, n)
  end)
end)
