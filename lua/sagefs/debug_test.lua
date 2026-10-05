-- sagefs/debug_test.lua — Debug a failing test through nvim-dap
--
-- The daemon runs a test in the process that loaded your code, so debugging it
-- means attaching a .NET debugger to that process. Two routes on the daemon's
-- MCP port do the hand-off (docs/LIVE_TESTING_GUIDE.md, "Debugging a failing test"):
--
--   POST /api/live-testing/debug           hold the test, answer a pid and a ticket
--   POST /api/live-testing/debug/continue  release it, wait up to 20 s for the result
--
-- A hold that outlives the debugger is a leaked test run, so the lifecycle is
-- the point of this module: it releases the hold when the debug session ends,
-- when dap.run fails, when the hold window runs out, when the buffer it started
-- from goes away and when Neovim exits. Everything effectful arrives through a
-- `deps` table (HTTP, dap, timers, exit hooks), so the lifecycle runs under
-- busted against a fake dap and a fake HTTP layer. nvim-dap is optional and is
-- only ever soft-required.

local util = require("sagefs.util")

local M = {}

local LEVELS = (vim and vim.log and vim.log.levels) or { INFO = 1, WARN = 2, ERROR = 3 }

--- Every status the daemon can answer on either route (DebugTestRequest.fs).
M.KNOWN_STATUSES = {
  held = true,
  still_running = true,
  attached = true,
  no_debugger_within = true,
  released_without_debugger = true,
  no_such_hold = true,
  host_lost = true,
  hold_already_open = true,
  host_unavailable = true,
  not_discovered = true,
  no_test_matched = true,
  ambiguous_test = true,
  no_worker = true,
  no_session = true,
  bad_request = true,
  worker_failed = true,
}

M.HOLD_PATH = "/api/live-testing/debug"
M.CONTINUE_PATH = "/api/live-testing/debug/continue"

-- The daemon waits 20 s per continue call; give the HTTP client well over that.
local CONTINUE_TIMEOUT_S = 75
local HOLD_TIMEOUT_S = 30
-- How long to wait for configurationDone after the adapter says it initialized
-- before releasing anyway (an adapter that never sends it must not strand the hold).
local CONFIGURED_GRACE_MS = 1500
-- How long dap.run gets to put a debug session of ours on the board. An adapter
-- that cannot start (missing binary) never creates one and fires no event, so
-- without this check the hold would sit until the two minute backstop.
M.SESSION_START_GRACE_MS = 5000
-- A continue that fails to reach the daemon is tried once more after this pause.
M.CONTINUE_RETRY_MS = 1000
-- At quit, a hold request still in flight gets this long to be answered, so the
-- answer can be released before Neovim goes. A dead daemon costs a quit this much.
M.EXIT_WAIT_MS = 2000

-- ─── Pure: adapter discovery ─────────────────────────────────────────────────

--- Find a netcoredbg binary. Looks on PATH, then in the usual mason locations.
--- Never installs anything.
---@param env { exepath: fun(name: string): string, executable: fun(path: string): boolean, data_dir: string, is_windows: boolean }
---@return string|nil path, string|nil source "PATH"|"mason"
function M.find_netcoredbg(env)
  local on_path = env.exepath and env.exepath("netcoredbg") or ""
  if on_path ~= nil and on_path ~= "" then
    return on_path, "PATH"
  end
  local name = env.is_windows and "netcoredbg.exe" or "netcoredbg"
  local mason = (env.data_dir or "") .. "/mason"
  local candidates = {
    mason .. "/bin/" .. name,
    mason .. "/packages/netcoredbg/" .. name,
    mason .. "/packages/netcoredbg/netcoredbg/" .. name,
  }
  for _, path in ipairs(candidates) do
    if env.executable(path) then
      return path, "mason"
    end
  end
  return nil, nil
end

