-- sagefs/commands.lua — Command, keymap, and autocmd registration
-- Thin registration layer. All handlers delegate to the plugin module (M).

local M = {}

--- Register all :SageFs* user commands
---@param plugin table  The sagefs plugin module (init.lua's M)
---@param helpers table  { clear_and_render: fun(), start_sse: fun(), stop_sse: fun(), notify: fun(msg, level) }
function M.register_commands(plugin, helpers)
  local hotreload = require("sagefs.hotreload")
  local model = require("sagefs.model")

  vim.api.nvim_create_user_command("SageFsEval", function()
    plugin.eval_cell()
  end, { desc = "Evaluate current cell" })

  vim.api.nvim_create_user_command("SageFsEvalFile", function()
    plugin.eval_file()
  end, { desc = "Evaluate entire file" })

  vim.api.nvim_create_user_command("SageFsClear", function()
    helpers.clear_and_render()
  end, { desc = "Clear all cell results" })

  vim.api.nvim_create_user_command("SageFsConnect", function()
    if plugin.health_check() then
      helpers.start_sse()
    end
  end, { desc = "Connect to SageFs" })

  vim.api.nvim_create_user_command("SageFsDisconnect", function()
    helpers.stop_sse()
    helpers.notify("Disconnected")
  end, { desc = "Disconnect from SageFs" })

  vim.api.nvim_create_user_command("SageFsStatus", function()
    plugin.health_check()
  end, { desc = "Check SageFs status" })

  vim.api.nvim_create_user_command("SageFsSessions", function()
    plugin.session_picker()
  end, { desc = "Manage SageFs sessions" })

  vim.api.nvim_create_user_command("SageFsCreateSession", function()
    plugin.discover_and_create()
  end, { desc = "Create new SageFs session" })

  vim.api.nvim_create_user_command("SageFsHotReload", function()
    local sid = plugin.active_session and plugin.active_session.id or nil
    hotreload.picker(sid)
  end, { desc = "Manage hot-reload file selection" })

  vim.api.nvim_create_user_command("SageFsWatchAll", function()
    local sid = plugin.active_session and plugin.active_session.id or nil
    if not sid then
      helpers.notify("No active session", vim.log.levels.WARN)
      return
    end
    hotreload.watch_all(sid, function()
      helpers.notify(string.format("Watching all %d files", #hotreload.files))
    end)
  end, { desc = "Watch all files for hot reload" })

  vim.api.nvim_create_user_command("SageFsUnwatchAll", function()
    local sid = plugin.active_session and plugin.active_session.id or nil
    if not sid then
      helpers.notify("No active session", vim.log.levels.WARN)
      return
    end
    hotreload.unwatch_all(sid, function()
      helpers.notify("Unwatched all files")
    end)
  end, { desc = "Unwatch all files for hot reload" })

  vim.api.nvim_create_user_command("SageFsReset", function()
    plugin.reset_session()
  end, { desc = "Reset active FSI session" })

  vim.api.nvim_create_user_command("SageFsHardReset", function()
    plugin.hard_reset()
  end, { desc = "Hard reset (rebuild) active FSI session" })

  vim.api.nvim_create_user_command("SageFsContext", function()
    plugin.show_session_context()
  end, { desc = "Show session context (assemblies, namespaces, warmup)" })
end

--- Register keymaps
---@param plugin table  The sagefs plugin module
---@param helpers table  { smart_eval: fun(fn): fun(), clear_and_render: fun() }
function M.register_keymaps(plugin, helpers)
  local smart_eval = helpers.smart_eval(function() plugin.eval_cell() end)
  local smart_eval_sel = helpers.smart_eval(function() plugin.eval_selection() end)
  local hotreload = require("sagefs.hotreload")

  vim.keymap.set("n", "<A-CR>", smart_eval,
    { desc = "SageFs: Evaluate cell", silent = true })
  vim.keymap.set("v", "<A-CR>", smart_eval_sel,
    { desc = "SageFs: Evaluate selection", silent = true })

  vim.keymap.set("n", "<leader>se", smart_eval,
    { desc = "SageFs: Evaluate cell", silent = true })
  vim.keymap.set("n", "<leader>sc", function()
    helpers.clear_and_render()
  end, { desc = "SageFs: Clear results", silent = true })
  vim.keymap.set("n", "<leader>ss", function() plugin.session_picker() end,
    { desc = "SageFs: Sessions", silent = true })
  vim.keymap.set("n", "<leader>sh", function()
    local sid = plugin.active_session and plugin.active_session.id or nil
    hotreload.picker(sid)
  end, { desc = "SageFs: Hot Reload Files", silent = true })
end

--- Register autocmds
---@param plugin table  The sagefs plugin module
---@param helpers table  { mark_stale_and_render: fun(buf), render_all: fun(buf) }
function M.register_autocmds(plugin, helpers)
  local group = vim.api.nvim_create_augroup("SageFs", { clear = true })

  vim.api.nvim_create_autocmd("TextChanged", {
    group = group,
    pattern = "*.fsx",
    callback = function(ev)
      helpers.mark_stale_and_render(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = "*.fsx",
    callback = function(ev)
      helpers.render_all(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "fsharp", "fsx" },
    callback = function()
      vim.bo.omnifunc = "v:lua.require'sagefs'.omnifunc"
    end,
  })
end

return M
