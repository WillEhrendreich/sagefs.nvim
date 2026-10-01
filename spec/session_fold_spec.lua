require("spec.helper")
local sessions = require("sagefs.sessions")

-- After :SageFsCreateSession the statusline stayed on "(Starting)" forever:
-- active_session is a snapshot of /api/sessions taken right after create, and
-- the daemon's `state {"sessionReady": <sid>}` event, which says the session
-- is Ready, was classified and then dropped (no handler). This is the pure
-- fold of such an event into the session list and the active session.

describe("sagefs.sessions.apply_update", function()
  local function fixture()
    local a = { id = "s1", name = "DemoEnv.Tests", status = "Starting", projects = { "DemoEnv.Tests.fsproj" } }
    local b = { id = "s2", name = "Other", status = "Starting", projects = { "Other.fsproj" } }
    return { a, b }, a
  end

  it("sets the status on the matching list entry and on the active session", function()
    local list, active = fixture()
    local new_list, new_active, found = sessions.apply_update(list, active, "s1", { status = "Ready" })
    assert.is_true(found)
    assert.equals("Ready", new_list[1].status)
    assert.equals("Ready", new_active.status)
    assert.equals("s1", new_active.id)
  end)

  it("leaves other sessions untouched", function()
    local list, active = fixture()
    local new_list = sessions.apply_update(list, active, "s1", { status = "Ready" })
    assert.equals("Starting", new_list[2].status)
  end)

  it("leaves the active session alone when the update is for another session", function()
    local list, active = fixture()
    local new_list, new_active = sessions.apply_update(list, active, "s2", { status = "Ready" })
    assert.equals("Ready", new_list[2].status)
    assert.equals("Starting", new_active.status)
  end)

  it("does not mutate its inputs", function()
    local list, active = fixture()
    sessions.apply_update(list, active, "s1", { status = "Ready" })
    assert.equals("Starting", list[1].status)
    assert.equals("Starting", active.status)
  end)

  it("reports found = false for an unknown session id, changing nothing", function()
    local list, active = fixture()
    local new_list, new_active, found = sessions.apply_update(list, active, "nope", { status = "Ready" })
    assert.is_false(found)
    assert.equals("Starting", new_list[1].status)
    assert.equals("Starting", new_active.status)
  end)

  it("handles a nil active session and a nil list", function()
    local list = fixture()
    local _, new_active = sessions.apply_update(list, nil, "s1", { status = "Ready" })
    assert.is_nil(new_active)
    local l, a, found = sessions.apply_update(nil, nil, "s1", { status = "Ready" })
    assert.same({}, l)
    assert.is_nil(a)
    assert.is_false(found)
  end)

  it("updates the active session even when it is not in the list yet", function()
    local active = { id = "s9", status = "Starting", projects = {} }
    local _, new_active, found = sessions.apply_update({}, active, "s9", { status = "Ready" })
    assert.is_true(found)
    assert.equals("Ready", new_active.status)
  end)

  it("merges health without dropping the status", function()
    local list, active = fixture()
    local _, new_active = sessions.apply_update(list, active, "s1",
      { health = { status = "Degraded", reason = "gc pressure" } })
    assert.equals("Starting", new_active.status)
    assert.equals("Degraded", new_active.health.status)
  end)

  it("makes the statusline stop saying Starting", function()
    local list, active = fixture()
    local _, new_active = sessions.apply_update(list, active, "s1", { status = "Ready" })
    local line = sessions.format_statusline(new_active, "connected")
    assert.is_truthy(line:find("(Ready)", 1, true))
    assert.is_nil(line:find("Starting", 1, true))
  end)
end)

describe("sagefs.sessions.lifecycle_update", function()
  it("reads a sessionReady state envelope", function()
    local sid, fields = sessions.lifecycle_update({ sessionReady = "s1" })
    assert.equals("s1", sid)
    assert.same({ status = "Ready" }, fields)
  end)

  it("reads a sessionFaulted state envelope", function()
    local sid, fields = sessions.lifecycle_update({ sessionFaulted = "s1", error = "boom" })
    assert.equals("s1", sid)
    assert.equals("Faulted", fields.status)
    assert.equals("boom", fields.fault_reason)
  end)

  it("reads a session_health_changed session event", function()
    local sid, fields = sessions.lifecycle_update({
      type = "session_health_changed", sessionId = "s1", health = { status = "Degraded", reason = "r" } })
    assert.equals("s1", sid)
    assert.equals("Degraded", fields.health.status)
    assert.equals("r", fields.health.reason)
  end)

  it("returns nil for anything else", function()
    assert.is_nil(sessions.lifecycle_update({ outputCount = 3 }))
    assert.is_nil(sessions.lifecycle_update(nil))
    assert.is_nil(sessions.lifecycle_update({ sessionReady = 5 }))
  end)
end)
