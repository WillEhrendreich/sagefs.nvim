-- status_fields: the one registry of per-session report fields the plugin reads
-- from /api/sessions (and get_session_status). A new closed field the daemon
-- adds is one entry here: its parser and its statusline segment. Nothing else in the plugin enumerates the fields.
require("spec.helper")
local status_fields = require("sagefs.status_fields")
local sessions = require("sagefs.sessions")
local reload_state = require("sagefs.reload_state")
local fx = require("spec.wire_fixtures")

local function raw_sessions() return vim.json.decode(fx.read("api-sessions.json")).sessions end

describe("status_fields.parse", function()
  it("reads lastReload and replFreshness from a real /api/sessions entry", function()
    local parsed = status_fields.parse(raw_sessions()[1])
    assert.are.equal("NeverEntered", parsed.last_reload.outcome)
    assert.are.equal("BehindApp", parsed.repl_freshness.state)
  end)

  it("omits a field the daemon did not send, so absence is never read as 'fine'", function()
    local parsed = status_fields.parse({ id = "x" })
    assert.is_nil(parsed.last_reload)
    assert.is_nil(parsed.repl_freshness)
  end)

  it("reads a null lastReload (a session nobody saved to) as absent", function()
    local parsed = status_fields.parse(raw_sessions()[2])
    assert.is_nil(parsed.last_reload)
    assert.are.equal("InSync", parsed.repl_freshness.state)
  end)
end)

describe("status_fields.segments", function()
  it("shows the REPL-behind warning, and prefers the event-fed reload report over the polled one", function()
    local session = status_fields.parse(raw_sessions()[1])
    session.id = "adfd6b6b"
    local model = select(1, reload_state.apply_sse(reload_state.model_new(), {
      sessionId = "adfd6b6b",
      reloadReported = { state = "finished", outcome = "PatchPending", mechanism = "metadata-delta", patched = 0, considered = 1, message = "m" },
    }, 1000))
    local segs = status_fields.segments(session, { reload_model = model, now_ms = 1500 })
    assert.are.equal("HR ◐ applied, not run yet [delta]", segs[1])
    assert.are.equal("⚠ REPL BEHIND app (1 save)", segs[2])
  end)

  it("falls back to the polled lastReload when no event has spoken", function()
    local session = status_fields.parse(raw_sessions()[1])
    session.id = "adfd6b6b"
    session.last_reload = reload_state.parse({ state = "finished", outcome = "RestartRequired", patched = 0, considered = 1, message = "Restart needed: x" })
    local segs = status_fields.segments(session, { reload_model = reload_state.model_new() })
    assert.are.equal("HR ↻ restart needed", segs[1])
  end)

  it("lets a settled, harmless verdict fade out of the statusline instead of sitting there", function()
    local session = status_fields.parse(raw_sessions()[1])
    session.id = "adfd6b6b"
    local model = select(1, reload_state.apply_sse(reload_state.model_new(), {
      sessionId = "adfd6b6b",
      reloadReported = { state = "finished", outcome = "Patched", mechanism = "detour", patched = 1, considered = 1, message = "m" },
    }, 1000))
    local fresh = status_fields.segments(session, { reload_model = model, now_ms = 2000 })
    assert.are.equal("HR ● patched (ran) [detour]", fresh[1])
    local later = status_fields.segments(session, { reload_model = model, now_ms = 1000 + 15001 })
    assert.are_not.equal("HR ● patched (ran) [detour]", later[1])
    assert.are.equal("⚠ REPL BEHIND app (1 save)", later[1])
  end)

  it("is empty for a quiet in-sync session with no reload", function()
    local session = status_fields.parse(raw_sessions()[2])
    session.id = "1626ed8c"
    assert.are.same({}, status_fields.segments(session, { reload_model = reload_state.model_new() }))
  end)

  it("is empty with no session", function()
    assert.are.same({}, status_fields.segments(nil, { reload_model = reload_state.model_new() }))
  end)
end)

describe("status_fields.register: a new closed field is one entry", function()
  local original

  before_each(function()
    original = status_fields.snapshot()
  end)

  after_each(function()
    status_fields.restore(original)
  end)

  it("a field added in one place is parsed, shown, and read back by name", function()
    status_fields.register({
      json = "nextField",
      key = "next_field",
      parse = function(v)
        if type(v) ~= "table" or type(v.state) ~= "string" then return nil end
        return { state = v.state }
      end,
      segment = function(value)
        if value and value.state == "StaleEdited" then return "⚠ source edited since the run" end
        return ""
      end,
    })
    local parsed = status_fields.parse({ id = "x", nextField = { state = "StaleEdited" } })
    assert.are.equal("StaleEdited", parsed.next_field.state)
    local segs = status_fields.segments(parsed, { reload_model = reload_state.model_new() })
    assert.are.same({ "⚠ source edited since the run" }, segs)
  end)

  it("sessions.parse_sessions_response carries the new field through without touching sessions.lua", function()
    status_fields.register({
      json = "nextField", key = "next_field",
      parse = function(v) return type(v) == "table" and { state = v.state } or nil end,
      segment = function() return "" end,
    })
    local json = '{"sessions":[{"id":"s1","status":"Ready","nextField":{"state":"Fresh"}}]}'
    local result = sessions.parse_sessions_response(json)
    assert.is_true(result.ok)
    assert.are.equal("Fresh", result.sessions[1].next_field.state)
  end)

  it("refuses to register a field twice under one key", function()
    assert.has_error(function()
      status_fields.register({ json = "other", key = "repl_freshness", parse = function() end, segment = function() return "" end })
    end)
  end)
end)

describe("sessions.parse_sessions_response carries the report fields", function()
  it("keeps lastReload and replFreshness on each normalized session", function()
    local result = sessions.parse_sessions_response(fx.read("api-sessions.json"))
    assert.is_true(result.ok)
    assert.are.equal("BehindApp", result.sessions[1].repl_freshness.state)
    assert.are.equal("NeverEntered", result.sessions[1].last_reload.outcome)
    assert.are.equal("InSync", result.sessions[2].repl_freshness.state)
  end)
end)
