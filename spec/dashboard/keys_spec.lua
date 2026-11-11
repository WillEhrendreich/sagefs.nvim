-- spec/dashboard/keys_spec.lua — the help section lists the keys the dashboard really maps

local dashboard_keys = require("sagefs.dashboard.keys")
local help = require("sagefs.dashboard.sections.help")
local state_mod = require("sagefs.dashboard.state")

local function help_keys()
  local keys = {}
  for _, line in ipairs(help.render(state_mod.new()).lines) do
    local key = line:match("^  (%S+)%s")
    if key then
      if key == "1-9" then
        for i = 1, 9 do keys[tostring(i)] = true end
      else
        keys[key] = true
      end
    end
  end
  return keys
end

describe("dashboard keys", function()
  local registered
  local saved_set, saved_win_valid

  before_each(function()
    package.loaded["sagefs.dashboard"] = nil
    registered = {}
    saved_set = vim.keymap and vim.keymap.set
    vim.keymap = vim.keymap or {}
    vim.keymap.set = function(_, lhs, _, _) registered[lhs] = true end
  end)

  after_each(function()
    vim.keymap.set = saved_set
    package.loaded["sagefs.dashboard"] = nil
  end)

  it("the help text lists exactly the keys that get mapped", function()
    local dashboard = require("sagefs.dashboard")
    dashboard._bufnr = 1
    dashboard._setup_keymaps()
    local listed = help_keys()
    for lhs in pairs(registered) do
      assert.is_true(listed[lhs] == true, "key '" .. lhs .. "' is mapped but the help does not list it")
    end
    for lhs in pairs(listed) do
      assert.is_true(registered[lhs] == true, "key '" .. lhs .. "' is in the help but is not mapped")
    end
  end)

  it("a key's help text says what its action does", function()
    local by_key = {}
    for _, k in ipairs(dashboard_keys.all) do by_key[k.key] = k end
    assert.is_truthy(by_key["h"].help:lower():find("workflow", 1, true))
  end)
end)