--- The real probe, backed by Neovim.
function M.default_probe()
  return {
    exepath = vim.fn.exepath,
    executable = function(path) return vim.fn.executable(path) == 1 end,
    data_dir = vim.fn.stdpath("data"),
    is_windows = vim.fn.has("win32") == 1,
  }
end

function M.install_hint(kind)
  if kind == "dap" then
    return "nvim-dap is not installed. Add mfussenegger/nvim-dap to your plugin manager "
      .. "(with netcoredbg for the coreclr adapter) and :SageFsDebugTest will drive it for you."
  end
  return "netcoredbg was not found on PATH or under mason. Install it with :MasonInstall netcoredbg "
    .. "(or the release from https://github.com/Samsung/netcoredbg/releases, put on PATH), "
    .. "then run :SageFsDebugTest again. Nothing was held."
end

-- ─── Pure: what :checkhealth says ────────────────────────────────────────────

--- The lines :checkhealth sagefs shows about debugging a failing test. Everything
--- here is optional, so a missing piece is "info" or "warn" with the fix, never
--- an error: the plugin and every other feature work without it.
---@param env { has_dap: boolean, adapters: table|nil, netcoredbg: string|nil, netcoredbg_source: string|nil, ptrace_scope: number|nil, is_linux: boolean|nil }
---@return { level: string, message: string, advice: string[]|nil }[]
function M.health_items(env)
  local items = {}
  if not env.has_dap then
    table.insert(items, {
      level = "info",
      message = "nvim-dap not installed (optional, :SageFsDebugTest attaches through it)",
      advice = {
        "Install mfussenegger/nvim-dap with your plugin manager, and netcoredbg for the coreclr adapter",
        "Without it :SageFsDebugTest still holds the test and prints the pid: attach to process N with any coreclr debugger",
      },
    })
  else
    table.insert(items, { level = "ok", message = "nvim-dap available (:SageFsDebugTest attaches the debugger for you)" })
    if env.adapters and env.adapters.coreclr then
      table.insert(items, { level = "ok", message = "dap coreclr adapter configured (yours is used as it is)" })
    elseif env.netcoredbg then
      table.insert(items, {
        level = "ok",
        message = string.format("netcoredbg found at %s (%s): the coreclr adapter is set up on first use", env.netcoredbg, env.netcoredbg_source or "PATH"),
      })
    else
      table.insert(items, {
        level = "warn",
        message = "netcoredbg not found on PATH or under mason, so :SageFsDebugTest cannot attach",
        advice = {
          "Install it with :MasonInstall netcoredbg",
          "Or take the release from https://github.com/Samsung/netcoredbg/releases and put it on PATH",
        },
      })
    end
  end
  if env.is_linux and env.ptrace_scope ~= nil then
    if env.ptrace_scope >= 2 then
      table.insert(items, {
        level = "warn",
        message = string.format("kernel.yama.ptrace_scope = %d: the OS will refuse a debugger attaching to the test host", env.ptrace_scope),
        advice = {
          "Set it to 1 (or 0): sudo sysctl kernel.yama.ptrace_scope=1",
          "At 1 the test host opens the door for the length of the hold, so 1 is enough",
        },
      })
    else
      table.insert(items, {
        level = "ok",
        message = string.format("kernel.yama.ptrace_scope = %d (a debugger can attach to the test host)", env.ptrace_scope),
      })
    end
  end
  return items
end

--- The real inputs to health_items, read from Neovim and /proc.
function M.health_env()
  local ok_dap, dap = pcall(require, "dap")
  local path, source = M.find_netcoredbg(M.default_probe())
  local scope
  local f = io.open("/proc/sys/kernel/yama/ptrace_scope", "r")
  if f then
    scope = tonumber(f:read("*l"))
    f:close()
  end
  return {
    has_dap = ok_dap,
    adapters = ok_dap and dap.adapters or nil,
    netcoredbg = path,
    netcoredbg_source = source,
    ptrace_scope = scope,
    is_linux = vim.fn.has("linux") == 1,
  }
end

-- ─── Pure: wire shapes ───────────────────────────────────────────────────────

