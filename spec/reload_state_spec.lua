-- Hot reload truth: the closed outcome set, the one function that turns a
-- reload report into display text, and the pure fold that keeps the latest
-- report per session. Payloads are the ones the dev daemon sent (see
-- spec/wire_fixtures.lua for provenance); shapes the daemon documents but did
-- not produce in the capture are written out in the spec and say so.
require("spec.helper")
local R = require("sagefs.reload_state")
local sse = require("sagefs.sse")
local fx = require("spec.wire_fixtures")

local function decode(s) return vim.json.decode(s) end

--- Every `state` frame of the captured save sequence, as the plugin's own SSE
--- parser and classifier see it, in arrival order.
local function captured_frames()
  local events = sse.parse_chunk(fx.read("sse-hot-reload-session.txt"))
  local frames = {}
  for _, ev in ipairs(events) do
    local data = decode(ev.data)
    table.insert(frames, { action = sse.classify_state_event(data), data = data })
  end
  return frames
end

local function reload_frames()
  local out = {}
  for _, f in ipairs(captured_frames()) do
    if f.action == "reload_reported" then table.insert(out, f.data) end
  end
  return out
end

describe("reload_state closed sets", function()
  it("names the eight outcomes SessionReload.ReloadCase names, in one place", function()
    assert.are.same({
      "Patched", "PatchPending", "NeverEntered", "Restarted",
      "NoEffect", "RestartRequired", "CompileFailed", "KeptLiveState",
    }, R.OUTCOME.all)
    assert.are.equal("PatchPending", R.OUTCOME.PatchPending)
  end)

  it("names the mechanisms, with the empty token for a verdict that is not a patch", function()
    assert.are.equal("detour", R.MECHANISM.Detour)
    assert.are.equal("metadata-delta", R.MECHANISM.MetadataDelta)
    assert.are.equal("", R.MECHANISM.NoPatch)
  end)

  it("names the phases of a report", function()
    assert.are.same({ "none", "compiling", "finished" }, R.PHASE.all)
  end)
end)

