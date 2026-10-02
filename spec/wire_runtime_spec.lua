-- wire_runtime: the glue between the daemon wire and the editor, with every
-- impure thing (notify, clock, session refresh, redraw) passed in. This is what
-- init.lua forwards the SSE handlers, the eval result and the statusline to.
require("spec.helper")
local wire_runtime = require("sagefs.wire_runtime")
local fx = require("spec.wire_fixtures")

local LEVELS = vim.log.levels

local function harness(opts)
  opts = opts or {}
  local h = { notes = {}, refreshes = 0, redraws = 0, shown = {}, now = 1000 }
  h.active = opts.active
  if h.active == nil then h.active = { id = "adfd6b6b" } end
  h.rt = wire_runtime.new({
    notify = function(msg, level) table.insert(h.notes, { msg = msg, level = level }) end,
    now_ms = function() return h.now end,
    refresh_sessions = function(cb) h.refreshes = h.refreshes + 1; if cb then cb() end end,
    active_session = function() return h.active end,
    redraw = function() h.redraws = h.redraws + 1 end,
    ui = {
      show = function(sid, display) table.insert(h.shown, { sid = sid, text = display.text }) end,
      clear = function(sid) table.insert(h.shown, { sid = sid, cleared = true }) end,
    },
    notify_reload = opts.notify_reload,
  })
  return h
end

local function frame(outcome, extra)
  local r = { state = "finished", outcome = outcome, patched = 0, considered = 1, message = "m", mechanism = "" }
  for k, v in pairs(extra or {}) do r[k] = v end
  return { sessionId = "adfd6b6b", reloadReported = r }
end

