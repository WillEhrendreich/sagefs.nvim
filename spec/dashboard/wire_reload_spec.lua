-- The dashboard's hot reload section and statusline show the reload truth and the
-- REPL-behind state, fed by the same pure folds as the plugin statusline.
require("spec.helper")
local state_mod = require("sagefs.dashboard.state")
local hot_reload = require("sagefs.dashboard.sections.hot_reload")
local statusline = require("sagefs.dashboard.statusline")
local event_index = require("sagefs.dashboard.event_index")

local function reload_event(outcome, extra)
  local r = { state = "finished", outcome = outcome, patched = 0, considered = 1, message = "m", mechanism = "" }
  for k, v in pairs(extra or {}) do r[k] = v end
  return { sessionId = "adfd6b6b", reloadReported = r }
end

local function text_of(out) return table.concat(out.lines, "\n") end

describe("dashboard state: reload_reported", function()
  it("is a handled event", function()
    local handled = {}
    for _, e in ipairs(state_mod.handled_events()) do handled[e] = true end
    assert.is_true(handled.reload_reported)
    assert.is_true(handled.repl_freshness_changed)
  end)

  it("keeps the latest report", function()
    local s = state_mod.new()
    s = state_mod.update(s, "reload_reported", reload_event("PatchPending", { mechanism = "metadata-delta" }))
    local out = hot_reload.render(s)
    assert.truthy(text_of(out):find("applied, new body has not run yet", 1, true))
    assert.truthy(text_of(out):find("via metadata delta", 1, true))
    s = state_mod.update(s, "reload_reported", reload_event("Patched", { mechanism = "metadata-delta", patched = 1 }))
    assert.truthy(text_of(hot_reload.render(s)):find("patched (ran)", 1, true))
  end)
end)

describe("hot reload section", function()
  it("subscribes to the new events so a report redraws it", function()
    local idx = event_index.build({ hot_reload })
    assert.are.same({ "hot_reload" }, event_index.lookup(idx, "reload_reported"))
    assert.are.same({ "hot_reload" }, event_index.lookup(idx, "repl_freshness_changed"))
  end)

  it("colours the truth line by severity", function()
    local s = state_mod.update(state_mod.new(), "reload_reported", reload_event("RestartRequired", { message = "Restart needed: x" }))
    local out = hot_reload.render(s)
    local found = false
    for _, h in ipairs(out.highlights) do
      if h.hl_group == "SageFsReloadError" then found = true end
    end
    assert.is_true(found)
  end)

  it("says a restart is needed with its cause", function()
    local s = state_mod.update(state_mod.new(), "reload_reported", reload_event("RestartRequired", { message = "Restart needed: the signature of A.f changed" }))
    assert.truthy(text_of(hot_reload.render(s)):find("restart needed: the signature of A.f changed", 1, true))
  end)

  it("shows the REPL-behind state with its remedy", function()
    local s = state_mod.new()
    s = state_mod.update(s, "repl_freshness_changed", {
      sessionId = "adfd6b6b",
      freshness = { state = "BehindApp", known = true, saves_since = 2, declarations = { "A.f", "B.g" }, message = "daemon words" },
    })
    local text = text_of(hot_reload.render(s))
    assert.truthy(text:find("REPL is BEHIND the app", 1, true))
    assert.truthy(text:find(":SageFsHardReset", 1, true))
  end)

  it("keeps the old toggle and file count", function()
    local s = state_mod.update(state_mod.new(), "hotreload_snapshot", { enabled = true, files = { "A.fs" }, totalFiles = 3 })
    local out = hot_reload.render(s)
    assert.truthy(text_of(out):find("1 / 3", 1, true))
    assert.are.equal("h", out.keymaps[1].key)
  end)
end)

describe("dashboard statusline", function()
  it("carries the reload segment and the REPL-behind segment", function()
    local s = state_mod.update(state_mod.new(), "connected", {})
    s = state_mod.update(s, "reload_reported", reload_event("PatchPending", { mechanism = "metadata-delta" }))
    s = state_mod.update(s, "repl_freshness_changed", {
      sessionId = "adfd6b6b",
      freshness = { state = "BehindApp", known = true, saves_since = 1, declarations = { "A.f" }, message = "m" },
    })
    local line = statusline.get(s)
    assert.truthy(line:find("HR ◐ applied, not run yet [delta]", 1, true))
    assert.truthy(line:find("REPL BEHIND app (1 save)", 1, true))
  end)

  it("is unchanged when there is nothing to say", function()
    local s = state_mod.update(state_mod.new(), "connected", {})
    assert.are.equal("⚡", statusline.get(s))
  end)
end)
