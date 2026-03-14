-- Statusline component tests — pure function from state to string

describe("statusline", function()
  local statusline = require("sagefs.dashboard.statusline")
  local state_mod = require("sagefs.dashboard.state")

  it("returns empty string for nil state", function()
    assert.equals("", statusline.get(nil))
  end)

  it("shows disconnected icon when not connected", function()
    local s = state_mod.new()
    local result = statusline.get(s)
    assert.truthy(result:find("⏻"))
    -- Should NOT show testing info when disconnected
    assert.is_nil(result:find("✓"))
  end)

  it("shows connected icon when connected", function()
    local s = state_mod.new()
    s.daemon.connected = true
    local result = statusline.get(s)
    assert.truthy(result:find("⚡"))
  end)

  it("shows test counts when testing enabled with failures", function()
    local s = state_mod.new()
    s.daemon.connected = true
    s.testing.enabled = true
    s.testing.summary = { total = 100, passed = 95, failed = 5, stale = 0, running = 0 }

    local result = statusline.get(s)
    assert.truthy(result:find("✓95"))
    assert.truthy(result:find("✗5"))
  end)

  it("omits failure count when zero failures", function()
    local s = state_mod.new()
    s.daemon.connected = true
    s.testing.enabled = true
    s.testing.summary = { total = 50, passed = 50, failed = 0, stale = 0, running = 0 }

    local result = statusline.get(s)
    assert.truthy(result:find("✓50"))
    assert.is_nil(result:find("✗"))
  end)

  it("hides test counts when testing disabled", function()
    local s = state_mod.new()
    s.daemon.connected = true
    s.testing.enabled = false

    local result = statusline.get(s)
    assert.is_nil(result:find("✓"))
  end)

  it("shows hot reload indicator when enabled", function()
    local s = state_mod.new()
    s.daemon.connected = true
    s.hot_reload.enabled = true
    s.hot_reload.total_files = 42

    local result = statusline.get(s)
    assert.truthy(result:find("🔄42"))
  end)

  it("shows eval duration when present", function()
    local s = state_mod.new()
    s.daemon.connected = true
    s.eval.duration_ms = 123

    local result = statusline.get(s)
    assert.truthy(result:find("123ms"))
  end)

  it("composes all indicators together", function()
    local s = state_mod.new()
    s.daemon.connected = true
    s.testing.enabled = true
    s.testing.summary = { total = 10, passed = 8, failed = 2, stale = 0, running = 0 }
    s.hot_reload.enabled = true
    s.hot_reload.total_files = 5
    s.eval.duration_ms = 42

    local result = statusline.get(s)
    assert.truthy(result:find("⚡"))
    assert.truthy(result:find("✓8"))
    assert.truthy(result:find("✗2"))
    assert.truthy(result:find("🔄5"))
    assert.truthy(result:find("42ms"))
  end)
end)