--- Body for the hold route. A test id wins over a name pattern.
---@param target { test_id: string|nil, pattern: string|nil }
---@param session_id string|nil
function M.build_hold_body(target, session_id)
  local body = {}
  if target.test_id and target.test_id ~= "" then
    body.testId = target.test_id
  elseif target.pattern and target.pattern ~= "" then
    body.pattern = target.pattern
  end
  if session_id and session_id ~= "" then body.sessionId = session_id end
  return body
end

function M.build_continue_body(ticket, session_id)
  local body = { ticket = ticket }
  if session_id and session_id ~= "" then body.sessionId = session_id end
  return body
end

--- Read a route's answer. The body is read whatever the HTTP status is: the 4xx
--- and 5xx answers carry the same JSON. A reply that is not a debug answer at
--- all becomes a `transport_error` dead end that says what came back.
---@param ok boolean transport-level success (2xx)
---@param raw string|nil
---@return table answer always has `status` (string) and `message` (string)
function M.parse_answer(ok, raw)
  local decoded, data = util.json_decode(raw)
  if decoded and type(data) == "table" and type(data.status) == "string" then
    data.message = data.message or ""
    return data
  end
  local text = (type(raw) == "string" and raw ~= "") and raw or "no response"
  if #text > 200 then text = text:sub(1, 200) .. "…" end
  if ok then
    return { status = "transport_error", message = "the daemon answered something that is not a debug answer: " .. text }
  end
  return { status = "transport_error", message = "the request to the daemon failed: " .. text }
end

function M.classify_hold(answer)
  return answer.status == "held" and "held" or "refused"
end

function M.classify_continue(answer)
  if answer.status == "still_running" then return "still_running" end
  if answer.status == "attached" then return "finished" end
  return "refused"
end

--- Text and log level for a final answer. A status it does not know shows the
--- daemon's own words and counts as a dead end, never a success.
---@param answer table
---@param test_name string|nil
---@return string text, number level
function M.format_final(answer, test_name)
  local name = answer.testName
  if not name or name == "" then name = test_name end
  local label = (name and name ~= "") and (" " .. name) or ""
  if answer.status == "attached" then
    local outcome = answer.outcome ~= "" and answer.outcome or "no_result"
    local text = string.format("SageFs debug:%s %s", label, (outcome:gsub("_", " ")))
    if answer.durationMs and answer.durationMs > 0 then
      text = text .. string.format(" (%d ms)", answer.durationMs)
    end
    if answer.detail and answer.detail ~= "" then
      text = text .. ": " .. answer.detail
    end
    local level = (outcome == "passed" or outcome == "skipped") and LEVELS.INFO or LEVELS.WARN
    return text, level
  end
  local message = answer.message
  if not message or message == "" then message = "the daemon answered '" .. tostring(answer.status) .. "'" end
  return "SageFs debug: " .. message, LEVELS.WARN
end

--- Warnings to show when a test is held: eval symbols and blocked ptrace.
function M.hold_warnings(held)
  local out = {}
  if held.symbols == "eval" then
    local note = (held.symbolsNote and held.symbolsNote ~= "") and held.symbolsNote
      or "this test was evaluated in the session and has no PDB, so breakpoints in it will not bind"
    table.insert(out, "SageFs debug: " .. note)
  end
  if held.access == "blocked" then
    local note = (held.accessNote and held.accessNote ~= "") and held.accessNote
      or "the OS may refuse the attach (Linux kernel.yama.ptrace_scope)"
    table.insert(out, "SageFs debug: " .. note)
  end
  return out
end

--- The nvim-dap configuration that attaches coreclr to the held host.
function M.dap_config(held)
  return {
    type = "coreclr",
    request = "attach",
    name = string.format("SageFs test: %s (%s)", held.testName or "?", held.ticket or "?"),
    processId = held.pid,
  }
end

