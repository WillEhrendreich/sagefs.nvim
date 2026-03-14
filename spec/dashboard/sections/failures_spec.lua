-- spec/dashboard/sections/failures_spec.lua — Failures section tests

describe("Failures section", function()
  local failures, state_mod

  before_each(function()
    failures = require("sagefs.dashboard.sections.failures")
    state_mod = require("sagefs.dashboard.state")
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.sections.failures"] = nil
    package.loaded["sagefs.dashboard.state"] = nil
  end)

  it("conforms to section protocol", function()
    local section = require("sagefs.dashboard.section")
    assert.is_true(section.validate(failures))
    package.loaded["sagefs.dashboard.section"] = nil
  end)

  it("shows no failures when empty", function()
    local s = state_mod.new()
    local out = failures.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("No failures"))
  end)

  it("renders failure narratives", function()
    local s = state_mod.new()
    s = state_mod.update(s, "failure_narratives", {
      narratives = {
        { testName = "roundtrip", summary = "Expected 42 but got 0" },
        { testName = "parsing", summary = "Type mismatch" },
      },
    })
    local out = failures.render(s)
    assert.is_true(#out.lines >= 4)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("roundtrip"))
    assert.truthy(joined:find("parsing"))
    assert.truthy(joined:find("2 failure"))
  end)

  it("has jump_to_test keymaps", function()
    local s = state_mod.new()
    s = state_mod.update(s, "failure_narratives", {
      narratives = { { testName = "my_test", summary = "broke" } },
    })
    local out = failures.render(s)
    local found = false
    for _, km in ipairs(out.keymaps) do
      if km.action.type == "jump_to_test" and km.action.test_name == "my_test" then
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("truncates after 10 narratives", function()
    local s = state_mod.new()
    local many = {}
    for i = 1, 15 do
      table.insert(many, { testName = "test_" .. i, summary = "fail" })
    end
    s = state_mod.update(s, "failure_narratives", { narratives = many })
    local out = failures.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("and 5 more"))
  end)
end)
