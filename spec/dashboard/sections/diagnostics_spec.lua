-- spec/dashboard/sections/diagnostics_spec.lua — Diagnostics section tests

describe("Diagnostics section", function()
  local diag, state_mod

  before_each(function()
    diag = require("sagefs.dashboard.sections.diagnostics")
    state_mod = require("sagefs.dashboard.state")
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.sections.diagnostics"] = nil
    package.loaded["sagefs.dashboard.state"] = nil
  end)

  it("conforms to section protocol", function()
    local section = require("sagefs.dashboard.section")
    assert.is_true(section.validate(diag))
    package.loaded["sagefs.dashboard.section"] = nil
  end)

  it("shows no diagnostics when empty", function()
    local s = state_mod.new()
    local out = diag.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("No diagnostics"))
  end)

  it("renders errors and warnings", function()
    local s = state_mod.new()
    s.diagnostics = {
      { severity = "error", message = "FS0039: undefined", file = "A.fs", line = 10 },
      { severity = "warning", message = "FS0040: shadow", file = "B.fs", line = 5 },
    }
    local out = diag.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("FS0039"))
    assert.truthy(joined:find("FS0040"))
    assert.truthy(joined:find("A.fs"))
  end)

  it("uses error highlight for errors", function()
    local s = state_mod.new()
    s.diagnostics = {
      { severity = "error", message = "bad", file = "X.fs", line = 1 },
    }
    local out = diag.render(s)
    local has_err = false
    for _, hl in ipairs(out.highlights) do
      if hl.hl_group == "SageFsDiagError" then has_err = true end
    end
    assert.is_true(has_err)
  end)

  it("truncates after 20 items", function()
    local s = state_mod.new()
    s.diagnostics = {}
    for i = 1, 25 do
      table.insert(s.diagnostics, {
        severity = "error", message = "err " .. i, file = "X.fs", line = i,
      })
    end
    local out = diag.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("and 5 more"))
  end)
end)
