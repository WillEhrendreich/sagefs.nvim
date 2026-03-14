-- spec/dashboard/sections/health_spec.lua — Health section tests

describe("Health section", function()
  local health, state_mod

  before_each(function()
    health = require("sagefs.dashboard.sections.health")
    state_mod = require("sagefs.dashboard.state")
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.sections.health"] = nil
    package.loaded["sagefs.dashboard.state"] = nil
  end)

  it("conforms to section protocol", function()
    local section = require("sagefs.dashboard.section")
    assert.is_true(section.validate(health))
    package.loaded["sagefs.dashboard.section"] = nil
  end)

  it("renders connected state", function()
    local s = state_mod.new()
    s = state_mod.update(s, "connected", {
      version = "0.6.163", uptime = "1h", memoryMb = 300, sessionCount = 2,
    })
    local out = health.render(s)
    assert.is_true(#out.lines >= 4)
    assert.truthy(out.lines[1]:find("Health"))
    assert.truthy(out.lines[2]:find("Connected"))
    -- Verify detail lines present
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("0.6.163"))
    assert.truthy(joined:find("300 MB"))
  end)

  it("renders disconnected state", function()
    local s = state_mod.new()
    local out = health.render(s)
    assert.truthy(out.lines[2]:find("Disconnected"))
  end)

  it("shows warmup indicator when warming up", function()
    local s = state_mod.new()
    s.warmup_context = { assemblies = 5 }
    local out = health.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("Warming up"))
  end)

  it("has correct section_id", function()
    local s = state_mod.new()
    local out = health.render(s)
    assert.equals("health", out.section_id)
  end)
end)
