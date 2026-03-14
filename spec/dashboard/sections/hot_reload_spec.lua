-- spec/dashboard/sections/hot_reload_spec.lua — Hot reload section tests

describe("Hot reload section", function()
  local hot_reload, state_mod

  before_each(function()
    hot_reload = require("sagefs.dashboard.sections.hot_reload")
    state_mod = require("sagefs.dashboard.state")
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.sections.hot_reload"] = nil
    package.loaded["sagefs.dashboard.state"] = nil
  end)

  it("conforms to section protocol", function()
    local section = require("sagefs.dashboard.section")
    assert.is_true(section.validate(hot_reload))
    package.loaded["sagefs.dashboard.section"] = nil
  end)

  it("shows OFF by default", function()
    local s = state_mod.new()
    local out = hot_reload.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("OFF"))
  end)

  it("shows ON with file count when enabled", function()
    local s = state_mod.new()
    s = state_mod.update(s, "hotreload_snapshot", {
      enabled = true, files = { "A.fs", "B.fs" }, totalFiles = 10,
    })
    local out = hot_reload.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("ON"))
    assert.truthy(joined:find("2 / 10"))
  end)

  it("has toggle keymap", function()
    local s = state_mod.new()
    local out = hot_reload.render(s)
    local found = false
    for _, km in ipairs(out.keymaps) do
      if km.action.type == "toggle_hot_reload" then found = true end
    end
    assert.is_true(found)
  end)
end)
