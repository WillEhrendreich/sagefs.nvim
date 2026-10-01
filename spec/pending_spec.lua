require("spec.helper")
local pending = require("sagefs.pending")
local config = require("sagefs.config")

-- "Why is nothing happening": once an eval has been out longer than a bound
-- with no result, the plugin names the real reason from the model's own state
-- instead of leaving a blank screen (the lemmings burned every turn waiting).

local function info(overrides)
  local base = {
    elapsed_ms = 6000,
    connection = "connected",
    daemon_reachable = true,
    port = 37749,
    session = { id = "ab12cd34", name = "DemoEnv", status = "Ready" },
    warmup = nil,
  }
  for k, v in pairs(overrides or {}) do base[k] = v end
  if base.session == false then base.session = nil end -- `false` means "no session" (nil would drop the override)
  if base.daemon_reachable == "unprobed" then base.daemon_reachable = nil end -- no fresh probe yet
  return base
end

describe("sagefs.config pending bound", function()
  it("names the bound as a constant a user and a spec can both read", function()
    assert.is_number(config.EVAL_SLOW_AFTER_MS)
    assert.is_true(config.EVAL_SLOW_AFTER_MS >= 1000 and config.EVAL_SLOW_AFTER_MS <= 15000)
    assert.is_number(config.EVAL_STATUS_POLL_MS)
  end)
end)

describe("sagefs.pending.classify", function()
  it("says the daemon is unreachable when a fresh probe failed", function()
    local c = pending.classify(info({ daemon_reachable = false }))
    assert.are.equal("daemon_unreachable", c.kind)
    assert.is_truthy(c.long:find("37749", 1, true))
    assert.is_truthy(c.long:find(":SageFsStart", 1, true))
    assert.are.equal("error", c.level)
  end)

  it("says the daemon is unreachable when the event stream is disconnected", function()
    local c = pending.classify(info({ connection = "disconnected", daemon_reachable = "unprobed" }))
    assert.are.equal("daemon_unreachable", c.kind)
  end)

  it("trusts a fresh successful probe over a dropped event stream (the answer comes over HTTP)", function()
    local c = pending.classify(info({ connection = "disconnected", daemon_reachable = true }))
    assert.are.equal("evaluating", c.kind)
  end)

  it("says it is reconnecting while the event stream retries", function()
    local c = pending.classify(info({ connection = "reconnecting", daemon_reachable = "unprobed" }))
    assert.are.equal("daemon_reconnecting", c.kind)
  end)

  it("says there is no session when nothing is attached", function()
    local c = pending.classify(info({ session = false }))
    assert.are.equal("no_session", c.kind)
    assert.is_truthy(c.long:find(":SageFsCreateSession", 1, true))
  end)

  it("names the fault when the session faulted", function()
    local c = pending.classify(info({ session = { id = "ab12cd34", name = "DemoEnv", status = "Faulted", fault_reason = "runtime 99 missing" } }))
    assert.are.equal("session_faulted", c.kind)
    assert.is_truthy(c.long:find("runtime 99 missing", 1, true))
    assert.are.equal("error", c.level)
  end)

  for _, status in ipairs({ "Starting", "Building", "Restarting", "WarmingUp" }) do
    it("says the session is still warming up when its status is " .. status, function()
      local c = pending.classify(info({ session = { id = "ab12cd34", name = "DemoEnv", status = status } }))
      assert.are.equal("session_warming", c.kind)
      assert.is_truthy(c.long:find("DemoEnv", 1, true))
      assert.is_truthy(c.long:find(status, 1, true))
    end)
  end

  it("includes the warmup phase and step when the daemon is reporting them", function()
    local c = pending.classify(info({
      session = { id = "ab12cd34", name = "DemoEnv", status = "WarmingUp" },
      warmup = { phase = "loading_assemblies", step = 3, total = 10 },
    }))
    assert.are.equal("session_warming", c.kind)
    assert.is_truthy(c.short:find("loading assemblies", 1, true))
  end)

  it("says the eval is running, with how long, when the session is Ready", function()
    local c = pending.classify(info({ elapsed_ms = 12000 }))
    assert.are.equal("evaluating", c.kind)
    assert.is_truthy(c.short:find("12s", 1, true))
    assert.is_truthy(c.long:find("DemoEnv", 1, true))
    assert.is_truthy(c.long:find(":SageFsCancel", 1, true))
    assert.are.equal("info", c.level)
  end)

  it("keeps the inline form short enough to sit at the end of a code line", function()
    for _, i in ipairs({
      info({ daemon_reachable = false }), info({ session = false }), info({}),
      info({ session = { id = "x", name = "X", status = "Faulted", fault_reason = string.rep("long reason ", 20) } }),
    }) do
      assert.is_true(#pending.classify(i).short <= 60, pending.classify(i).short)
    end
  end)

  it("prefers the unreachable daemon over everything else", function()
    local c = pending.classify(info({
      daemon_reachable = false,
      session = { id = "x", name = "X", status = "Faulted", fault_reason = "r" },
    }))
    assert.are.equal("daemon_unreachable", c.kind)
  end)
end)
