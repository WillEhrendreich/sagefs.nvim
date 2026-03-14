-- Help section tests — help is a section like any other

describe("help section", function()
  local help = require("sagefs.dashboard.sections.help")
  local section_mod = require("sagefs.dashboard.section")
  local state_mod = require("sagefs.dashboard.state")

  it("conforms to the section protocol", function()
    assert.is_true(section_mod.validate(help))
  end)

  it("has id 'help'", function()
    assert.equals("help", help.id)
  end)

  it("has no events (static content)", function()
    assert.are.same({}, help.events)
  end)

  it("renders a header line", function()
    local state = state_mod.new()
    local output = help.render(state)
    assert.truthy(output.lines[1]:find("Keybindings"))
  end)

  it("renders all documented keybindings", function()
    local state = state_mod.new()
    local output = help.render(state)
    local text = table.concat(output.lines, "\n")

    -- Every key from the help table should appear
    local expected_keys = { "q", "<Tab>", "<S%-Tab>", "1%-9", "e", "d", "h", "r", "R", "<CR>", "?" }
    for _, key in ipairs(expected_keys) do
      assert.truthy(text:find(key), "help should mention key: " .. key)
    end
  end)

  it("produces highlights for every keybinding", function()
    local state = state_mod.new()
    local output = help.render(state)

    -- Header highlight + one per keybinding
    assert.is_true(#output.highlights > 1)

    -- All key highlights use SageFsHelpKey
    local key_hls = 0
    for _, hl in ipairs(output.highlights) do
      if hl.hl_group == "SageFsHelpKey" then key_hls = key_hls + 1 end
    end
    assert.is_true(key_hls >= 10, "should have highlights for all keybindings")
  end)

  it("returns section_id in output", function()
    local output = help.render(state_mod.new())
    assert.equals("help", output.section_id)
  end)
end)
