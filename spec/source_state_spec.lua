-- Source state: is the build this session runs behind the files on disk? A green
-- test over a stale build is not green. Shapes are the ones SourceState.toWire writes
-- (SageFs.Core/Features/SourceState.fs, SageFs master 282f4981); the 0.6.875 daemon
-- that is running does not send the field yet, so absence must stay quiet.
-- Fixture: spec/fixtures/wire/api-sessions-source-state.json.
require("spec.helper")
local S = require("sagefs.source_state")
local status_fields = require("sagefs.status_fields")
local sessions = require("sagefs.sessions")
local fx = require("spec.wire_fixtures")

local function raw() return vim.json.decode(fx.read("api-sessions-source-state.json")).sessions end

describe("source_state closed set", function()
  it("has the four states the daemon names", function()
    assert.are.same({ "InSync", "Stale", "Rebuilding", "Unknown" }, S.STATE.all)
  end)
end)

describe("source_state.parse", function()
  it("reads InSync with what the daemon compared", function()
    local f = S.parse(raw()[1].sourceState)
    assert.are.equal("InSync", f.state)
    assert.is_true(f.known)
    assert.are.equal(14, f.files_checked)
    assert.is_false(S.is_stale(f))
  end)

  it("reads Stale with the files that changed and why", function()
    local f = S.parse(raw()[2].sourceState)
    assert.are.equal("Stale", f.state)
    assert.is_true(S.is_stale(f))
    assert.are.equal(2, #f.changed)
    assert.are.equal("/w/demoenv2/DemoEnv/DemoEnv.fs", f.changed[1].path)
    assert.are.equal("EditedAfterBuild", f.changed[1].because)
    assert.truthy(f.changed[1].detail:find("edited 2026-10-02 08:05:00Z", 1, true))
    assert.truthy(f.message:find("STALE SOURCE", 1, true))
  end)

  it("reads Rebuilding with when it started", function()
    local f = S.parse(raw()[3].sourceState)
    assert.are.equal("Rebuilding", f.state)
    assert.are.equal("2026-10-02T08:10:00Z", f.since)
  end)

  it("reads Unknown with the reason kind and detail", function()
    local f = S.parse(raw()[4].sourceState)
    assert.are.equal("Unknown", f.state)
    assert.are.equal("LoadTimeNotReported", f.reason.kind)
    assert.truthy(f.reason.detail:find("did not report when it loaded", 1, true))
  end)

  it("returns nil when the daemon sent nothing, so an older daemon is never read as in sync", function()
    assert.is_nil(S.parse(nil))
    assert.is_nil(S.parse(vim.NIL))
    assert.is_nil(S.parse("InSync"))
    assert.is_nil(S.parse({}))
  end)

  it("keeps a state outside the closed set, marked unknown to the plugin", function()
    local f = S.parse({ state = "Sideways" })
    assert.are.equal("Sideways", f.state)
    assert.is_false(f.known)
    assert.is_false(S.is_stale(f))
  end)

  it("survives a Stale object with no file list, and a file entry that is not a table", function()
    local f = S.parse({ state = "Stale", changedFiles = { "x", { path = "/a.fs" } } })
    assert.are.equal(1, #f.changed)
    assert.are.equal("/a.fs", f.changed[1].path)
    assert.are.equal(0, #S.parse({ state = "Stale" }).changed)
  end)
end)

describe("source_state.segment (statusline)", function()
  it("is empty when in sync", function()
    assert.are.equal("", S.segment(S.parse(raw()[1].sourceState)))
  end)

  it("is empty for a daemon that sent nothing", function()
    assert.are.equal("", S.segment(nil))
  end)

  it("says STALE SOURCE with how many files", function()
    assert.are.equal("⚠ STALE SOURCE (2 files)", S.segment(S.parse(raw()[2].sourceState)))
    assert.are.equal("⚠ STALE SOURCE (1 file)",
      S.segment(S.parse({ state = "Stale", changedFiles = { { path = "/a.fs", because = "EditedAfterBuild" } } })))
  end)

  it("says STALE SOURCE without a count when the daemon named no file", function()
    assert.are.equal("⚠ STALE SOURCE", S.segment(S.parse({ state = "Stale" })))
  end)

  it("says a rebuild is running", function()
    assert.are.equal("⟳ rebuilding", S.segment(S.parse(raw()[3].sourceState)))
  end)

  it("says the source could not be checked when the daemon could not tell", function()
    assert.are.equal("source ?", S.segment(S.parse(raw()[4].sourceState)))
  end)

  it("stays quiet for a session with no project, and for a daemon that never looked", function()
    assert.are.equal("", S.segment(S.parse(raw()[5].sourceState)))
    assert.are.equal("", S.segment(S.parse({ state = "Unknown", reason = { kind = "NotAssessed", detail = "x" } })))
  end)

  it("names a state it does not know instead of dropping it", function()
    assert.are.equal("source: Sideways?", S.segment(S.parse({ state = "Sideways" })))
  end)
end)

describe("source_state.lines (panels)", function()
  local function texts(lines)
    local out = {}
    for _, l in ipairs(lines) do table.insert(out, l.text) end
    return out
  end

  it("is empty with no report", function()
    assert.are.same({}, S.lines(nil))
  end)

  it("says a stale build runs code the files no longer say, names the files and the remedy", function()
    local t = texts(S.lines(S.parse(raw()[2].sourceState)))
    assert.truthy(t[1]:find("STALE SOURCE", 1, true))
    assert.truthy(t[1]:find("2 files changed on disk after the build", 1, true))
    assert.truthy(t[2]:find("/w/demoenv2/DemoEnv/DemoEnv.fs", 1, true))
    assert.truthy(t[3]:find("/w/demoenv2/DemoEnv.Tests/DemoEnvTests.fs", 1, true))
    assert.truthy(t[#t]:find(":SageFsHardReset", 1, true))
  end)

  it("names at most five files, then how many more", function()
    local changed = {}
    for i = 1, 8 do changed[i] = { path = "/f" .. i .. ".fs", because = "EditedAfterBuild" } end
    local t = texts(S.lines(S.parse({ state = "Stale", changedFiles = changed })))
    assert.truthy(t[1]:find("8 files changed", 1, true))
    assert.truthy(t[7]:find("and 3 more", 1, true))
  end)

  it("uses the daemon's words for a rebuild in progress", function()
    local t = texts(S.lines(S.parse(raw()[3].sourceState)))
    assert.truthy(t[1]:find("A rebuild is in progress", 1, true))
  end)

  it("says why the source could not be checked", function()
    local t = texts(S.lines(S.parse(raw()[4].sourceState)))
    assert.truthy(t[1]:find("could not be checked", 1, true))
    assert.truthy(t[1]:find("did not report when it loaded", 1, true))
  end)

  it("says in sync in one quiet line", function()
    local lines = S.lines(S.parse(raw()[1].sourceState))
    assert.are.equal(1, #lines)
    assert.truthy(lines[1].text:find("in sync with the build", 1, true))
    assert.are.equal("SageFsReplInSync", lines[1].hl)
  end)

  it("is quiet for no project and for never looked", function()
    assert.are.same({}, S.lines(S.parse(raw()[5].sourceState)))
  end)
end)

describe("source_state.status_text (:SageFsStatus)", function()
  it("is nil when there is nothing to say", function()
    assert.is_nil(S.status_text(nil))
    assert.is_nil(S.status_text(S.parse(raw()[5].sourceState)))
  end)

  it("is one line per state", function()
    assert.are.equal("in sync with the build", S.status_text(S.parse(raw()[1].sourceState)))
    assert.are.equal("STALE: 2 files changed on disk after the build", S.status_text(S.parse(raw()[2].sourceState)))
    assert.are.equal("rebuilding, the old build still serves", S.status_text(S.parse(raw()[3].sourceState)))
    assert.truthy(S.status_text(S.parse(raw()[4].sourceState)):find("could not be checked", 1, true))
  end)
end)

describe("source_state in the session report", function()
  it("is registered in status_fields, after replFreshness", function()
    local parsed = status_fields.parse(raw()[2])
    assert.are.equal("Stale", parsed.source_state.state)
    assert.are.equal("InSync", parsed.repl_freshness.state)
  end)

  it("reaches the normalized session", function()
    local result = sessions.parse_sessions_response(fx.read("api-sessions-source-state.json"))
    assert.is_true(result.ok)
    assert.are.equal("InSync", result.sessions[1].source_state.state)
    assert.are.equal("Stale", result.sessions[2].source_state.state)
    assert.are.equal("Rebuilding", result.sessions[3].source_state.state)
  end)

  it("shows in the statusline segments next to replFreshness", function()
    local s = status_fields.parse(raw()[2])
    s.id = "aa000002"
    s.repl_freshness = { state = "BehindApp", known = true, saves_since = 1, declarations = {} }
    local segs = status_fields.segments(s, { reload_model = nil, now_ms = 0 })
    assert.are.same({ "⚠ REPL BEHIND app (1 save)", "⚠ STALE SOURCE (2 files)" }, segs)
  end)

  it("adds nothing for a session list from a daemon that does not send the field", function()
    local result = sessions.parse_sessions_response('{"sessions":[{"id":"x","status":"Ready","projects":[],"replFreshness":{"state":"InSync"}}]}')
    assert.is_nil(result.sessions[1].source_state)
    assert.are.same({}, status_fields.segments(result.sessions[1], { now_ms = 0 }))
  end)
end)
