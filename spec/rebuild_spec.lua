-- Rebuild: what the daemon says the last hard reset did. POST /hard-reset with
-- rebuild=true answers at once ("Hard reset initiated ...") and builds in the
-- background; the outcome is `lastRestart` on /api/sessions:
--   {outcome:"InProgress"|"Succeeded"|"FailedStillServing"|"FailedNotServing", message}
-- (SessionStatusPayload.lastRestartJson). The plugin used to say "Hard reset complete"
-- the moment the daemon said "initiated", and a failed build said nothing at all.
require("spec.helper")
local R = require("sagefs.rebuild")
local sessions = require("sagefs.sessions")
local status_fields = require("sagefs.status_fields")
local fx = require("spec.wire_fixtures")

local LEVELS = vim.log.levels

local function restart(outcome, message)
  return R.parse({ outcome = outcome, message = message or (outcome .. " words") })
end

describe("rebuild closed set", function()
  it("has the four outcomes the daemon names", function()
    assert.are.same({ "InProgress", "Succeeded", "FailedStillServing", "FailedNotServing" }, R.OUTCOME.all)
  end)
end)

describe("rebuild.parse", function()
  it("reads the real lastRestart object from /api/sessions", function()
    local raw = vim.json.decode(fx.read("api-sessions.json")).sessions
    local f = R.parse(raw[1].lastRestart)
    assert.are.equal("Succeeded", f.outcome)
    assert.is_true(f.known)
    assert.truthy(f.message:find("Last rebuild succeeded", 1, true))
  end)

  it("returns nil when the session was never rebuilt (null) or the daemon sent nothing", function()
    assert.is_nil(R.parse(nil))
    assert.is_nil(R.parse(vim.NIL))
    assert.is_nil(R.parse("Succeeded"))
    assert.is_nil(R.parse({ message = "no outcome" }))
  end)

  it("keeps an outcome outside the closed set, marked unknown to the plugin", function()
    local f = R.parse({ outcome = "Sideways", message = "m" })
    assert.are.equal("Sideways", f.outcome)
    assert.is_false(f.known)
  end)
end)

describe("rebuild.segment (statusline)", function()
  it("says a rebuild is running", function()
    assert.are.equal("⟳ rebuilding", R.segment(restart("InProgress")))
  end)

  it("does not say it twice when sourceState already says Rebuilding", function()
    assert.are.equal("", R.segment(restart("InProgress"), { state = "Rebuilding", known = true }))
  end)

  it("is quiet after a rebuild that worked", function()
    assert.are.equal("", R.segment(restart("Succeeded")))
  end)

  it("says a failed rebuild left the old build serving", function()
    assert.are.equal("⚠ rebuild FAILED (old build still serves)", R.segment(restart("FailedStillServing")))
  end)

  it("says a failed rebuild left no worker", function()
    assert.are.equal("✖ rebuild FAILED (no worker)", R.segment(restart("FailedNotServing")))
  end)

  it("is empty with no record, and names an outcome it does not know", function()
    assert.are.equal("", R.segment(nil))
    assert.are.equal("rebuild: Sideways?", R.segment(R.parse({ outcome = "Sideways" })))
  end)
end)

describe("rebuild.started_in_background", function()
  it("is true for the answer the daemon gives while the build runs on", function()
    assert.is_true(R.started_in_background({ success = true,
      message = "Hard reset initiated — building first; the current worker keeps serving until the new build is ready. Call get_session_status ..." }))
  end)

  it("is false for a daemon that answered after the work was done, and for nonsense", function()
    assert.is_false(R.started_in_background({ success = true, message = "Hard reset complete. Rebuilt and reloaded." }))
    assert.is_false(R.started_in_background(nil))
    assert.is_false(R.started_in_background({}))
  end)
end)

describe("rebuild.started_message", function()
  it("says what happens next, in editor words", function()
    local m = R.started_message()
    assert.truthy(m:find("Hard reset started", 1, true))
    assert.truthy(m:find("current worker keeps serving", 1, true))
    assert.is_nil(m:find("get_session_status", 1, true))
  end)
end)

