-- sagefs/wire_testing.lua — Registry for the daemon features wired in one place
--
-- commands.lua and init.lua call these three entry points; each feature lives
-- in its own module (debug_test_ui, bindings_view, coverage_hover) so the big
-- files only carry one additive line each.

local M = {}

--- Register the :SageFs* commands these features add.
function M.register_commands(plugin, helpers)
  require("sagefs.debug_test_ui").register_commands(plugin, helpers)
end

--- Buffer-local keymaps (called per F# buffer, like the rest of the maps).
function M.register_keymaps(plugin, helpers, bufnr)
  require("sagefs.debug_test_ui").register_keymaps(plugin, helpers, bufnr)
end

--- Draw whatever these features put in a buffer. Called from the render paths.
function M.render(buf, plugin)
  require("sagefs.debug_test_ui").render_hints(buf, plugin.testing_state, plugin.annotations_state)
end

--- Highlight groups these features use.
function M.define_highlights()
  require("sagefs.debug_test_ui").define_highlights()
end

return M
