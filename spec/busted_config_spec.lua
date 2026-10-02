require("spec.helper")

-- Plain `busted` at the repo root is how the plugin's CI and SageFs's
-- scripts/sync-nvim-version run the suite, so .busted has to make it work
-- from a bare shell. One thing in it breaks that: a `lua` key makes busted
-- re-run itself through that interpreter name (busted/modules/cli.lua), and
-- the re-run does not get the LuaRocks package path the `busted` wrapper set
-- up. Without LUA_PATH in the environment it dies with
-- "module 'busted.runner' not found", which sync-nvim-version reads as "busted
-- is not usable here" and then publishes the release without running anything.

local function load_busted_config()
  local f = assert(loadfile(".busted"), ".busted must be loadable from the repo root")
  return f()
end

describe(".busted", function()
  it("does not re-exec busted through another interpreter", function()
    local default = load_busted_config().default
    assert.is_nil(default.lua, "a `lua` key re-runs busted without the LuaRocks package path")
  end)

  it("points at the spec directory and the vim-mocking helper that exist", function()
    local default = load_busted_config().default
    assert.equals("spec/helper.lua", default.helper)
    local helper = io.open(default.helper)
    assert.is_truthy(helper, "helper file must exist")
    helper:close()
    assert.same({ "spec/" }, default.ROOT)
  end)

  it("keeps the end-to-end specs out of the default run", function()
    assert.equals("e2e", load_busted_config().default["exclude-pattern"])
  end)
end)
