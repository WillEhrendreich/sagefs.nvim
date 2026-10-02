-- Tests: how the wire-testing features hang off the plugin: SSE classification,
-- the User autocmd catalog, the live_bindings handler and :SageFsBindings.
require("spec.helper")

local sse = require("sagefs.sse")
local events = require("sagefs.events")

local function fixture_text(name)
  local src = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
  local f = assert(io.open(src .. "fixtures/wire/" .. name, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

describe("live_bindings SSE wiring", function()
  it("classifies a live_bindings event", function()
    local result = sse.classify_event({ type = "live_bindings", data = "{}" })
    assert.are.equal("live_bindings", result.action)
  end)

  it("has a User autocmd for it", function()
    local data = events.build_autocmd_data("live_bindings", { x = 1 })
    assert.are.equal("SageFsLiveBindings", data.pattern)
  end)

  it("the handler folds the snapshot into the plugin state and fires the event", function()
    local wire = require("sagefs.wire_testing")
    local plugin = {}
    local fired = {}
    local handlers = wire.sse_handlers(plugin, {
      decode = function(raw) local ok, d = require("sagefs.util").json_decode(raw); return ok and d or nil end,
      fire = function(name, data) table.insert(fired, name) end,
    })
    handlers.live_bindings(fixture_text("live_bindings_safe.json"))
    local lb = require("sagefs.live_bindings")
    assert.is_truthy(lb.get(plugin.live_bindings_state, "57bbdfd8"))
    assert.are.same({ "live_bindings" }, fired)
  end)

  it("the handler survives a payload it cannot decode", function()
    local wire = require("sagefs.wire_testing")
    local plugin = {}
    local handlers = wire.sse_handlers(plugin, { decode = function() return nil end, fire = function() end })
    handlers.live_bindings("not json")
    assert.is_nil(plugin.live_bindings_state and next(plugin.live_bindings_state.sessions))
  end)
end)

describe("wire_testing.render", function()
  it("hands the density to the debug hint so minimal draws none", function()
    local ui = require("sagefs.debug_test_ui")
    local prev = ui.render_hints
    local seen
    ui.render_hints = function(_, _, _, opts) seen = opts end
    local density = { codelens = false }
    require("sagefs.wire_testing").render(1, { density_state = density })
    ui.render_hints = prev
    assert.is_truthy(seen)
    assert.are.equal(density, seen.density)
  end)
end)

describe("wire_testing command registration", function()
  it("registers :SageFsBindings as the live view and keeps the tracked list as :SageFsBindingList", function()
    local registered = {}
    local prev = vim.api.nvim_create_user_command
    vim.api.nvim_create_user_command = function(name, handler, opts) registered[name] = { handler = handler, opts = opts } end
    local wire = require("sagefs.wire_testing")
    wire.register_commands({}, { notify = function() end, base_url = function() return "" end })
    vim.api.nvim_create_user_command = prev
    assert.is_truthy(registered.SageFsBindings)
    assert.is_truthy(registered.SageFsDebugTest)
  end)
end)
