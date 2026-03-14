-- spec/dashboard/sections/tests_spec.lua — Tests section tests

describe("Tests section", function()
  local tests_section, state_mod

  before_each(function()
    tests_section = require("sagefs.dashboard.sections.tests")
    state_mod = require("sagefs.dashboard.state")
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.sections.tests"] = nil
    package.loaded["sagefs.dashboard.state"] = nil
  end)

  it("conforms to section protocol", function()
    local section = require("sagefs.dashboard.section")
    assert.is_true(section.validate(tests_section))
    package.loaded["sagefs.dashboard.section"] = nil
  end)

  it("shows OFF when testing disabled", function()
    local s = state_mod.new()
    local out = tests_section.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("OFF"))
    assert.truthy(joined:find("No tests discovered"))
  end)

  it("shows ON and summary when testing enabled with results", function()
    local s = state_mod.new()
    s = state_mod.update(s, "test_state", { enabled = true })
    s = state_mod.update(s, "test_summary", {
      total = 100, passed = 95, failed = 5, stale = 0, running = 0,
    })
    local out = tests_section.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("ON"))
    assert.truthy(joined:find("100 tests"))
    assert.truthy(joined:find("95"))
    assert.truthy(joined:find("5"))
  end)

  it("has enable/disable keymaps", function()
    local s = state_mod.new()
    local out = tests_section.render(s)
    local has_enable, has_disable = false, false
    for _, km in ipairs(out.keymaps) do
      if km.action.type == "enable_testing" then has_enable = true end
      if km.action.type == "disable_testing" then has_disable = true end
    end
    assert.is_true(has_enable)
    assert.is_true(has_disable)
  end)

  it("has run_tests keymap", function()
    local s = state_mod.new()
    local out = tests_section.render(s)
    local has_run = false
    for _, km in ipairs(out.keymaps) do
      if km.action.type == "run_tests" then has_run = true end
    end
    assert.is_true(has_run)
  end)
end)