--- What to do by hand when nvim-dap is not there to do it.
function M.attach_instruction(held)
  local secs = math.floor((held.holdMs or 120000) / 1000)
  return string.format(
    "SageFs holds \"%s\" in process %d. To debug it, attach a .NET debugger (coreclr) to that process: "
      .. "attach to process %d. Then run :SageFsDebugRelease to let the test run under it. "
      .. "The hold is dropped after %d seconds, or when Neovim exits.",
    held.testName or "?", held.pid or 0, held.pid or 0, secs)
end

-- ─── Pure: failing tests at a line ───────────────────────────────────────────

local function case_of(v)
  if type(v) == "table" then return v.Case or v.case end
  return v
end

local same_file = util.paths_match

--- Failing tests in `file` (optionally only those on `line`), from the daemon's
--- file annotations (a DebugTest CodeLens, or a Failed test annotation) and from
--- the live testing state. Deduplicated by test id, ordered by line then name.
---@return table[] { test_id, name, line }
function M.failing_tests_at(testing_state, annotations_state, file, line)
  local found, seen = {}, {}

  local function add(id, name, at)
    if not id or seen[id] then return end
    if line and at ~= line then return end
    seen[id] = true
    table.insert(found, { test_id = id, name = name or id, line = at })
  end

  local ann = annotations_state and require("sagefs.annotations").get_file(annotations_state, file) or nil
  if ann then
    local names = {}
    local test_anns = ann.TestAnnotations or ann.testAnnotations or {}
    for _, ta in ipairs(test_anns) do
      names[ta.TestId or ta.testId] = ta.DisplayName or ta.displayName
    end
    for _, ta in ipairs(test_anns) do
      if case_of(ta.Status or ta.status) == "Failed" then
        add(ta.TestId or ta.testId, ta.DisplayName or ta.displayName, ta.Line or ta.line)
      end
    end
    for _, lens in ipairs(ann.CodeLenses or ann.codeLenses or {}) do
      if case_of(lens.Command or lens.command) == "DebugTest" then
        local id = lens.TestId or lens.testId
        local label = (lens.Label or lens.label or ""):gsub("^%S+%s+", ""):gsub(":.*$", ""):gsub("%s*%(%d+ms%)$", "")
        add(id, names[id] or label, lens.Line or lens.line)
      end
    end
  end

  if testing_state and testing_state.tests then
    for id, t in pairs(testing_state.tests) do
      if t.status == "Failed" and t.line and same_file(t.file, file) then
        add(id, t.displayName, t.line)
      end
    end
  end

  table.sort(found, function(a, b)
    if a.line ~= b.line then return (a.line or 0) < (b.line or 0) end
    return tostring(a.name) < tostring(b.name)
  end)
  return found
end

--- Lines of `file` that carry at least one debuggable failure: line → count.
function M.hint_marks(testing_state, annotations_state, file)
  local marks = {}
  for _, t in ipairs(M.failing_tests_at(testing_state, annotations_state, file, nil)) do
    if t.line then marks[t.line] = (marks[t.line] or 0) + 1 end
  end
  return marks
end

-- ─── The lifecycle ───────────────────────────────────────────────────────────

local active = nil -- the open run; the host holds one test at a time

--- Forget the open run (tests only).
function M._reset()
  active = nil
end

--- The run that is open, if any.
function M.current()
  return active
end

local function remove_listeners(dap, key)
  if not dap or not dap.listeners then return end
  for _, when in pairs(dap.listeners) do
    for _, bucket in pairs(when) do
      if type(bucket) == "table" then bucket[key] = nil end
    end
  end
  -- on_session is flat (key -> function), unlike the before/after event buckets
  if dap.listeners.on_session then dap.listeners.on_session[key] = nil end
end

local function add_listener(dap, when, event, key, fn)
  local by_event = dap.listeners[when]
  local bucket = by_event[event]
  if not bucket then
    bucket = {}
    by_event[event] = bucket
  end
  bucket[key] = fn
end

