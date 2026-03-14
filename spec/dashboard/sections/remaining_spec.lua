-- spec/dashboard/sections/remaining_spec.lua — Tests for output, bindings, coverage, filmstrip, alarms

describe("Output section", function()
  local output_section, state_mod

  before_each(function()
    output_section = require("sagefs.dashboard.sections.output")
    state_mod = require("sagefs.dashboard.state")
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.sections.output"] = nil
    package.loaded["sagefs.dashboard.state"] = nil
  end)

  it("conforms to section protocol", function()
    local section = require("sagefs.dashboard.section")
    assert.is_true(section.validate(output_section))
    package.loaded["sagefs.dashboard.section"] = nil
  end)

  it("shows placeholder when no output", function()
    local s = state_mod.new()
    local out = output_section.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("no eval output"))
  end)

  it("renders eval output with metadata", function()
    local s = state_mod.new()
    s = state_mod.update(s, "eval_result", {
      output = "val it: int = 42\nline 2",
      cellId = 3,
      durationMs = 12,
    })
    local out = output_section.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("Cell 3"))
    assert.truthy(joined:find("12ms"))
    assert.truthy(joined:find("val it: int = 42"))
    assert.truthy(joined:find("line 2"))
  end)
end)

describe("Bindings section", function()
  local bindings_section, state_mod

  before_each(function()
    bindings_section = require("sagefs.dashboard.sections.bindings")
    state_mod = require("sagefs.dashboard.state")
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.sections.bindings"] = nil
    package.loaded["sagefs.dashboard.state"] = nil
  end)

  it("conforms to section protocol", function()
    local section = require("sagefs.dashboard.section")
    assert.is_true(section.validate(bindings_section))
    package.loaded["sagefs.dashboard.section"] = nil
  end)

  it("shows placeholder when no bindings", function()
    local s = state_mod.new()
    local out = bindings_section.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("no bindings"))
  end)

  it("renders bindings with type signature", function()
    local s = state_mod.new()
    s = state_mod.update(s, "bindings_snapshot", {
      bindings = {
        { name = "x", typeSig = "int", value = "42" },
        { name = "msg", typeSig = "string", value = "\"hello\"" },
      },
    })
    local out = bindings_section.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("val x : int = 42"))
    assert.truthy(joined:find("val msg : string"))
  end)

  it("has inspect_binding keymaps", function()
    local s = state_mod.new()
    s = state_mod.update(s, "bindings_snapshot", {
      bindings = { { name = "foo", value = "1" } },
    })
    local out = bindings_section.render(s)
    local found = false
    for _, km in ipairs(out.keymaps) do
      if km.action.type == "inspect_binding" and km.action.name == "foo" then
        found = true
      end
    end
    assert.is_true(found)
  end)
end)

describe("Coverage section", function()
  local coverage_section, state_mod

  before_each(function()
    coverage_section = require("sagefs.dashboard.sections.coverage")
    state_mod = require("sagefs.dashboard.state")
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.sections.coverage"] = nil
    package.loaded["sagefs.dashboard.state"] = nil
  end)

  it("conforms to section protocol", function()
    local section = require("sagefs.dashboard.section")
    assert.is_true(section.validate(coverage_section))
    package.loaded["sagefs.dashboard.section"] = nil
  end)

  it("shows no data when total=0", function()
    local s = state_mod.new()
    local out = coverage_section.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("No coverage data"))
  end)

  it("renders progress bar at 80%", function()
    local s = state_mod.new()
    s = state_mod.update(s, "coverage_updated", {
      total = 500, covered = 400, percent = 80,
    })
    local out = coverage_section.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("80%%"))
    assert.truthy(joined:find("400 / 500"))
    -- Good coverage should use SageFsCoverageGood
    local has_good = false
    for _, hl in ipairs(out.highlights) do
      if hl.hl_group == "SageFsCoverageGood" then has_good = true end
    end
    assert.is_true(has_good)
  end)
end)

describe("Filmstrip section", function()
  local filmstrip_section, state_mod

  before_each(function()
    filmstrip_section = require("sagefs.dashboard.sections.filmstrip")
    state_mod = require("sagefs.dashboard.state")
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.sections.filmstrip"] = nil
    package.loaded["sagefs.dashboard.state"] = nil
  end)

  it("conforms to section protocol", function()
    local section = require("sagefs.dashboard.section")
    assert.is_true(section.validate(filmstrip_section))
    package.loaded["sagefs.dashboard.section"] = nil
  end)

  it("shows placeholder when empty", function()
    local s = state_mod.new()
    local out = filmstrip_section.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("no evals yet"))
  end)

  it("renders timeline entries", function()
    local s = state_mod.new()
    s = state_mod.update(s, "eval_timeline", {
      entries = {
        { index = 0, label = "let x = 1", durationMs = 5, status = "ok" },
        { index = 1, label = "let y = 2", durationMs = 3, status = "ok" },
      },
    })
    local out = filmstrip_section.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("let x = 1"))
    assert.truthy(joined:find("5ms"))
  end)
end)

describe("Alarms section", function()
  local alarms_section, state_mod

  before_each(function()
    alarms_section = require("sagefs.dashboard.sections.alarms")
    state_mod = require("sagefs.dashboard.state")
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.sections.alarms"] = nil
    package.loaded["sagefs.dashboard.state"] = nil
  end)

  it("conforms to section protocol", function()
    local section = require("sagefs.dashboard.section")
    assert.is_true(section.validate(alarms_section))
    package.loaded["sagefs.dashboard.section"] = nil
  end)

  it("shows no alarms when empty", function()
    local s = state_mod.new()
    local out = alarms_section.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("No alarms"))
  end)

  it("renders alarms", function()
    local s = state_mod.new()
    s = state_mod.update(s, "system_alarm", { type = "queue_depth", value = 300 })
    local out = alarms_section.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("queue_depth"))
    assert.truthy(joined:find("300"))
  end)
end)
