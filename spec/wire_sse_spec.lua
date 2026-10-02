-- The `state` envelope's ReloadReported variant, which the plugin dropped on the
-- floor (it fell through to the keepalive branch), and the event catalog entries
-- the dashboard and user autocmds hang off.
require("spec.helper")
local sse = require("sagefs.sse")
local events = require("sagefs.events")

describe("sse.classify_state_event: ReloadReported", function()
  it("a frame carrying reloadReported is a reload report", function()
    local frame = '{"reloadReported":{"considered":1,"mechanism":"metadata-delta","message":"m","outcome":"PatchPending","patched":0,"state":"finished","suggestedAction":"s"},"sessionId":"adfd6b6b"}'
    assert.are.equal("reload_reported", sse.classify_state_event(vim.json.decode(frame)))
  end)

  it("a compiling frame is a reload report too", function()
    assert.are.equal("reload_reported",
      sse.classify_state_event({ reloadReported = { file = "Program.fs", state = "compiling" }, sessionId = "s" }))
  end)

  it("a frame with only a sessionId is the report being cleared (SessionReload.NoReloadYet is sent without the field)", function()
    assert.are.equal("reload_reported", sse.classify_state_event({ sessionId = "0a000001" }))
  end)

  it("does not take other variants that carry a sessionId for a reload", function()
    assert.are.equal("hot_reload_changed", sse.classify_state_event({ hotReloadChanged = true, sessionId = "s" }))
    assert.are.equal("file_reloaded", sse.classify_state_event({ fileReloaded = "a.fs", sessionId = "s" }))
    assert.are.equal("warmup_progress", sse.classify_state_event({ warmupProgress = true, sessionId = "s", step = 1, total = 4 }))
    assert.are.equal("session_ready", sse.classify_state_event({ sessionReady = "s" }))
  end)

  it("still treats a bare keepalive as no state", function()
    assert.are.equal("state_update", sse.classify_state_event({ sessionProgress = true }))
  end)
end)

describe("events catalog", function()
  it("fires a user autocmd for a reload report", function()
    local evt = events.build_autocmd_data("reload_reported", { sessionId = "s" })
    assert.are.equal("SageFsReloadReported", evt.pattern)
    assert.are.equal("s", evt.data.sessionId)
  end)

  it("lists the new patterns in EVENT_NAMES", function()
    local names = {}
    for _, n in ipairs(events.EVENT_NAMES) do names[n] = true end
    for _, p in ipairs({ "SageFsReloadReported", "SageFsCohortMatrix", "SageFsClaimChanged", "SageFsLandingChanged", "SageFsSaveObserved", "SageFsCohortChanged" }) do
      assert.is_true(names[p], p)
    end
  end)
end)