local function new_run(deps)
  local run = {}
  local state = "starting" -- starting | held | released | finished
  local held = nil
  local config = nil
  local key = nil
  local release_sent = false
  local debug_ended = false
  local abort_when_held = nil
  local exit_pending = false -- Neovim started to quit while the hold request was in flight
  local cancels = {}
  local unhooks = {}

  local function notify(msg, level)
    if deps.notify then deps.notify(msg, level or LEVELS.INFO) end
  end

  local function mine(session)
    return session and session.config and config and session.config.name == config.name
  end

  local function cleanup()
    for _, cancel in ipairs(cancels) do pcall(cancel) end
    cancels = {}
    for _, unhook in ipairs(unhooks) do pcall(unhook) end
    unhooks = {}
    if key then remove_listeners(deps.dap, key) end
  end

  local function finish()
    if state == "finished" then return end
    state = "finished"
    cleanup()
    if active == run then active = nil end
  end

  --- Stop our debug session without killing the process we attached to.
  local function detach()
    local dap = deps.dap
    if not dap or debug_ended then return end
    local session = dap.session and dap.session() or nil
    if not mine(session) then return end
    debug_ended = true
    if dap.disconnect then
      pcall(dap.disconnect, { terminateDebuggee = false })
    elseif dap.terminate then
      pcall(dap.terminate)
    end
  end

  local function ask_continue(callback)
    deps.http({
      method = "POST",
      url = deps.base_url() .. M.CONTINUE_PATH,
      body = M.build_continue_body(held.ticket, deps.session_id and deps.session_id() or nil),
      timeout = CONTINUE_TIMEOUT_S,
      callback = callback,
    })
  end

  local retried = false

  local function poll()
    ask_continue(function(ok, raw)
      if state == "finished" then return end
      local answer = M.parse_answer(ok, raw)
      if answer.status == "transport_error" and not retried then
        retried = true
        table.insert(cancels, deps.defer(M.CONTINUE_RETRY_MS, poll))
        return
      end
      retried = false
      local kind = M.classify_continue(answer)
      if kind == "still_running" then
        if debug_ended then
          notify("SageFs debug: the debugger went away while the test was still running; it finishes on its own.", LEVELS.WARN)
          finish()
        else
          poll()
        end
        return
      end
      local text, level = M.format_final(answer, held and held.testName)
      if answer.status == "transport_error" then
        text = text .. string.format(" The test may stay held on the daemon for up to %d seconds.",
          math.floor(((held and held.holdMs) or 120000) / 1000))
      end
      notify(text, level)
      detach()
      finish()
    end)
  end

  --- Release the hold (once). The only way to free the host's one slot.
  local function release()
    if state == "finished" or release_sent or not held then return end
    release_sent = true
    state = "released"
    poll()
  end

  local function on_session_end()
    if state == "finished" then return end
    if key then remove_listeners(deps.dap, key) end
    debug_ended = true
    -- nvim-dap closes its sessions on ExitPre, just before VimLeavePre, and an
    -- asynchronous release started there is cut off when Neovim exits. Wait one
    -- tick: a quit takes the synchronous route (on_exit) first. No-op when the
    -- hold was released already.
    table.insert(cancels, deps.defer(0, release))
  end

  local function on_exit()
    if state == "finished" or release_sent then return end
    if not held then
      -- The hold request is still in flight: there is no ticket to release yet.
      -- A late "held" answer is released the moment it arrives (see on_held), so
      -- give the request a moment to come back before Neovim goes.
      exit_pending = true
      if deps.wait then
        deps.wait(M.EXIT_WAIT_MS, function() return held ~= nil or state == "finished" end)
      end
      return
    end
    release_sent = true
    local body = vim.json.encode(M.build_continue_body(held.ticket, deps.session_id and deps.session_id() or nil))
    if deps.release_sync then pcall(deps.release_sync, deps.base_url() .. M.CONTINUE_PATH, body) end
    finish()
  end

  local function arm_dap(dap)
    config = M.dap_config(held)
    key = "sagefs_debug_" .. tostring(held.ticket)
    local grace_cancel = nil

    add_listener(dap, "after", "event_initialized", key, function(session)
      if not mine(session) or release_sent then return end
      if grace_cancel then pcall(grace_cancel) end
      grace_cancel = deps.defer(CONFIGURED_GRACE_MS, release)
      table.insert(cancels, grace_cancel)
    end)
    add_listener(dap, "after", "configurationDone", key, function(session)
      if not mine(session) then return end
      if grace_cancel then pcall(grace_cancel); grace_cancel = nil end
      release()
    end)
    for _, spec in ipairs({
      { "before", "event_terminated" }, { "before", "event_exited" },
      { "before", "disconnect" }, { "after", "disconnect" },
    }) do
      add_listener(dap, spec[1], spec[2], key, function(session)
        if mine(session) then on_session_end() end
      end)
    end

    -- Our own session closing without a terminate event: the adapter died, or
    -- the user called dap.close() before it answered initialize.
    if dap.listeners.on_session then
      dap.listeners.on_session[key] = function(old_session)
        if old_session and old_session.closed and mine(old_session) then on_session_end() end
      end
    end

    local ok, err = pcall(dap.run, config)
    if not ok then
      notify("SageFs debug: could not start the debugger: " .. tostring(err), LEVELS.ERROR)
      debug_ended = true
      release()
      return
    end

    local function have_session()
      if mine(dap.session and dap.session() or nil) then return true end
      if dap.sessions then
        for _, other in pairs(dap.sessions()) do
          if mine(other) then return true end
        end
      end
      return false
    end
    table.insert(cancels, deps.defer(M.SESSION_START_GRACE_MS, function()
      if state == "finished" or release_sent or debug_ended or have_session() then return end
      notify("SageFs debug: the debugger did not start (see :DapShowLog); releasing the test.", LEVELS.WARN)
      debug_ended = true
      release()
    end))
  end

  local function on_held(answer)
    held = answer
    state = "held"
    -- First of all: if the debugger never shows up, free the hold before the
    -- host drops it. Nothing below may keep this from being armed.
    table.insert(cancels, deps.defer(held.holdMs or 120000, function() release() end))

    if exit_pending then
      on_exit() -- Neovim is on its way out: release through the synchronous route
      return
    end
    if abort_when_held then
      release()
      return
    end
    for _, warning in ipairs(M.hold_warnings(held)) do
      notify(warning, LEVELS.WARN)
    end
    if deps.dap then
      arm_dap(deps.dap)
    else
      notify(M.attach_instruction(held), LEVELS.INFO)
      notify(M.install_hint("dap"), LEVELS.INFO)
    end
  end

  function run.state() return state end
  function run.held() return held end

  --- Release the held test now (manual mode, or an explicit stop).
  function run.release() release() end

  --- Stop everything: detach the debugger, release the hold, clean up.
  function run.abort(reason)
    if state == "finished" then return end
    if not held then
      abort_when_held = reason or true
      return
    end
    if key then remove_listeners(deps.dap, key) end
    detach()
    release()
  end

  --- Watch for the ways a hold can be orphaned. Armed before the hold request
  --- goes out, so a quit or a wipe while it is in flight is still seen. A hook
  --- that cannot be registered is reported and never stops the run: the hold
  --- window watchdog is the backstop.
  local function watch(what, hook, ...)
    local ok, unhook = pcall(hook, ...)
    if not ok then
      notify("SageFs debug: could not watch for " .. what .. " (" .. tostring(unhook) .. ").", LEVELS.WARN)
    elseif unhook then
      table.insert(unhooks, unhook)
    end
  end

  function run.begin(target)
    local dap = deps.dap
    if dap then
      dap.adapters = dap.adapters or {}
      if not dap.adapters.coreclr then
        local path = deps.find_adapter and deps.find_adapter() or nil
        if not path then
          notify(M.install_hint("adapter"), LEVELS.WARN)
          finish()
          return
        end
        dap.adapters.coreclr = { type = "executable", command = path, args = { "--interpreter=vscode" } }
      end
    end
    if deps.on_exit then watch("Neovim exiting", deps.on_exit, on_exit) end
    if deps.bufnr and deps.on_buffer_gone then
      watch("the buffer closing", deps.on_buffer_gone, deps.bufnr, function() run.abort("buffer closed") end)
    end
    if abort_when_held then
      notify("SageFs debug: the buffer was closed before the test was held. Nothing was held.", LEVELS.INFO)
      finish()
      return
    end
    deps.http({
      method = "POST",
      url = deps.base_url() .. M.HOLD_PATH,
      body = M.build_hold_body(target, deps.session_id and deps.session_id() or nil),
      timeout = HOLD_TIMEOUT_S,
      callback = function(ok, raw)
        if state == "finished" then return end
        local answer = M.parse_answer(ok, raw)
        if M.classify_hold(answer) ~= "held" then
          local text, level = M.format_final(answer)
          notify(text, level)
          finish()
          return
        end
        on_held(answer)
      end,
    })
  end

  return run