describe("rebuild.follow_step", function()
  it("keeps waiting while the rebuild runs, then says it finished", function()
    local f = R.follow_new(nil)
    local result
    f, result = R.follow_step(f, restart("InProgress"))
    assert.is_nil(result)
    f, result = R.follow_step(f, restart("Succeeded", "ok"))
    assert.are.equal("Succeeded", result.outcome)
    assert.are.equal(LEVELS.INFO, result.level)
    assert.truthy(result.text:find("Rebuild finished", 1, true))
  end)

  it("does not mistake the record of an earlier rebuild for this one", function()
    local before = restart("Succeeded", "Last rebuild succeeded at 10:00:00")
    local f = R.follow_new(before)
    local result
    f, result = R.follow_step(f, restart("Succeeded", "Last rebuild succeeded at 10:00:00"))
    assert.is_nil(result)
  end)

  it("sees a rebuild that finished before the first look, because the record changed", function()
    local before = restart("Succeeded", "Last rebuild succeeded at 10:00:00")
    local f = R.follow_new(before)
    local _, result = R.follow_step(f, restart("Succeeded", "Last rebuild succeeded at 10:02:11"))
    assert.are.equal("Succeeded", result.outcome)
  end)

  it("says a failed build as an error with the daemon's words, and that the old build serves", function()
    local f = R.follow_new(nil)
    local _, result = R.follow_step(f, restart("FailedStillServing", "Last rebuild failed at 10:00:00 - still serving the previous build.\nerror FS0039: x is not defined"))
    assert.are.equal(LEVELS.ERROR, result.level)
    assert.truthy(result.text:find("Rebuild FAILED", 1, true))
    assert.truthy(result.text:find("error FS0039: x is not defined", 1, true))
  end)

  it("says a failed build with no worker as an error", function()
    local f = R.follow_new(nil)
    local _, result = R.follow_step(f, restart("FailedNotServing", "no worker is serving this session.\nboom"))
    assert.are.equal(LEVELS.ERROR, result.level)
    assert.truthy(result.text:find("boom", 1, true))
  end)

  it("gives up with a warning after the poll limit, naming where to look", function()
    local f = R.follow_new(nil)
    local result
    for _ = 1, R.MAX_POLLS do f, result = R.follow_step(f, nil) end
    assert.are.equal(LEVELS.WARN, result.level)
    assert.truthy(result.text:find(":SageFsStatus", 1, true))
  end)
end)

describe("lastRestart in the session report", function()
  it("is registered in status_fields and reaches the normalized session", function()
    local parsed = status_fields.parse({ id = "x", lastRestart = { outcome = "FailedStillServing", message = "m" } })
    assert.are.equal("FailedStillServing", parsed.last_restart.outcome)
    local result = sessions.parse_sessions_response(fx.read("api-sessions.json"))
    assert.are.equal("Succeeded", result.sessions[1].last_restart.outcome)
  end)

  it("shows a failed rebuild in the statusline segments", function()
    local s = status_fields.parse({ id = "x", lastRestart = { outcome = "FailedStillServing", message = "m" } })
    assert.are.same({ "⚠ rebuild FAILED (old build still serves)" }, status_fields.segments(s, { now_ms = 0 }))
  end)

  it("shows one word for a running rebuild even when sourceState says it too", function()
    local s = status_fields.parse({ id = "x",
      lastRestart = { outcome = "InProgress", message = "m" },
      sourceState = { state = "Rebuilding", since = "2026-10-02T08:10:00Z" } })
    assert.are.same({ "⟳ rebuilding" }, status_fields.segments(s, { now_ms = 0 }))
  end)

  it("adds nothing for a daemon that sent no lastRestart", function()
    local s = status_fields.parse({ id = "x" })
    assert.is_nil(s.last_restart)
    assert.are.same({}, status_fields.segments(s, { now_ms = 0 }))
  end)
end)