describe("wire_runtime.on_reload_reported", function()
  it("folds the report into the model and shows it for the active session", function()
    local h = harness()
    h.rt.on_reload_reported(frame("PatchPending", { mechanism = "metadata-delta" }))
    assert.are.same({ "HR ◐ applied, not run yet [delta]" }, h.rt.statusline_segments())
    assert.are.equal("applied, new body has not run yet", h.shown[#h.shown].text)
    assert.is_true(h.redraws >= 1)
  end)

  it("stays quiet about a pending patch and a confirmed one", function()
    local h = harness()
    h.rt.on_reload_reported(frame("PatchPending", { mechanism = "metadata-delta" }))
    h.rt.on_reload_reported(frame("Patched", { mechanism = "metadata-delta", patched = 1 }))
    assert.are.equal(0, #h.notes)
  end)

  it("says so when the new body never ran, as a warning with the truth in it", function()
    local h = harness()
    h.rt.on_reload_reported(frame("NeverEntered", { mechanism = "metadata-delta" }))
    assert.are.equal(1, #h.notes)
    assert.are.equal(LEVELS.WARN, h.notes[1].level)
    assert.truthy(h.notes[1].msg:find("applied, but the new body never ran", 1, true))
  end)

  it("says a restart is needed as an error, with the cause", function()
    local h = harness()
    h.rt.on_reload_reported(frame("RestartRequired", { message = "Restart needed: the signature of A.f changed" }))
    assert.are.equal(LEVELS.ERROR, h.notes[1].level)
    assert.truthy(h.notes[1].msg:find("restart needed: the signature of A.f changed", 1, true))
  end)

  it("says the app restarted as information", function()
    local h = harness()
    h.rt.on_reload_reported(frame("Restarted", { message = "Restarted the app: type X was added" }))
    assert.are.equal(LEVELS.INFO, h.notes[1].level)
    assert.truthy(h.notes[1].msg:find("restarted: type X was added", 1, true))
  end)

  it("does not repeat an identical notification for the same state", function()
    local h = harness()
    h.rt.on_reload_reported(frame("NeverEntered"))
    h.rt.on_reload_reported(frame("NeverEntered"))
    assert.are.equal(1, #h.notes)
  end)

  it("keeps quiet when the user turned reload notifications off, and still shows the state", function()
    local h = harness({ notify_reload = false })
    h.rt.on_reload_reported(frame("RestartRequired"))
    assert.are.equal(0, #h.notes)
    assert.are_not.equal(0, #h.rt.statusline_segments())
  end)

  it("tracks a session that is not the active one without notifying or showing it", function()
    local h = harness({ active = { id = "other" } })
    h.rt.on_reload_reported(frame("RestartRequired"))
    assert.are.equal(0, #h.notes)
    assert.are.same({}, h.rt.statusline_segments())
    h.active = { id = "adfd6b6b" }
    assert.are_not.equal(0, #h.rt.statusline_segments())
  end)

  it("asks for the session list again, because the REPL's freshness lives there", function()
    local h = harness()
    h.rt.on_reload_reported(frame("PatchPending", { mechanism = "metadata-delta" }))
    assert.are.equal(1, h.refreshes)
  end)

  it("does not re-read the list for a compiling frame: nothing about freshness can have changed yet", function()
    local h = harness()
    h.rt.on_reload_reported({ sessionId = "adfd6b6b", reloadReported = { state = "compiling", file = "Program.fs" } })
    assert.are.equal(0, h.refreshes)
    h.rt.on_reload_reported(frame("PatchPending", { mechanism = "metadata-delta" }))
    assert.are.equal(1, h.refreshes)
  end)

  it("ignores an undecodable frame", function()
    local h = harness()
    h.rt.on_reload_reported(nil)
    h.rt.on_reload_reported({})
    assert.are.equal(0, #h.notes)
  end)
end)

describe("wire_runtime REPL freshness", function()
  local function behind_session()
    return {
      id = "adfd6b6b",
      repl_freshness = { state = "BehindApp", known = true, saves_since = 1, declarations = { "FalcoHello.Program.greet" }, message = "daemon words" },
    }
  end

  it("puts the warning in the statusline when the session is behind", function()
    local h = harness({ active = behind_session() })
    assert.are.same({ "⚠ REPL BEHIND app (1 save)" }, h.rt.statusline_segments())
  end)

  it("says it once per eval state, with the remedy, and not again for the same state straight away", function()
    local h = harness({ active = behind_session() })
    h.rt.on_eval({ ok = true, output = "val it: int = 2" })
    assert.are.equal(1, #h.notes)
    assert.are.equal(LEVELS.WARN, h.notes[1].level)
    assert.truthy(h.notes[1].msg:find(":SageFsHardReset", 1, true))
    assert.truthy(h.notes[1].msg:find("stops the running app", 1, true))
    h.now = h.now + 5000
    h.rt.on_eval({ ok = true, output = "val it: int = 3" })
    assert.are.equal(1, #h.notes)
    h.now = h.now + 60000
    h.rt.on_eval({ ok = true, output = "val it: int = 4" })
    assert.are.equal(2, #h.notes)
  end)

  it("says nothing on eval when the REPL is level", function()
    local h = harness({ active = { id = "x", repl_freshness = { state = "InSync", known = true } } })
    h.rt.on_eval({ ok = true, output = "val it: int = 2" })
    assert.are.equal(0, #h.notes)
  end)

  it("takes the WARNING banner off the cell output, and turns it into the one-line message", function()
    local body = vim.json.decode(fx.read("exec-behind-app.json"))
    local h = harness({ active = { id = "adfd6b6b" } })
    local result = h.rt.on_eval({ ok = true, output = body.result })
    assert.are.equal("Result: val it: int = 2", result.output)
    assert.are.equal(1, #h.notes)
    assert.truthy(h.notes[1].msg:find("The REPL is BEHIND the app", 1, true))
    assert.truthy(h.notes[1].msg:find(":SageFsHardReset", 1, true))
    assert.are.same({ "⚠ REPL BEHIND app" }, h.rt.statusline_segments())
  end)

  it("takes the banner off an error result too", function()
    local body = vim.json.decode(fx.read("exec-behind-app.json"))
    local h = harness()
    local result = h.rt.on_eval({ ok = false, error = "error FS0039: nope\n\n" .. select(2, require("sagefs.repl_freshness").split_banner(body.result)) })
    assert.are.equal("error FS0039: nope", result.error)
  end)

  it("believes the session list over a banner once the list has been read again", function()
    local h = harness({ active = { id = "adfd6b6b" } })
    local body = vim.json.decode(fx.read("exec-behind-app.json"))
    h.rt.on_eval({ ok = true, output = body.result })
    assert.are_not.same({}, h.rt.statusline_segments())
    h.active = { id = "adfd6b6b", repl_freshness = { state = "InSync", known = true } }
    h.rt.on_sessions({ h.active })
    assert.are.same({}, h.rt.statusline_segments())
  end)

  it("a hard reset clears what it knew and asks for the list", function()
    local h = harness({ active = behind_session() })
    local before = h.refreshes
    h.rt.on_hard_reset()
    assert.is_true(h.refreshes > before)
  end)
end)

describe("wire_runtime.report_lines (the :SageFsReloadStatus panel)", function()
  it("shows the reload truth, then the REPL state", function()
    local h = harness({ active = {
      id = "adfd6b6b",
      repl_freshness = { state = "BehindApp", known = true, saves_since = 1, declarations = { "A.f" }, message = "daemon words" },
    } })
    h.rt.on_reload_reported(frame("PatchPending", { mechanism = "metadata-delta" }))
    local lines = h.rt.report_lines()
    local text = {}
    for _, l in ipairs(lines) do table.insert(text, l.text) end
    local joined = table.concat(text, "\n")
    assert.truthy(joined:find("applied, new body has not run yet", 1, true))
    assert.truthy(joined:find("via metadata delta", 1, true))
    assert.truthy(joined:find("REPL is BEHIND the app", 1, true))
  end)

  it("says there is nothing yet when nothing has been reported", function()
    local h = harness({ active = { id = "z" } })
    local lines = h.rt.report_lines()
    assert.truthy(lines[1].text:find("no hot reload yet", 1, true))
  end)
end)

describe("wire_runtime.on_reconnect", function()
  it("forgets what events said, so the next session list is believed", function()
    local h = harness()
    h.rt.on_reload_reported(frame("RestartRequired"))
    h.rt.on_reconnect()
    assert.are.same({}, h.rt.statusline_segments())
  end)
end)

describe("wire_runtime surfaces that outlive one frame", function()
  it("tells the virtual-text surface which file a save is about, from the compiling frame", function()
    local noted = {}
    local rt = wire_runtime.new({
      notify = function() end, now_ms = function() return 0 end,
      active_session = function() return { id = "adfd6b6b" } end,
      ui = {
        show = function() end, clear = function() end,
        note_file = function(sid, file) table.insert(noted, { sid = sid, file = file }) end,
      },
    })
    rt.on_reload_reported({ sessionId = "adfd6b6b", reloadReported = { state = "compiling", file = "Program.fs" } })
    assert.are.same({ { sid = "adfd6b6b", file = "Program.fs" } }, noted)
  end)

  it("asks for a statusline redraw after a harmless verdict's fade, so the segment goes away on its own", function()
    local later = {}
    local rt = wire_runtime.new({
      notify = function() end, now_ms = function() return 0 end,
      active_session = function() return { id = "adfd6b6b" } end,
      redraw_later = function(ms) table.insert(later, ms) end,
    })
    rt.on_reload_reported({ sessionId = "adfd6b6b", reloadReported = { state = "finished", outcome = "Patched", patched = 1, considered = 1, message = "m" } })
    assert.are.same({ 15050 }, later)
    rt.on_reload_reported({ sessionId = "adfd6b6b", reloadReported = { state = "finished", outcome = "RestartRequired", patched = 0, considered = 1, message = "m" } })
    assert.are.same({ 15050 }, later)
  end)
end)

describe("wire_runtime.on_session_ready: the worker was replaced", function()
  it("forgets what events said about that session and reads the list again, because the daemon cleared both", function()
    local h = harness()
    h.rt.on_reload_reported(frame("Patched", { mechanism = "metadata-delta", patched = 1 }))
    local before = h.refreshes
    h.rt.on_session_ready({ sessionReady = "adfd6b6b" })
    assert.are.equal(before + 1, h.refreshes)
    assert.is_nil(require("sagefs.reload_state").current(h.rt.model(), "adfd6b6b"))
  end)

  it("drops a banner-derived behind state for that session", function()
    local body = vim.json.decode(fx.read("exec-behind-app.json"))
    local h = harness({ active = { id = "adfd6b6b" } })
    h.rt.on_eval({ ok = true, output = body.result })
    assert.are_not.same({}, h.rt.statusline_segments())
    h.rt.on_session_ready({ sessionReady = "adfd6b6b" })
    assert.are.same({}, h.rt.statusline_segments())
  end)

  it("leaves other sessions alone", function()
    local h = harness()
    h.rt.on_reload_reported(frame("RestartRequired"))
    h.rt.on_session_ready({ sessionReady = "someone-else" })
    assert.are.equal("RestartRequired", require("sagefs.reload_state").current(h.rt.model(), "adfd6b6b").outcome)
  end)

  it("ignores a frame with no session id", function()
    local h = harness()
    h.rt.on_session_ready({})
    h.rt.on_session_ready(nil)
    assert.are.equal(0, h.refreshes)
  end)
end)
