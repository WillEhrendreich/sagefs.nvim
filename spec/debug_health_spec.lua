-- Tests: what :checkhealth sagefs says about debugging a failing test.
-- nvim-dap and netcoredbg are optional, so a missing one is information with the
-- way to fix it, never an error: every other feature works without them.
require("spec.helper")

local dt = require("sagefs.debug_test")

local function env(over)
  local base = {
    has_dap = true,
    adapters = {},
    netcoredbg = nil,
    netcoredbg_source = nil,
    ptrace_scope = nil,
    is_linux = true,
  }
  for k, v in pairs(over or {}) do base[k] = v end
  return base
end

local function find(items, fragment)
  for _, item in ipairs(items) do
    if item.message:find(fragment, 1, true) then return item end
  end
  return nil
end

describe("debug_test.health_items", function()
  it("without nvim-dap it is information, names the plugin, and says the hold still works", function()
    local items = dt.health_items(env({ has_dap = false }))
    local item = find(items, "nvim-dap not installed")
    assert.is_truthy(item, "an item for the missing nvim-dap")
    assert.are.equal("info", item.level)
    assert.is_truthy(item.message:find("optional", 1, true))
    assert.is_truthy(table.concat(item.advice, " "):find("mfussenegger/nvim-dap", 1, true))
    assert.is_truthy(table.concat(item.advice, " "):find("attach to process", 1, true),
      "the advice says what :SageFsDebugTest does instead")
  end)

  it("with nvim-dap and netcoredbg on PATH both are ok and the path is named", function()
    local items = dt.health_items(env({ netcoredbg = "/usr/bin/netcoredbg", netcoredbg_source = "PATH" }))
    assert.are.equal("ok", find(items, "nvim-dap available").level)
    local adapter = find(items, "netcoredbg")
    assert.are.equal("ok", adapter.level)
    assert.is_truthy(adapter.message:find("/usr/bin/netcoredbg", 1, true))
  end)

  it("a coreclr adapter the user configured is ok and is not second-guessed", function()
    local items = dt.health_items(env({ adapters = { coreclr = { type = "executable", command = "x" } } }))
    local adapter = find(items, "coreclr adapter")
    assert.are.equal("ok", adapter.level)
    assert.is_nil(find(items, "netcoredbg not found"))
  end)

  it("with nvim-dap but no adapter it warns and names the install command", function()
    local items = dt.health_items(env())
    local item = find(items, "netcoredbg not found")
    assert.is_truthy(item)
    assert.are.equal("warn", item.level)
    assert.is_truthy(table.concat(item.advice, " "):find("MasonInstall netcoredbg", 1, true))
  end)

  it("without nvim-dap the adapter is not checked at all", function()
    local items = dt.health_items(env({ has_dap = false }))
    assert.is_nil(find(items, "netcoredbg"))
    assert.is_nil(find(items, "coreclr adapter"))
  end)

  it("ptrace_scope 0 and 1 are ok on Linux, 2 and 3 warn with the setting to change", function()
    local ok1 = find(dt.health_items(env({ ptrace_scope = 1 })), "ptrace_scope")
    assert.are.equal("ok", ok1.level)
    local bad = find(dt.health_items(env({ ptrace_scope = 2 })), "ptrace_scope")
    assert.are.equal("warn", bad.level)
    assert.is_truthy(table.concat(bad.advice, " "):find("kernel.yama.ptrace_scope", 1, true))
  end)

  it("off Linux, or with the file unreadable, there is no ptrace item", function()
    assert.is_nil(find(dt.health_items(env({ is_linux = false, ptrace_scope = 2 })), "ptrace_scope"))
    assert.is_nil(find(dt.health_items(env({ ptrace_scope = nil })), "ptrace_scope"))
  end)
end)
