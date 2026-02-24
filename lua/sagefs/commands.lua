-- sagefs/commands.lua — Command, keymap, and autocmd registration
-- Thin registration layer. All handlers delegate to the plugin module (M).

local M = {}

--- Register all :SageFs* user commands
---@param plugin table  The sagefs plugin module (init.lua's M)
---@param helpers table  { clear_and_render: fun(), start_sse: fun(), stop_sse: fun(), notify: fun(msg, level) }
function M.register_commands(plugin, helpers)
  local hotreload = require("sagefs.hotreload")
  local model = require("sagefs.model")
  local testing = require("sagefs.testing")
  local coverage = require("sagefs.coverage")
  local type_explorer = require("sagefs.type_explorer")
  local history = require("sagefs.history")
  local export = require("sagefs.export")
  local render = require("sagefs.render")
  local transport = require("sagefs.transport")

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
      helpers.notify(string.format("Watching all %d files", #hotreload.state.files))
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

  -- ─── Testing Commands ────────────────────────────────────────────────────

  vim.api.nvim_create_user_command("SageFsTests", function()
    local lines = testing.format_test_list(plugin.testing_state)
    local summary = testing.compute_summary(plugin.testing_state)
    local title = testing.format_summary(summary)
    render.show_float(lines, { title = title })
  end, { desc = "Show live test results panel" })

  vim.api.nvim_create_user_command("SageFsRunTests", function(opts)
    local req = testing.build_run_request({
      pattern = opts.args ~= "" and opts.args or nil,
    })
    transport.http_json({
      method = "POST",
      url = helpers.base_url() .. "/api/run-tests",
      body = req,
      timeout = 10,
      callback = function(ok)
        if ok then helpers.notify("Tests triggered")
        else helpers.notify("Failed to trigger tests", vim.log.levels.ERROR) end
      end,
    })
  end, { desc = "Run tests (optional pattern filter)", nargs = "?" })

  vim.api.nvim_create_user_command("SageFsTestPolicy", function()
    local items = testing.format_picker_items(plugin.testing_state)
    if #items == 0 then
      helpers.notify("No test categories discovered yet", vim.log.levels.WARN)
      return
    end
    vim.ui.select(items, { prompt = "Select category:" }, function(choice)
      if not choice then return end
      local category = choice:match("^(%S+)")
      local current = testing.get_run_policy(plugin.testing_state, category)
      local options = testing.format_policy_options(category, current)
      vim.ui.select(options, { prompt = category .. " policy:" }, function(policy_choice)
        if not policy_choice then return end
        local policy = policy_choice:match("^(%S+)")
        transport.http_json({
          method = "POST",
          url = helpers.base_url() .. "/api/test-policy",
          body = { category = category, policy = policy },
          timeout = 5,
          callback = function(ok)
            if ok then helpers.notify(category .. " → " .. policy)
            else helpers.notify("Failed to set policy", vim.log.levels.ERROR) end
          end,
        })
      end)
    end)
  end, { desc = "Configure test run policies" })

  vim.api.nvim_create_user_command("SageFsToggleTesting", function()
    transport.http_json({
      method = "POST",
      url = helpers.base_url() .. "/api/toggle-live-testing",
      timeout = 5,
      callback = function(ok)
        if ok then helpers.notify("Live testing toggled")
        else helpers.notify("Failed to toggle", vim.log.levels.ERROR) end
      end,
    })
  end, { desc = "Toggle live testing on/off" })

  -- ─── Coverage Commands ───────────────────────────────────────────────────

  vim.api.nvim_create_user_command("SageFsCoverage", function()
    local summary = coverage.compute_total_summary(plugin.coverage_state)
    local lines = { coverage.format_summary(summary) }
    table.insert(lines, "")
    for path, _ in pairs(plugin.coverage_state.files) do
      local fs = coverage.compute_file_summary(plugin.coverage_state, path)
      table.insert(lines, coverage.format_summary(fs) .. "  " .. path)
    end
    if #lines == 2 then
      table.insert(lines, "(no coverage data yet)")
    end
    render.show_float(lines, { title = "Coverage" })
  end, { desc = "Show coverage summary" })

  -- ─── Type Explorer Command ───────────────────────────────────────────────

  vim.api.nvim_create_user_command("SageFsTypeExplorer", function()
    transport.http_json({
      method = "GET",
      url = helpers.dashboard_url() .. "/api/assemblies",
      timeout = 5,
      callback = function(ok, raw)
        if not ok then
          helpers.notify("Failed to fetch assemblies", vim.log.levels.ERROR)
          return
        end
        local parse_ok, data = pcall(vim.json.decode, raw)
        if not parse_ok or not data then return end
        local items = type_explorer.format_assemblies(data)
        local labels = {}
        for _, item in ipairs(items) do table.insert(labels, item.label) end
        vim.ui.select(labels, { prompt = "Assemblies:" }, function(choice)
          if not choice then return end
          local asm = choice:match("^(%S+)")
          transport.http_json({
            method = "GET",
            url = helpers.dashboard_url() .. "/api/namespaces?assembly=" .. vim.uri_encode(asm),
            timeout = 5,
            callback = function(ns_ok, ns_raw)
              if not ns_ok then return end
              local ns_parse_ok, ns_data = pcall(vim.json.decode, ns_raw)
              if not ns_parse_ok or not ns_data then return end
              local ns_items = type_explorer.format_namespaces(ns_data)
              local ns_labels = {}
              for _, item in ipairs(ns_items) do table.insert(ns_labels, item.label or item) end
              vim.ui.select(ns_labels, { prompt = asm .. " namespaces:" }, function(ns_choice)
                if not ns_choice then return end
                local ns_name = ns_choice:match("^(%S+)")
                transport.http_json({
                  method = "GET",
                  url = helpers.dashboard_url() .. "/api/types?namespace=" .. vim.uri_encode(ns_name),
                  timeout = 5,
                  callback = function(t_ok, t_raw)
                    if not t_ok then return end
                    local t_parse_ok, t_data = pcall(vim.json.decode, t_raw)
                    if not t_parse_ok or not t_data then return end
                    local type_items = type_explorer.format_types(t_data)
                    local type_labels = {}
                    for _, item in ipairs(type_items) do table.insert(type_labels, item.label) end
                    vim.ui.select(type_labels, { prompt = ns_name .. " types:" }, function(t_choice)
                      if not t_choice then return end
                      local type_name = t_choice:match("[◆◇◈▣▤▥●]%s+(.+)")
                      if not type_name then return end
                      transport.http_json({
                        method = "GET",
                        url = helpers.dashboard_url() .. "/api/members?type=" .. vim.uri_encode(type_name),
                        timeout = 5,
                        callback = function(m_ok, m_raw)
                          if not m_ok then return end
                          local m_parse_ok, m_data = pcall(vim.json.decode, m_raw)
                          if not m_parse_ok or not m_data then return end
                          local lines = type_explorer.format_members(type_name, m_data)
                          render.show_float(lines, { title = type_name })
                        end,
                      })
                    end)
                  end,
                })
              end)
            end,
          })
        end)
      end,
    })
  end, { desc = "Browse assemblies → namespaces → types" })

  -- ─── History Command ─────────────────────────────────────────────────────

  vim.api.nvim_create_user_command("SageFsHistory", function()
    transport.http_json({
      method = "GET",
      url = helpers.dashboard_url() .. "/api/history",
      timeout = 5,
      callback = function(ok, raw)
        if not ok then
          helpers.notify("Failed to fetch history", vim.log.levels.ERROR)
          return
        end
        local parse_ok, data = pcall(vim.json.decode, raw)
        if not parse_ok or not data then return end
        local items = history.format_events(data)
        if #items == 0 then
          helpers.notify("No eval history", vim.log.levels.INFO)
          return
        end
        local labels = {}
        for i, item in ipairs(items) do
          table.insert(labels, string.format("%d. %s", i, item.label))
        end
        vim.ui.select(labels, { prompt = "FSI History:" }, function(choice)
          if not choice then return end
          local idx = tonumber(choice:match("^(%d+)%."))
          if idx and items[idx] then
            local event = { code = items[idx].code, result = items[idx].result,
              timestamp = items[idx].timestamp, source = items[idx].source }
            local preview = history.format_preview(event)
            render.show_float(preview, { title = "Eval #" .. idx })
          end
        end)
      end,
    })
  end, { desc = "Browse FSI eval history" })

  -- ─── Export Command ──────────────────────────────────────────────────────

  vim.api.nvim_create_user_command("SageFsExport", function()
    transport.http_json({
      method = "GET",
      url = helpers.dashboard_url() .. "/api/history",
      timeout = 5,
      callback = function(ok, raw)
        if not ok then
          helpers.notify("Failed to fetch history", vim.log.levels.ERROR)
          return
        end
        local parse_ok, data = pcall(vim.json.decode, raw)
        if not parse_ok or not data then return end
        local content = export.format_fsx(data)
        local filename = "sagefs-session-" .. os.date("%Y%m%d-%H%M%S") .. ".fsx"
        local path = vim.fn.getcwd() .. "/" .. filename
        local f = io.open(path, "w")
        if f then
          f:write(content)
          f:close()
          helpers.notify("Exported to " .. filename)
          vim.cmd("edit " .. vim.fn.fnameescape(path))
        else
          helpers.notify("Failed to write " .. path, vim.log.levels.ERROR)
        end
      end,
    })
  end, { desc = "Export session history as .fsx file" })

  -- ─── Call Graph Commands ─────────────────────────────────────────────────

  vim.api.nvim_create_user_command("SageFsCallers", function(opts)
    if opts.args == "" then
      helpers.notify("Usage: :SageFsCallers <symbol>", vim.log.levels.WARN)
      return
    end
    transport.http_json({
      method = "GET",
      url = helpers.dashboard_url() .. "/api/callers?symbol=" .. vim.uri_encode(opts.args),
      timeout = 10,
      callback = function(ok, raw)
        if not ok then
          helpers.notify("Failed to fetch callers", vim.log.levels.ERROR)
          return
        end
        local parse_ok, data = pcall(vim.json.decode, raw)
        if not parse_ok or not data then return end
        local lines = { "Callers of: " .. opts.args, string.rep("─", 40) }
        for _, caller in ipairs(data) do
          table.insert(lines, string.format("  %s  (%s:%d)",
            caller.symbol or caller.name or "?",
            caller.file or "?", caller.line or 0))
        end
        if #lines == 2 then table.insert(lines, "  (no callers found)") end
        render.show_float(lines, { title = "Callers" })
      end,
    })
  end, { desc = "Show callers of a symbol", nargs = 1 })

  vim.api.nvim_create_user_command("SageFsCallees", function(opts)
    if opts.args == "" then
      helpers.notify("Usage: :SageFsCallees <symbol>", vim.log.levels.WARN)
      return
    end
    transport.http_json({
      method = "GET",
      url = helpers.dashboard_url() .. "/api/callees?symbol=" .. vim.uri_encode(opts.args),
      timeout = 10,
      callback = function(ok, raw)
        if not ok then
          helpers.notify("Failed to fetch callees", vim.log.levels.ERROR)
          return
        end
        local parse_ok, data = pcall(vim.json.decode, raw)
        if not parse_ok or not data then return end
        local lines = { "Callees of: " .. opts.args, string.rep("─", 40) }
        for _, callee in ipairs(data) do
          table.insert(lines, string.format("  %s  (%s:%d)",
            callee.symbol or callee.name or "?",
            callee.file or "?", callee.line or 0))
        end
        if #lines == 2 then table.insert(lines, "  (no callees found)") end
        render.show_float(lines, { title = "Callees" })
      end,
    })
  end, { desc = "Show callees of a symbol", nargs = 1 })
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

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = { "*.fs", "*.fsx" },
    callback = function(ev)
      helpers.render_signs(ev.buf)
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
