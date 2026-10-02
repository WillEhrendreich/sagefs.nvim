-- sagefs/wire_testing.lua — Registry for the daemon features wired in one place
--
-- commands.lua and init.lua call these entry points; each feature lives in its
-- own module (debug_test_ui, bindings_view, coverage_hover) so the big files
-- only carry one additive line each.

local M = {}

--- Register the :SageFs* commands these features add.
function M.register_commands(plugin, helpers)
  require("sagefs.debug_test_ui").register_commands(plugin, helpers)
  require("sagefs.coverage_hover").register_commands(plugin, helpers)

  vim.api.nvim_create_user_command("SageFsBindings", function()
    require("sagefs.bindings_view").open(plugin, helpers)
  end, { desc = "Live bindings: the daemon's value tree, with run-this-getter and the walk mode" })
end

--- Buffer-local keymaps (called per F# buffer, like the rest of the maps).
function M.register_keymaps(plugin, helpers, bufnr)
  require("sagefs.debug_test_ui").register_keymaps(plugin, helpers, bufnr)
  require("sagefs.coverage_hover").register_keymaps(plugin, helpers, bufnr)
end

--- Draw whatever these features put in a buffer. Called from the render paths.
function M.render(buf, plugin)
  require("sagefs.debug_test_ui").render_hints(buf, plugin.testing_state, plugin.annotations_state)
  if plugin.coverage_state then
    require("sagefs.coverage_hover").render_badges(buf, plugin.coverage_state, { density = plugin.density_state })
  end
end

--- Highlight groups these features use.
function M.define_highlights()
  require("sagefs.debug_test_ui").define_highlights()
  require("sagefs.bindings_view").define_highlights()
  require("sagefs.coverage_hover").define_highlights()
end

--- SSE handlers for the events these features fold, keyed by classified action.
---@param plugin table the plugin module (state lives on it)
---@param ctx { decode: fun(raw): table|nil, fire: fun(name: string, data: table) }
function M.sse_handlers(plugin, ctx)
  local handlers = {}

  handlers.live_bindings = function(raw)
    local data = ctx.decode(raw)
    if not data then return end
    local lb = require("sagefs.live_bindings")
    plugin.live_bindings_state = lb.apply_snapshot(plugin.live_bindings_state or lb.new(), data)
    ctx.fire("live_bindings", data)
    require("sagefs.bindings_view").on_snapshot()
  end

  return handlers
end

return M