describe("reload_state.parse", function()
  it("reads the finished PatchPending frame the daemon sent for a metadata delta", function()
    local frames = reload_frames()
    local pending
    for _, f in ipairs(frames) do
      if f.reloadReported.outcome == "PatchPending" then pending = f; break end
    end
    local r = R.parse(pending.reloadReported)
    assert.are.equal("finished", r.phase)
    assert.are.equal("PatchPending", r.outcome)
    assert.is_true(r.known)
    assert.are.equal("metadata-delta", r.mechanism)
    assert.are.equal(0, r.patched)
    assert.are.equal(1, r.considered)
    assert.truthy(r.message:find("not confirmed yet", 1, true))
    assert.truthy(r.suggested_action:find("Exercise the changed code", 1, true))
    assert.are.same({}, r.declarations)
  end)

  it("reads the compiling frame, which carries a file and no outcome", function()
    local r = R.parse({ file = "Program.fs", state = "compiling" })
    assert.are.equal("compiling", r.phase)
    assert.are.equal("Program.fs", r.file)
    assert.is_nil(r.outcome)
  end)

  it("reads the session-level lastReload object the same way as the SSE one", function()
    local sessions = decode(fx.read("api-sessions.json")).sessions
    local r = R.parse(sessions[1].lastReload)
    assert.are.equal("NeverEntered", r.outcome)
    assert.are.equal("metadata-delta", r.mechanism)
    assert.are.equal(0, r.patched)
    assert.are.equal(1, r.considered)
  end)

  it("returns nil for no report: null, absent, or not a table", function()
    assert.is_nil(R.parse(nil))
    assert.is_nil(R.parse("x"))
    assert.is_nil(R.parse(42))
  end)

  it("reads the worker's own payload, whose `type` cue and `declarations`/`reasons`/`kept` the daemon wire drops", function()
    -- DevReloadEvent.payloadJson shape (SageFs.Core/DevReload.fs reportFields), the
    -- pending form of ReplFreshnessTests, plus a refusal as refusalJson writes it.
    local pending = R.parse({
      type = "pending", outcome = "PatchPending", mechanism = "metadata-delta", patched = 0, considered = 2,
      message = "m", suggestedAction = "s", reasons = {},
      declarations = { "Handlers.describe", "Handlers.makeHeld" },
    })
    assert.are.same({ "Handlers.describe", "Handlers.makeHeld" }, pending.declarations)
    local restart = R.parse({
      type = "restarted", outcome = "Restarted", patched = 0, considered = 1, message = "Restarted the app: x",
      suggestedAction = "", reasons = {
        { case = "FieldsChanged", message = "the fields of Shape changed", suggestedAction = "restart" },
      },
    })
    assert.are.equal(1, #restart.reasons)
    assert.are.equal("FieldsChanged", restart.reasons[1].case)
    assert.are.equal("the fields of Shape changed", restart.reasons[1].message)
  end)

  it("falls back to the worker `type` cue only when the outcome token is missing", function()
    assert.are.equal("PatchPending", R.parse({ type = "pending" }).outcome)
    assert.are.equal("Patched", R.parse({ type = "patched" }).outcome)
    assert.are.equal("NeverEntered", R.parse({ type = "neverentered" }).outcome)
    assert.are.equal("Restarted", R.parse({ type = "restarted" }).outcome)
    assert.are.equal("NoEffect", R.parse({ type = "noeffect" }).outcome)
    assert.are.equal("CompileFailed", R.parse({ type = "failed" }).outcome)
    assert.are.equal("none", R.parse({ type = "none" }).phase)
    assert.are.equal("compiling", R.parse({ type = "compiling", file = "A.fs" }).phase)
  end)

  it("keeps a token the daemon invented, marked unknown, instead of guessing", function()
    local r = R.parse({ state = "finished", outcome = "Exploded", message = "boom" })
    assert.are.equal("Exploded", r.outcome)
    assert.is_false(r.known)
  end)

  it("reads the kept live values a save kept", function()
    local r = R.parse({
      state = "finished", outcome = "KeptLiveState", patched = 0, considered = 1, message = "Live state kept",
      kept = { { binding = "App.State.tuned", keptValue = "13", newInitializer = "25" } },
    })
    assert.are.equal("App.State.tuned", r.kept[1].binding)
    assert.are.equal("13", r.kept[1].kept_value)
    assert.are.equal("25", r.kept[1].new_initializer)
  end)
end)

describe("reload_state.display: the truth in words", function()
  local function d(payload) return R.display(R.parse(payload)) end

  it("PatchPending says applied and not yet run, never live", function()
    local x = d({ state = "finished", outcome = "PatchPending", mechanism = "metadata-delta", patched = 0, considered = 1, message = "m" })
    assert.are.equal("applied, new body has not run yet", x.text)
    assert.are.equal("applied, not run yet", x.short)
    assert.are.equal("info", x.severity)
    assert.are.equal("SageFsReloadPending", x.hl)
    assert.is_false(x.attention)
  end)

  it("Patched says the new body ran", function()
    local x = d({ state = "finished", outcome = "Patched", mechanism = "detour", patched = 2, considered = 2, message = "m" })
    assert.are.equal("patched (ran)", x.text)
    assert.are.equal("ok", x.severity)
    assert.are.equal("SageFsReloadOk", x.hl)
    assert.is_truthy(x.fade_ms)
  end)

  it("NeverEntered says the new body never ran, with the counts, and is not green", function()
    local x = d({ state = "finished", outcome = "NeverEntered", mechanism = "metadata-delta", patched = 0, considered = 1, message = "m" })
    assert.are.equal("applied, but the new body never ran (0 of 1 did): exercise it, or the callee was inlined", x.text)
    assert.are.equal("warn", x.severity)
    assert.is_true(x.attention)
    assert.are_not.equal("ok", x.severity)
  end)

  it("RestartRequired says restart needed with the cause from the reasons when the payload has them", function()
    local x = d({
      state = "finished", outcome = "RestartRequired", patched = 0, considered = 1, message = "Restart needed: x",
      reasons = { { case = "FieldsChanged", message = "the fields of Shape changed\nmore", suggestedAction = "r" } },
    })
    assert.are.equal("restart needed: FieldsChanged, the fields of Shape changed", x.text)
    assert.are.equal("restart needed: FieldsChanged", x.short)
    assert.are.equal("error", x.severity)
    assert.is_true(x.attention)
    assert.are.equal("FieldsChanged", x.cause.case)
  end)

  it("takes the cause from the message when the daemon wire (which carries no reasons) is all there is", function()
    local x = d({
      state = "finished", outcome = "RestartRequired", patched = 0, considered = 1,
      message = "Restart needed: the signature of Handlers.describe changed\n→ Restart the app.",
      suggestedAction = "Restart the app.",
    })
    assert.are.equal("restart needed: the signature of Handlers.describe changed", x.text)
    assert.is_nil(x.cause.case)
  end)

  it("Restarted names why the app restarted: the real frame, signature change", function()
    local frames = reload_frames()
    local sig
    for _, f in ipairs(frames) do
      if f.reloadReported.message and f.reloadReported.message:find("signature of", 1, true) then sig = f end
    end
    local x = R.display(R.parse(sig.reloadReported))
    assert.are.equal("restarted: the signature of FalcoHello.Program.greet changed", x.text)
    assert.are.equal("restarted", x.short)
  end)

  it("Restarted with no cause in the message still says it restarted", function()
    local x = d({ state = "finished", outcome = "Restarted", patched = 0, considered = 0, message = "" })
    assert.are.equal("restarted", x.text)
  end)

  it("MetadataDeltaUnavailable is a named restart cause", function()
    local x = d({
      state = "finished", outcome = "RestartRequired", patched = 0, considered = 1, message = "Restart needed: x",
      reasons = { { case = "MetadataDeltaUnavailable", message = "SageFs cannot patch this app in place: a debugger is attached", suggestedAction = "detach" } },
    })
    assert.are.equal("restart needed: MetadataDeltaUnavailable, SageFs cannot patch this app in place: a debugger is attached", x.text)
  end)

  it("CompileFailed says the app keeps the last good code", function()
    local x = d({
      state = "finished", outcome = "CompileFailed", patched = 0, considered = 0,
      message = "Not applied — the file did not compile, so the app is still serving the last good code: error FS0001: bad",
    })
    assert.are.equal("did not compile; the app keeps running the last code that did: error FS0001: bad", x.text)
    assert.are.equal("error", x.severity)
    assert.are.equal("compile failed", x.short)
  end)

  it("NoEffect with nothing considered is quiet and says how little reached the app: the real eval-time frame", function()
    local frame
    for _, f in ipairs(reload_frames()) do
      if f.reloadReported.outcome == "NoEffect" then frame = f end
    end
    local x = R.display(R.parse(frame.reloadReported))
    assert.are.equal("no effect (0 of 0 changed definitions reached the running app)", x.text)
    assert.are.equal("quiet", x.severity)
    assert.is_false(x.attention)
  end)

  it("KeptLiveState says the live value was kept", function()
    local x = d({
      state = "finished", outcome = "KeptLiveState", patched = 0, considered = 1, message = "Live state kept: x",
      kept = { { binding = "App.State.tuned", keptValue = "13", newInitializer = "25" } },
    })
    assert.are.equal("kept live value App.State.tuned = 13 (the new initializer 25 applies when you reset it)", x.text)
    assert.are.equal("ok", x.severity)
  end)

  it("names the mechanism from the field, never from the words", function()
    local delta = d({ state = "finished", outcome = "PatchPending", mechanism = "metadata-delta", message = "by detour in words only" })
    assert.are.equal("metadata-delta", delta.mechanism)
    assert.are.equal("via metadata delta", delta.mechanism_text)
    assert.are.equal("delta", delta.tag)
    local detour = d({ state = "finished", outcome = "Patched", mechanism = "detour", message = "m" })
    assert.are.equal("via detour", detour.mechanism_text)
    assert.are.equal("detour", detour.tag)
    local none = d({ state = "finished", outcome = "Restarted", mechanism = "", message = "Restarted the app: x" })
    assert.is_nil(none.mechanism_text)
    assert.is_nil(none.tag)
  end)

  it("compiling and none are shown as what they are", function()
    local c = R.display(R.parse({ file = "Program.fs", state = "compiling" }))
    assert.are.equal("compiling Program.fs", c.text)
    assert.are.equal("info", c.severity)
    local n = R.display(R.parse({ type = "none" }))
    assert.are.equal("no hot reload yet", n.text)
  end)

  it("an outcome outside the closed set is shown as unrecognized and warns", function()
    local x = d({ state = "finished", outcome = "Exploded", message = "boom" })
    assert.are.equal("unrecognized reload outcome 'Exploded'", x.text)
    assert.are.equal("warn", x.severity)
  end)

  it("maps every outcome in the closed set, so a new case cannot arrive without a display", function()
    for _, outcome in ipairs(R.OUTCOME.all) do
      local x = d({ state = "finished", outcome = outcome, message = "m" })
      assert.is_string(x.text)
      assert.is_string(x.hl)
      assert.is_string(x.icon)
      assert.is_truthy(x.severity)
    end
  end)
end)

describe("reload_state.statusline", function()
  it("is empty before any save", function()
    assert.are.equal("", R.statusline(nil))
    assert.are.equal("", R.statusline(R.parse({ type = "none" })))
  end)

  it("shows icon, short truth and the mechanism tag", function()
    local r = R.parse({ state = "finished", outcome = "PatchPending", mechanism = "metadata-delta", patched = 0, considered = 1, message = "m" })
    assert.are.equal("HR ◐ applied, not run yet [delta]", R.statusline(r))
    local p = R.parse({ state = "finished", outcome = "Patched", mechanism = "detour", patched = 1, considered = 1, message = "m" })
    assert.are.equal("HR ● patched (ran) [detour]", R.statusline(p))
  end)

  it("shows a restart with its cause token and no tag", function()
    local r = R.parse({
      state = "finished", outcome = "RestartRequired", patched = 0, considered = 1, message = "x",
      reasons = { { case = "SignatureChanged", message = "m", suggestedAction = "r" } },
    })
    assert.are.equal("HR ↻ restart needed: SignatureChanged", R.statusline(r))
  end)
end)

describe("reload_state.lines", function()
  it("lays a pending metadata-delta save out as truth, mechanism and remedy", function()
    local r = R.parse({
      state = "finished", outcome = "PatchPending", mechanism = "metadata-delta", patched = 0, considered = 1,
      message = "Applied 1 of 1 changed method(s) by metadata delta, not confirmed yet: the new code has not run\n→ Exercise it.",
      suggestedAction = "Exercise it.",
    })
    local lines = R.lines(r)
    assert.are.equal("◐ applied, new body has not run yet", lines[1].text)
    assert.are.equal("SageFsReloadPending", lines[1].hl)
    assert.are.equal("  via metadata delta", lines[2].text)
    assert.are.equal("  → Exercise it.", lines[3].text)
  end)

  it("lists up to three causes and counts the rest", function()
    local reasons = {}
    for i = 1, 5 do reasons[i] = { case = "C" .. i, message = "m" .. i, suggestedAction = "" } end
    local r = R.parse({ state = "finished", outcome = "RestartRequired", patched = 0, considered = 5, message = "x", reasons = reasons })
    local text = {}
    for _, l in ipairs(R.lines(r)) do table.insert(text, l.text) end
    local joined = table.concat(text, "\n")
    assert.truthy(joined:find("C1: m1", 1, true))
    assert.truthy(joined:find("C3: m3", 1, true))
    assert.is_nil(joined:find("C4: m4", 1, true))
    assert.truthy(joined:find("and 2 more", 1, true))
  end)

  it("says nothing for no report", function()
    assert.are.same({}, R.lines(nil))
  end)
end)

describe("reload_state model fold over the captured save sequence", function()
  local function fold_through(upto)
    local m = R.model_new()
    local n = 0
    for _, f in ipairs(captured_frames()) do
      if f.action == "reload_reported" then
        n = n + 1
        if n > upto then break end
        m = select(1, R.apply_sse(m, f.data))
      end
    end
    return m
  end

  it("classifies the captured frames: reloadReported is a reload, hotReloadChanged and fileReloaded stay what they were", function()
    local counts = {}
    for _, f in ipairs(captured_frames()) do counts[f.action] = (counts[f.action] or 0) + 1 end
    assert.are.equal(15, counts.reload_reported)
    assert.are.equal(15, counts.hot_reload_changed)
    assert.are.equal(5, counts.file_reloaded)
  end)

  it("shows compiling, then the restart, then applied-but-not-run, then patched (ran)", function()
    local m = fold_through(1)
    local sid = "adfd6b6b"
    assert.are.equal("compiling", R.current(m, sid).phase)
    m = fold_through(2)
    assert.are.equal("Restarted", R.current(m, sid).outcome)
    m = fold_through(4)
    assert.are.equal("PatchPending", R.current(m, sid).outcome)
    assert.are.equal("applied, new body has not run yet", R.display(R.current(m, sid)).text)
    m = fold_through(5)
    assert.are.equal("Patched", R.current(m, sid).outcome)
    assert.are.equal("patched (ran)", R.display(R.current(m, sid)).text)
  end)

  it("an eval's no-effect after a patch does NOT become what is displayed", function()
    -- The daemon records every terminal reload event as the session's lastReload,
    -- including the no-effect an eval produces (SageFs/DaemonMode.fs:3001 relays
    -- each payload to ReloadObserved). So after a working patch, this exact
    -- sequence hands the plugin a no-effect. Showing it says the hot reload
    -- stopped working, which is the opposite of what happened.
    local m = fold_through(6)
    local cur = R.current(m, "adfd6b6b")
    assert.are.equal("Patched", cur.outcome, "the patch verdict is what the user is still looking at")
    assert.are.equal("patched (ran)", R.display(cur).text)
    local noop = m.last_noop and m.last_noop["adfd6b6b"]
    assert.is_table(noop, "the no-effect is still recorded, just not displayed")
    assert.are.equal("NoEffect", noop.outcome)
    assert.are.equal(0, noop.considered)
  end)

  it("the displayed verdict still replaces the one before it, and the no-op never becomes that `previous`", function()
    local m = fold_through(6)
    assert.are.equal("PatchPending", R.previous(m, "adfd6b6b").outcome)
    assert.are_not.equal("NoEffect", R.previous(m, "adfd6b6b").outcome,
      "a no-op names nothing, so it is not a verdict a panel can show as 'last save'")
  end)

  it("walks the whole sequence and never shows a no-op in place of a verdict", function()
    local m = R.model_new()
    local seen = {}
    for _, f in ipairs(reload_frames()) do
      m = select(1, R.apply_sse(m, f))
      local cur = R.current(m, "adfd6b6b")
      table.insert(seen, cur.outcome or cur.phase)
    end
    -- The two NoEffect frames of the capture (frame 6 and frame 15) are the no-effects
    -- an eval produced behind two real patches. Each is held back, so the sequence
    -- stays on the verdict that actually describes the save and the slot repeats it.
    assert.are.same({
      "compiling", "Restarted", "compiling", "PatchPending", "Patched", "Patched",
      "compiling", "PatchPending", "Patched", "compiling", "Restarted", "compiling",
      "PatchPending", "NeverEntered", "NeverEntered",
    }, seen)
  end)

  it("keeps sessions apart", function()
    local m = R.model_new()
    m = select(1, R.apply_sse(m, { sessionId = "a", reloadReported = { state = "finished", outcome = "Patched", message = "m" } }))
    m = select(1, R.apply_sse(m, { sessionId = "b", reloadReported = { state = "finished", outcome = "RestartRequired", message = "m" } }))
    assert.are.equal("Patched", R.current(m, "a").outcome)
    assert.are.equal("RestartRequired", R.current(m, "b").outcome)
  end)

  it("a frame with only a sessionId is the daemon saying the report was cleared (worker replaced)", function()
    local m = R.model_new()
    m = select(1, R.apply_sse(m, { sessionId = "a", reloadReported = { state = "finished", outcome = "Patched", message = "m" } }))
    local cleared, info = R.apply_sse(m, { sessionId = "a" })
    assert.is_nil(R.current(cleared, "a"))
    assert.is_true(info.changed)
  end)

  it("does not mutate the model it was given", function()
    local m = R.model_new()
    local m2 = select(1, R.apply_sse(m, { sessionId = "a", reloadReported = { state = "finished", outcome = "Patched", message = "m" } }))
    assert.is_nil(R.current(m, "a"))
    assert.are.equal("Patched", R.current(m2, "a").outcome)
  end)

  it("a session list seeds a session no event has spoken for, and never overrides one an event has", function()
    local m = R.model_new()
    local seeded = R.seed(m, { { id = "a", last_reload = R.parse({ state = "finished", outcome = "Restarted", message = "x" }) } })
    assert.are.equal("Restarted", R.current(seeded, "a").outcome)
    local live = select(1, R.apply_sse(seeded, { sessionId = "a", reloadReported = { state = "finished", outcome = "Patched", message = "m" } }))
    local reseeded = R.seed(live, { { id = "a", last_reload = R.parse({ state = "finished", outcome = "Restarted", message = "x" }) } })
    assert.are.equal("Patched", R.current(reseeded, "a").outcome)
  end)

  it("forgets what events said when the connection drops, so the next list is believed again", function()
    local m = select(1, R.apply_sse(R.model_new(), { sessionId = "a", reloadReported = { state = "finished", outcome = "Patched", message = "m" } }))
    m = R.drop_events(m)
    assert.is_nil(R.current(m, "a"))
  end)

  it("reads a vim.NIL / non-table reloadReported as cleared", function()
    local m = select(1, R.apply_sse(R.model_new(), { sessionId = "a", reloadReported = { state = "finished", outcome = "Patched", message = "m" } }))
    local cleared = select(1, R.apply_sse(m, { sessionId = "a", reloadReported = "null-ish" }))
    assert.is_nil(R.current(cleared, "a"))
  end)
end)

describe("reload_state fade: a settled harmless verdict leaves the statusline, a problem does not", function()
  local function observed(payload, at)
    local m = select(1, R.apply_sse(R.model_new(), { sessionId = "a", reloadReported = payload }, at))
    -- What a surface would actually show, which is not `current()` for a no-op:
    -- a no-op only holds the display back when a verdict replaces it.
    return R.displayable(m, "a", nil)
  end

  it("Patched fades after fifteen seconds, and only when the caller says what time it is", function()
    local r = observed({ state = "finished", outcome = "Patched", mechanism = "detour", patched = 1, considered = 1, message = "m" }, 1000)
    assert.are.equal("HR ● patched (ran) [detour]", R.statusline(r, 1000 + 14999))
    assert.are.equal("", R.statusline(r, 1000 + 15001))
    assert.are.equal("HR ● patched (ran) [detour]", R.statusline(r))
  end)

  it("a quiet no-effect fades after eight seconds", function()
    -- With nothing before it, a no-effect is still what is displayed: there is no
    -- better word, and it is the truth about this session's only save so far.
    local r = observed({ state = "finished", outcome = "NoEffect", patched = 0, considered = 0, message = "m" }, 0)
    assert.are.equal("HR ○ no effect", R.statusline(r, 7999))
    assert.are.equal("", R.statusline(r, 8001))
  end)

  it("pending, never-entered, restarts and compile failures never fade", function()
    for _, outcome in ipairs({ "PatchPending", "NeverEntered", "Restarted", "RestartRequired", "CompileFailed" }) do
      local r = observed({ state = "finished", outcome = outcome, patched = 0, considered = 1, message = "m" }, 0)
      assert.are_not.equal("", R.statusline(r, 10 * 60 * 1000), outcome)
    end
  end)

  it("a polled report that no event has confirmed is shown only if it is a problem", function()
    local m = R.seed(R.model_new(), {
      { id = "a", last_reload = R.parse({ state = "finished", outcome = "Patched", patched = 1, considered = 1, message = "m" }) },
      { id = "b", last_reload = R.parse({ state = "finished", outcome = "RestartRequired", patched = 0, considered = 1, message = "m" }) },
    })
    assert.are.equal("", R.statusline(R.current(m, "a"), 5))
    assert.are_not.equal("", R.statusline(R.current(m, "b"), 5))
  end)
end)

describe("reload_state highlight groups", function()
  it("defines every group the display can name, as a link target, so the UI layer has one list to apply", function()
    for _, outcome in ipairs(R.OUTCOME.all) do
      local x = R.display(R.parse({ state = "finished", outcome = outcome, message = "m" }))
      assert.is_string(R.HL[x.hl], x.hl)
    end
    assert.is_string(R.HL.SageFsReplBehind)
    assert.is_string(R.HL.SageFsReloadQuiet)
  end)
end)

describe("reload_state.forget", function()
  it("removes one session's report and the verdict it replaced, and leaves the others", function()
    local m = R.model_new()
    m = select(1, R.apply_sse(m, { sessionId = "a", reloadReported = { state = "finished", outcome = "Patched", message = "m" } }))
    m = select(1, R.apply_sse(m, { sessionId = "a", reloadReported = { state = "finished", outcome = "NoEffect", message = "m" } }))
    m = select(1, R.apply_sse(m, { sessionId = "b", reloadReported = { state = "finished", outcome = "Patched", message = "m" } }))
    local f = R.forget(m, "a")
    assert.is_nil(R.current(f, "a"))
    assert.is_nil(R.previous(f, "a"))
    assert.are.equal("Patched", R.current(f, "b").outcome)
    -- The no-effect was held back from the display, so a is still on its Patched.
    assert.are.equal("Patched", R.current(m, "a").outcome)
    -- `forget` RETURNS the cleared model; `m` is untouched, because the state is immutable and
    -- `forget` is a pure fold. Asserting on `m` here asked the ORIGINAL to have lost something,
    -- which it never does — that is what made this case fail against correct code.
    assert.is_nil(f.last_noop["a"], "forget drops the no-effect it was holding back")
    assert.are.equal("Patched", R.current(m, "a").outcome, "and the original model is untouched")
    -- A different session's held-back state must SURVIVE: forget is about ONE session, and
    -- dropping state the user can still be shown would lose a real reload report.
    assert.is_nil(f.last_noop["b"], "session b had no held-back no-effect to keep")
  end)
end)