end

--- Start debugging a test. One run at a time: the host holds one test.
---@param deps table see default_deps
---@param target { test_id: string|nil, pattern: string|nil }
---@return table run { state, held, release, abort }
function M.start(deps, target)
  if active and active.state() ~= "finished" then
    if deps.notify then
      deps.notify("SageFs debug: a debug run is already open. Finish it, or stop it with :SageFsDebugRelease.", LEVELS.WARN)
    end
    return active
  end
  local run = new_run(deps)
  active = run
  run.begin(target)
  return run
end

--- Release the open run's hold (manual mode, or to abandon a run).
---@return boolean released false when there is nothing open
function M.release_current()
  if not active or active.state() == "finished" then return false end
  active.abort("manual release")
  return true
end

-- ─── Real dependencies ───────────────────────────────────────────────────────

--- Deps backed by Neovim: transport, nvim-dap (soft), libuv timers, autocmds.
---@param plugin table the plugin module (for the active session)
---@param helpers table { base_url: fun(): string, notify: fun(msg, level) }
---@param bufnr number|nil buffer the run starts from
function M.default_deps(plugin, helpers, bufnr)
  local ok_dap, dap = pcall(require, "dap")
  return {
    base_url = helpers.base_url,
    session_id = function() return plugin.active_session and plugin.active_session.id or nil end,
    dap = ok_dap and dap or nil,
    find_adapter = function() return (M.find_netcoredbg(M.default_probe())) end,
    notify = function(msg, level)
      -- helpers.notify adds the "[SageFs] " prefix; our texts carry "SageFs debug:" already.
      vim.notify(msg, level or LEVELS.INFO)
    end,
    http = require("sagefs.transport").http_json,
    defer = function(ms, fn)
      local timer = vim.uv.new_timer()
      timer:start(ms, 0, vim.schedule_wrap(function()
        if not timer:is_closing() then timer:stop(); timer:close() end
        fn()
      end))
      return function()
        if not timer:is_closing() then timer:stop(); timer:close() end
      end
    end,
    wait = function(ms, cond) vim.wait(ms, cond, 10) end,
    release_sync = function(url, body)
      vim.fn.system({ "curl", "-s", "-m", "5", "-X", "POST", "-H", "Content-Type: application/json", "-d", body, url })
    end,
    on_exit = function(fn)
      local id = vim.api.nvim_create_autocmd("VimLeavePre", { callback = function() fn() end })
      return function() pcall(vim.api.nvim_del_autocmd, id) end
    end,
    on_buffer_gone = function(buf, fn)
      if not vim.api.nvim_buf_is_valid(buf) then
        fn() -- already gone: there is nothing to wait for
        return function() end
      end
      local id = vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        buffer = buf, once = true, callback = function() fn() end,
      })
      return function() pcall(vim.api.nvim_del_autocmd, id) end
    end,
    bufnr = bufnr,
  }
end

return M
