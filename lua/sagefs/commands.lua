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
  local te_cache = require("sagefs.type_explorer_cache")
  local history = require("sagefs.history")
  local export = require("sagefs.export")
  local render = require("sagefs.render")
  local transport = require("sagefs.transport")
  local format = require("sagefs.format")

  -- Truncate raw server response for error messages
  local function err_detail(raw)
    if not raw or raw == "" then return "" end
    local detail = raw:sub(1, 200)
    if #raw > 200 then detail = detail .. "…" end
    return ": " .. detail
  end

  vim.api.nvim_create_user_command("SageFsEval", function()
    plugin.eval_cell()
  end, { desc = "Evaluate current cell" })

  vim.api.nvim_create_user_command("SageFsEvalAdvance", function()
    plugin.eval_cell_and_advance()
  end, { desc = "Evaluate current cell and move to next" })

  vim.api.nvim_create_user_command("SageFsEvalFile", function()
    plugin.eval_file()
  end, { desc = "Evaluate entire file" })

  vim.api.nvim_create_user_command("SageFsEvalLine", function()
    plugin.eval_current_line()
  end, { desc = "Evaluate current line only" })

  vim.api.nvim_create_user_command("SageFsClear", function()
    helpers.clear_and_render()
  end, { desc = "Clear all cell results" })

  vim.api.nvim_create_user_command("SageFsCellStyle", function(cmd)
    local ch = require("sagefs.cell_highlight")
    if cmd.args ~= "" then
      ch.set_style(cmd.args)
      vim.notify("[SageFs] Cell highlight: " .. ch.style, vim.log.levels.INFO)
    else
      ch.cycle_style()
    end
  end, {
    nargs = "?",
    complete = function() return { "off", "minimal", "normal", "full" } end,
    desc = "Set or cycle cell highlight style (off/minimal/normal/full)",
  })

  vim.api.nvim_create_user_command("SageFsConnect", function()
    plugin.health_check(function(healthy)
      if healthy then helpers.start_sse() end
    end)
  end, { desc = "Connect to SageFs" })

  vim.api.nvim_create_user_command("SageFsDisconnect", function()
    helpers.stop_sse()
    helpers.notify("Disconnected")
  end, { desc = "Disconnect from SageFs" })

  vim.api.nvim_create_user_command("SageFsStatus", function()
    plugin.health_check(function(healthy)
      local lines = format.format_status_report({
        state = plugin.state,
        testing_state = plugin.testing_state,
        coverage_state = plugin.coverage_state,
        daemon_state = plugin.daemon_state,
        active_session = plugin.active_session,
        config = plugin.config,
      })
      local status_label = healthy and "✓ Connected" or "✗ Disconnected"
      table.insert(lines, 2, "Status:    " .. status_label)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
      vim.bo[buf].bufhidden = "wipe"
      local width = 50
      for _, l in ipairs(lines) do width = math.max(width, #l + 4) end
      vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = #lines,
        row = math.floor((vim.o.lines - #lines) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
      })
      vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, silent = true })
    end)
  end, { desc = "SageFs status dashboard" })

  vim.api.nvim_create_user_command("SageFsBindings", function()
    local tracker = plugin.binding_tracker
    local lines = { "═══ FSI Bindings ═══", "" }
    local sorted = {}
    for name, info in pairs(tracker.bindings) do
      table.insert(sorted, { name = name, type_sig = info.type_sig, count = info.count })
    end
    table.sort(sorted, function(a, b) return a.name < b.name end)
    if #sorted == 0 then
      table.insert(lines, "(no bindings tracked yet)")
    else
      for _, b in ipairs(sorted) do
        local suffix = b.count > 1
          and string.format("  (shadowed %dx)", b.count - 1)
          or ""
        table.insert(lines, string.format("  val %s : %s%s", b.name, b.type_sig, suffix))
      end
    end
    table.insert(lines, "")
    table.insert(lines, string.format("Total: %d bindings", #sorted))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    local width = 50
    for _, l in ipairs(lines) do width = math.max(width, #l + 4) end
    vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = math.min(#lines, 30),
      row = math.floor((vim.o.lines - math.min(#lines, 30)) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      style = "minimal",
      border = "rounded",
    })
    vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, silent = true })
  end, { desc = "Show FSI binding state" })

  -- Note: SageFsTestTrace is registered later with HTTP fetch (richer than SSE state)

  vim.api.nvim_create_user_command("SageFsSessions", function()
    plugin.session_picker()
  end, { desc = "Manage SageFs sessions" })

  vim.api.nvim_create_user_command("SageFsCreateSession", function()
    plugin.discover_and_create()
  end, { desc = "Create new SageFs session" })

  vim.api.nvim_create_user_command("SageFsConfig", function()
    plugin.configure_warmup_auto_open()
  end, { desc = "Create or open .SageFs/config.fsx for warmup auto-open" })

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
    te_cache.clear()
    plugin.hard_reset()
  end, { desc = "Hard reset (rebuild) active FSI session" })

  vim.api.nvim_create_user_command("SageFsContext", function()
    plugin.show_session_context()
  end, { desc = "Show session context (assemblies, namespaces, warmup)" })

  vim.api.nvim_create_user_command("SageFsExport", function()
    local transport = require("sagefs.transport")
    local sid = plugin.active_session and plugin.active_session.id or nil
    if not sid then
      helpers.notify("No active session", vim.log.levels.WARN)
      return
    end
    local port = plugin.config and plugin.config.port or 37749
    local url = string.format("http://localhost:%d/api/sessions/%s/export-fsx", port, sid)
    transport.http_json({
      method = "GET",
      url = url,
      callback = function(ok, raw)
        vim.schedule(function()
          if not ok then
            helpers.notify("Failed to export session", vim.log.levels.ERROR)
            return
          end
          local data = vim.fn.json_decode(raw)
          if not data or (data.evalCount or 0) == 0 then
            helpers.notify("No evaluations to export", vim.log.levels.INFO)
            return
          end
          local buf = vim.api.nvim_create_buf(true, false)
          vim.bo[buf].filetype = "fsharp"
          local lines = vim.split(data.content, "\n")
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
          vim.api.nvim_set_current_buf(buf)
          helpers.notify(string.format("Exported %d evaluations", data.evalCount))
        end)
      end,
    })
  end, { desc = "Export session eval history as .fsx" })

  -- ─── Testing Commands ────────────────────────────────────────────────────

  vim.api.nvim_create_user_command("SageFsTests", function()
    -- Prefer Telescope when available
    local has_telescope = pcall(require, "telescope")
    if has_telescope then
      vim.cmd("Telescope sagefs tests")
      return
    end
    local lines = testing.format_test_list(plugin.testing_state)
    local s = plugin.testing_state.summary
    if #lines == 0 and s and s.total and s.total > 0 then
      lines = {
        string.format("  %d tests discovered", s.total),
        "",
        "  Individual test entries arrive via SSE when tests run.",
        "  Use :SageFsRunTests to trigger a test run.",
      }
      if (s.passed or 0) > 0 or (s.failed or 0) > 0 then
        table.insert(lines, 2, string.format(
          "  ✓ %d passed  ✗ %d failed  ⟳ %d running",
          s.passed or 0, s.failed or 0, s.running or 0))
      end
    end
    local summary = testing.compute_summary(plugin.testing_state)
    local title = testing.format_summary(summary)
    render.show_float(lines, { title = title })
  end, { desc = "Show live test results (Telescope or float)" })

  vim.api.nvim_create_user_command("SageFsFailures", function()
    local has_telescope = pcall(require, "telescope")
    if has_telescope then
      vim.cmd("Telescope sagefs failures")
      return
    end
    -- Fallback: filter to failures in float
    local failed = testing.filter_by_status(plugin.testing_state, "Failed")
    local lines = {}
    for _, t in ipairs(failed) do
      table.insert(lines, string.format("  ✗ %s", t.displayName or "?"))
      if t.file then
        table.insert(lines, string.format("    %s:%d", t.file:match("[^\\/]+$") or t.file, t.line or 0))
      end
    end
    if #lines == 0 then lines = { "  No failures 🎉" } end
    render.show_float(lines, { title = string.format("Failures (%d)", #failed) })
  end, { desc = "Show failing tests (Telescope or float)" })

  vim.api.nvim_create_user_command("SageFsRunTests", function(opts)
    local req = testing.build_run_request({
      pattern = opts.args ~= "" and opts.args or nil,
    })
    transport.http_json({
      method = "POST",
      url = helpers.base_url() .. "/api/live-testing/run",
      body = req,
      timeout = 10,
      callback = function(ok, raw)
        if not ok then
          helpers.notify("Failed to trigger tests" .. err_detail(raw), vim.log.levels.ERROR)
          return
        end
        local resp = pcall(vim.json.decode, raw) and vim.json.decode(raw) or nil
        if resp and resp.success then
          helpers.notify("Tests triggered")
        else
          local reason = (resp and (resp.message or resp.reason)) or raw or "Unknown error"
          helpers.notify("SageFs: test run failed — " .. reason, vim.log.levels.ERROR)
        end
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
          url = helpers.base_url() .. "/api/live-testing/policy",
          body = { category = category, policy = policy },
          timeout = 5,
          callback = function(ok, raw)
            if ok then helpers.notify(category .. " → " .. policy)
            else helpers.notify("Failed to set policy" .. err_detail(raw), vim.log.levels.ERROR) end
          end,
        })
      end)
    end)
  end, { desc = "Configure test run policies" })

  -- ─── Persistent Test Panel (scope-filtered) ──────────────────────────────────

  local test_panel_buf = nil
  local test_panel_win = nil
  local test_panel_entries = {}
  local test_panel_scope_kind = "file"  -- default operational scope
  local test_panel_source_file = nil    -- filepath of last active .fs buffer
  local test_panel_module_prefix = nil  -- derived from source_file
  local test_panel_binding_name = nil   -- treesitter-detected enclosing binding

  --- Derive module prefix from a file path.
  --- Heuristic: basename without extension, prepended with common namespace.
  --- E.g. "C:\SageFs\EditorTests.fs" → nil (we use fullName prefix matching,
  --- which needs the actual namespace. We'll extract from first test match.)
  local function derive_module_prefix(state, filepath)
    if not filepath then return nil end
    -- Find any test in this file and extract its top-level module from fullName
    -- Use testing.filter_by_file which handles path separator normalization
    local file_tests = testing.filter_by_file(state, filepath)
    for _, test in ipairs(file_tests) do
      if test.fullName then
        -- fullName = "Ns.Module.binding/group/test" → extract "Ns.Module"
        local prefix = test.fullName:match("^([^/]+)")
        if prefix then
          -- Strip trailing binding: "Ns.Module.binding" → "Ns.Module"
          return prefix:match("^(.+)%.[^%.]+$") or prefix
        end
      end
    end
    return nil
  end

  --- Detect the enclosing F# let binding name via treesitter.
  --- Walks from cursor up the tree to find function_or_value_defn → identifier_pattern.
  ---@param buf number buffer handle
  ---@param row number|nil 0-based row (uses cursor of buf's window if nil)
  ---@param col number|nil 0-based col
  ---@return string|nil binding name or nil
  local function detect_binding_name(buf, row, col)
    local ok, parser = pcall(vim.treesitter.get_parser, buf, "fsharp")
    if not ok or not parser then return nil end
    -- If no explicit position, find the window showing this buffer
    if not row then
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == buf then
          local pos = vim.api.nvim_win_get_cursor(w)
          row = pos[1] - 1  -- 0-based
          col = pos[2]
          break
        end
      end
    end
    if not row then return nil end
    local node = vim.treesitter.get_node({ bufnr = buf, pos = { row, col or 0 } })
    while node and node:type() ~= "function_or_value_defn" do
      node = node:parent()
    end
    if not node then return nil end
    -- value_declaration_left → identifier_pattern
    local vdl = node:child(1)
    if not vdl then return nil end
    for i = 0, vdl:child_count() - 1 do
      local c = vdl:child(i)
      if c:type() == "identifier_pattern" then
        return vim.treesitter.get_node_text(c, buf)
      end
    end
    return nil
  end

  --- Build the current scope table from panel state
  local function build_panel_scope()
    if test_panel_scope_kind == "file" then
      return { kind = "file", path = test_panel_source_file }
    elseif test_panel_scope_kind == "module" then
      return { kind = "module", prefix = test_panel_module_prefix }
    elseif test_panel_scope_kind == "binding" then
      return { kind = "binding", name = test_panel_binding_name, path = test_panel_source_file }
    else
      return { kind = "all" }
    end
  end

  local function update_test_panel()
    if not test_panel_buf or not vim.api.nvim_buf_is_valid(test_panel_buf) then return end
    if not test_panel_win or not vim.api.nvim_win_is_valid(test_panel_win) then return end

    local scope = build_panel_scope()
    test_panel_entries = testing.format_scoped_panel_entries(plugin.testing_state, scope, plugin.annotations_state)

    local lines = {}
    -- Show poll-based summary when we have summary but no individual tests
    local s = plugin.testing_state.summary
    local has_individual_tests = false
    for _ in pairs(plugin.testing_state.tests) do has_individual_tests = true; break end
    if not has_individual_tests and s and s.total and s.total > 0 then
      local status = plugin.testing_state.enabled and "enabled" or "disabled"
      table.insert(lines, string.format("═══ Tests (%s) ═══", status))
      table.insert(lines, string.format("Total: %d  ✓ %d  ✗ %d  ⏳ %d",
        s.total, s.passed or 0, s.failed or 0, s.running or 0))
      if (s.stale or 0) > 0 then
        table.insert(lines, string.format("Stale: %d", s.stale))
      end
      table.insert(lines, "")
      table.insert(lines, "(per-test details unavailable)")
    else
      for _, e in ipairs(test_panel_entries) do
        table.insert(lines, e.text)
      end
    end
    vim.bo[test_panel_buf].modifiable = true
    vim.api.nvim_buf_set_lines(test_panel_buf, 0, -1, false, lines)
    vim.bo[test_panel_buf].modifiable = false
  end

  --- Set scope kind and refresh
  local function set_panel_scope(kind)
    test_panel_scope_kind = kind
    -- Recompute module prefix when switching to module scope
    if kind == "module" then
      test_panel_module_prefix = derive_module_prefix(plugin.testing_state, test_panel_source_file)
    elseif kind == "binding" then
      -- Detect binding from the source window (previous window)
      local prev_win = vim.fn.win_getid(vim.fn.winnr("#"))
      if prev_win and prev_win ~= 0 then
        local prev_buf = vim.api.nvim_win_get_buf(prev_win)
        test_panel_binding_name = detect_binding_name(prev_buf)
      end
    end
    update_test_panel()
  end

  vim.api.nvim_create_user_command("SageFsTestPanel", function()
    -- Toggle: close if open (guard against E444 if it's the last window)
    if test_panel_win and vim.api.nvim_win_is_valid(test_panel_win) then
      if #vim.api.nvim_tabpage_list_wins(0) > 1 then
        vim.api.nvim_win_close(test_panel_win, true)
      else
        vim.api.nvim_win_set_buf(test_panel_win, vim.api.nvim_create_buf(true, false))
      end
      test_panel_win = nil
      return
    end
    -- Capture source file from current buffer before creating panel
    local cur_file = vim.fn.expand("%:p")
    if cur_file:match("%.fs$") or cur_file:match("%.fsx$") then
      test_panel_source_file = cur_file
      test_panel_module_prefix = derive_module_prefix(plugin.testing_state, cur_file)
    end
    -- If no .fs context yet, default to all scope
    if not test_panel_source_file then
      test_panel_scope_kind = "all"
    end
    -- Create scratch buffer
    test_panel_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[test_panel_buf].buftype = "nofile"
    vim.bo[test_panel_buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_name(test_panel_buf, "sagefs://tests")
    -- Buffer-local <CR> to jump to test source
    vim.keymap.set("n", "<CR>", function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local entry = test_panel_entries[row]
      if not entry or not entry.file then return end
      vim.cmd("wincmd p")
      vim.cmd.edit(entry.file)
      if entry.line then
        vim.api.nvim_win_set_cursor(0, { entry.line, 0 })
      end
    end, { buffer = test_panel_buf, desc = "Jump to test source" })
    -- Buffer-local scope keymaps
    vim.keymap.set("n", "f", function() set_panel_scope("file") end,
      { buffer = test_panel_buf, desc = "Filter: file scope" })
    vim.keymap.set("n", "m", function() set_panel_scope("module") end,
      { buffer = test_panel_buf, desc = "Filter: module scope" })
    vim.keymap.set("n", "a", function() set_panel_scope("all") end,
      { buffer = test_panel_buf, desc = "Filter: all tests" })
    vim.keymap.set("n", "b", function() set_panel_scope("binding") end,
      { buffer = test_panel_buf, desc = "Filter: binding scope (treesitter)" })
    vim.keymap.set("n", "<Tab>", function()
      set_panel_scope(testing.next_scope(test_panel_scope_kind))
    end, { buffer = test_panel_buf, desc = "Cycle filter scope" })
    -- Open in vertical split
    vim.cmd("botright vsplit")
    test_panel_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(test_panel_win, test_panel_buf)
    vim.api.nvim_win_set_width(test_panel_win, 45)
    vim.wo[test_panel_win].number = false
    vim.wo[test_panel_win].relativenumber = false
    vim.wo[test_panel_win].signcolumn = "no"
    vim.wo[test_panel_win].winfixwidth = true
    -- Fill initial content
    update_test_panel()
    -- Return focus to previous window
    vim.cmd("wincmd p")
  end, { desc = "Toggle persistent test results panel" })

  -- Auto-update panel on test events
  local panel_group = vim.api.nvim_create_augroup("SageFsTestPanel", { clear = true })
  for _, pattern in ipairs({ "SageFsTestResultsBatch", "SageFsTestRunCompleted", "SageFsTestsDiscovered", "SageFsTestState" }) do
    vim.api.nvim_create_autocmd("User", {
      group = panel_group,
      pattern = pattern,
      callback = function()
        vim.schedule(update_test_panel)
      end,
    })
  end

  -- Track source buffer: when user enters an F# buffer, update panel context
  vim.api.nvim_create_autocmd("BufEnter", {
    group = panel_group,
    pattern = { "*.fs", "*.fsx" },
    callback = function(args)
      local filepath = vim.api.nvim_buf_get_name(args.buf)
      if filepath and filepath ~= "" then
        test_panel_source_file = filepath
        test_panel_module_prefix = derive_module_prefix(plugin.testing_state, filepath)
        -- Only refresh if scope depends on file context
        if test_panel_scope_kind ~= "all" then
          vim.schedule(update_test_panel)
        end
      end
    end,
  })

  -- ─── Tests Here (current file) ─────────────────────────────────────────────

  vim.api.nvim_create_user_command("SageFsTestsHere", function()
    local testing = require("sagefs.testing")
    local filepath = vim.fn.expand("%:p")
    local lines = testing.format_file_panel_content(plugin.testing_state, filepath)
    render.show_float(lines, { title = "Tests: " .. vim.fn.fnamemodify(filepath, ":t") })
  end, { desc = "Show tests for the current file" })

  -- ─── test trace ────────────────────────────────────────────────────────

  vim.api.nvim_create_user_command("SageFsTestTrace", function()
    local test_trace_mod = require("sagefs.test_trace")
    transport.http_json({
      method = "GET",
      url = helpers.base_url() .. "/api/status",
      timeout = 5,
      callback = function(ok, raw)
        if not ok then
          helpers.notify("Failed to fetch test trace" .. err_detail(raw), vim.log.levels.ERROR)
          return
        end
        local trace = test_trace_mod.parse_trace(raw)
        if not trace then
          helpers.notify("Invalid test trace response", vim.log.levels.WARN)
          return
        end
        local lines = test_trace_mod.format_panel_content(trace)
        render.show_float(lines, { title = "test trace" })
      end,
    })
  end, { desc = "Show test trace in floating window" })

  -- ─── Load Script ───────────────────────────────────────────────────────────

  vim.api.nvim_create_user_command("SageFsLoadScript", function(opts)
    local path = opts.args
    if path == "" then
      path = vim.fn.expand("%:p")
      if not path:match("%.fsx$") then
        helpers.notify("Current file is not an .fsx script", vim.log.levels.WARN)
        return
      end
    end
    helpers.notify("Loading script: " .. vim.fn.fnamemodify(path, ":t"))
    transport.http_json({
      method = "POST",
      url = helpers.base_url() .. "/exec",
      body = { code = string.format('#load @"%s";;', path) },
      timeout = 30,
      callback = function(ok, raw)
        if ok then
          helpers.notify("Script loaded: " .. vim.fn.fnamemodify(path, ":t"))
        else
          helpers.notify("Failed to load script: " .. tostring(raw), vim.log.levels.ERROR)
        end
      end,
    })
  end, { desc = "Load an F# script file (.fsx)", nargs = "?", complete = "file" })

  vim.api.nvim_create_user_command("SageFsEnableTesting", function()
    transport.http_json({
      method = "POST",
      url = helpers.base_url() .. "/api/live-testing/enable",
      timeout = 5,
      callback = function(ok, raw)
        if not ok then
          helpers.notify("Failed to enable live testing" .. err_detail(raw), vim.log.levels.ERROR)
          return
        end
        local resp = pcall(vim.json.decode, raw) and vim.json.decode(raw) or nil
        if resp and resp.success == false then
          local reason = (resp.message or resp.reason) or "Unknown error"
          helpers.notify("SageFs: failed to enable live testing — " .. reason, vim.log.levels.ERROR)
        else
          helpers.notify("Live testing enabled")
        end
      end,
    })
  end, { desc = "Enable live testing" })

  vim.api.nvim_create_user_command("SageFsDisableTesting", function()
    transport.http_json({
      method = "POST",
      url = helpers.base_url() .. "/api/live-testing/disable",
      timeout = 5,
      callback = function(ok, raw)
        if not ok then
          helpers.notify("Failed to disable live testing" .. err_detail(raw), vim.log.levels.ERROR)
          return
        end
        local resp = pcall(vim.json.decode, raw) and vim.json.decode(raw) or nil
        if resp and resp.success == false then
          local reason = (resp.message or resp.reason) or "Unknown error"
          helpers.notify("SageFs: failed to disable live testing — " .. reason, vim.log.levels.ERROR)
        else
          helpers.notify("Live testing disabled")
        end
      end,
    })
  end, { desc = "Disable live testing" })

  vim.api.nvim_create_user_command("SageFsCancel", function()
    transport.http_json({
      method = "POST",
      url = helpers.base_url() .. "/api/cancel-eval",
      body = { working_directory = vim.fn.getcwd() },
      timeout = 5,
      callback = function(ok, raw)
        if ok then helpers.notify("Eval cancelled")
        else helpers.notify("Failed to cancel eval" .. err_detail(raw), vim.log.levels.ERROR) end
      end,
    })
  end, { desc = "Cancel running evaluation" })

  -- ─── Daemon Lifecycle ──────────────────────────────────────────────────

  vim.api.nvim_create_user_command("SageFsStart", function(opts)
    local daemon = require("sagefs.daemon")
    if daemon.is_running(plugin.daemon_state) then
      helpers.notify("SageFs daemon already running", vim.log.levels.WARN)
      return
    end
    -- Check if SageFs is already running externally (health check)
    local function try_start(project)
      plugin.daemon_state = daemon.mark_starting(plugin.daemon_state, project, plugin.config.port)
      local cmd = daemon.start_command({ project = project, port = plugin.config.port })
      local stderr_lines = {}
      local job_id = vim.fn.jobstart(cmd, {
        detach = true,
        on_stdout = function() end,
        on_stderr = function(_, data)
          if data then
            for _, line in ipairs(data) do
              if line ~= "" then table.insert(stderr_lines, line) end
            end
          end
        end,
        on_exit = function(_, code)
          vim.schedule(function()
            if code ~= 0 then
              local err_msg = #stderr_lines > 0
                and table.concat(stderr_lines, "\n"):sub(1, 200)
                or ("exit code " .. code)
              plugin.daemon_state = daemon.mark_failed(plugin.daemon_state, err_msg)
              helpers.notify("SageFs daemon failed: " .. err_msg, vim.log.levels.ERROR)
            else
              plugin.daemon_state = daemon.mark_stopped(plugin.daemon_state)
              helpers.notify("SageFs daemon stopped")
            end
          end)
        end,
      })
      if job_id > 0 then
        plugin.daemon_state = daemon.mark_running(plugin.daemon_state, job_id)
        helpers.notify("SageFs daemon started for " .. project)
        -- Auto-connect after a short delay
        vim.defer_fn(function()
          plugin.health_check(function(healthy)
            if healthy then helpers.start_sse() end
          end)
        end, 3000)
      else
        plugin.daemon_state = daemon.mark_failed(plugin.daemon_state, "jobstart failed")
        helpers.notify("Failed to start SageFs daemon", vim.log.levels.ERROR)
      end
    end

    if opts.args and opts.args ~= "" then
      try_start(opts.args)
      return
    end

    -- Auto-discover: prefer .slnx/.sln, then .fsproj
    local cwd = vim.fn.getcwd()
    local solutions = vim.fn.glob(cwd .. "/*.slnx", false, true)
    if #solutions == 0 then
      solutions = vim.fn.glob(cwd .. "/*.sln", false, true)
    end
    if #solutions == 1 then
      try_start(solutions[1])
      return
    elseif #solutions > 1 then
      local names = vim.tbl_map(function(f) return vim.fn.fnamemodify(f, ":t") end, solutions)
      vim.ui.select(names, { prompt = "Start SageFs with solution:" }, function(choice, idx)
        if choice then try_start(solutions[idx]) end
      end)
      return
    end

    -- No solutions found, try .fsproj (non-recursive, cwd only first)
    local fsproj_files = vim.fn.glob(cwd .. "/*.fsproj", false, true)
    if #fsproj_files == 0 then
      -- Scan one level deep
      fsproj_files = vim.fn.glob(cwd .. "/*/*.fsproj", false, true)
    end
    if #fsproj_files == 1 then
      try_start(fsproj_files[1])
    elseif #fsproj_files > 1 then
      local names = vim.tbl_map(function(f) return vim.fn.fnamemodify(f, ":~:.") end, fsproj_files)
      vim.ui.select(names, { prompt = "Start SageFs with project:" }, function(choice, idx)
        if choice then try_start(fsproj_files[idx]) end
      end)
    else
      helpers.notify("No .slnx, .sln, or .fsproj files found", vim.log.levels.ERROR)
    end
  end, { nargs = "?", complete = "file", desc = "Start SageFs daemon" })

  vim.api.nvim_create_user_command("SageFsStop", function()
    local daemon = require("sagefs.daemon")
    if not daemon.is_running(plugin.daemon_state) then
      helpers.notify("SageFs daemon is not running", vim.log.levels.WARN)
      return
    end
    helpers.stop_sse()
    vim.fn.jobstop(plugin.daemon_state.job_id)
    plugin.daemon_state = daemon.mark_stopped(plugin.daemon_state)
    helpers.notify("SageFs daemon stopped")
  end, { desc = "Stop SageFs daemon" })

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
    local sid = plugin.active_session and plugin.active_session.id or ""

    local function explore(qualified_name)
      -- Check cache
      local cached = te_cache.get(qualified_name)
      if cached then
        show_explorer_results(qualified_name, cached)
        return
      end
      -- Send "QualifiedName." as code and get completions at cursor after the dot
      local code = qualified_name .. "."
      local body = { code = code, cursorPos = #code, sessionId = sid }
      transport.http_json({
        method = "POST",
        url = helpers.dashboard_url() .. "/dashboard/completions",
        body = body,
        timeout = 8,
        callback = function(ok, raw)
          if not ok then
            helpers.notify("Failed to explore " .. qualified_name .. err_detail(raw), vim.log.levels.ERROR)
            return
          end
          local parse_ok, data = pcall(vim.json.decode, raw)
          if not parse_ok or not data or not data.completions then
            helpers.notify("No completions for " .. qualified_name, vim.log.levels.WARN)
            return
          end
          te_cache.set(qualified_name, data.completions)
          show_explorer_results(qualified_name, data.completions)
        end,
      })
    end

    function show_explorer_results(qualified_name, completions)
      if #completions == 0 then
        helpers.notify("No members found for " .. qualified_name, vim.log.levels.WARN)
        return
      end
      local items = type_explorer.format_completions(completions)
      local labels = {}
      for _, item in ipairs(items) do labels[#labels + 1] = item.label end
      vim.ui.select(labels, { prompt = qualified_name .. ":" }, function(choice)
        if not choice then return end
        local idx
        for i, l in ipairs(labels) do
          if l == choice then idx = i; break end
        end
        if not idx then return end
        local picked = items[idx]
        if picked.drillable then
          explore(qualified_name .. "." .. picked.insertText)
        else
          -- Show leaf member panel
          local panel = type_explorer.format_members_panel(
            qualified_name .. "." .. picked.insertText, completions)
          render.show_float(panel, { title = qualified_name })
        end
      end)
    end

    -- Start: offer common roots or custom input
    local roots = type_explorer.common_roots()
    local root_labels = {}
    for _, r in ipairs(roots) do root_labels[#root_labels + 1] = r end
    root_labels[#root_labels + 1] = "⌨ Enter custom namespace…"
    vim.ui.select(root_labels, { prompt = "Explore namespace:" }, function(choice)
      if not choice then return end
      if choice:find("^⌨") then
        vim.ui.input({ prompt = "Namespace: " }, function(input)
          if input and input ~= "" then explore(input) end
        end)
      else
        explore(choice)
      end
    end)
  end, { desc = "Browse namespaces → types → members via completions" })

  -- SageFsTypeExplorerFlat is removed — the drill-down approach replaces it.
  -- The old flat explorer required non-existent /api/assemblies endpoint.

  -- ─── Export Command ──────────────────────────────────────────────────────

  vim.api.nvim_create_user_command("SageFsExportFile", function()
    transport.http_json({
      method = "GET",
      url = helpers.dashboard_url() .. "/api/history",
      timeout = 5,
      callback = function(ok, raw)
        if not ok then
          helpers.notify("Failed to fetch history" .. err_detail(raw), vim.log.levels.ERROR)
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
          helpers.notify("Failed to write " .. path .. err_detail(raw), vim.log.levels.ERROR)
        end
      end,
    })
  end, { desc = "Export session history as .fsx file (to disk)" })

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
          helpers.notify("Failed to fetch callers" .. err_detail(raw), vim.log.levels.ERROR)
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
          helpers.notify("Failed to fetch callees" .. err_detail(raw), vim.log.levels.ERROR)
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

  vim.api.nvim_create_user_command("SageFsStats", function()
    local lines = format.format_stats_lines(plugin.state)
    render.show_float(lines, { title = "SageFs Stats" })
  end, { desc = "Show SageFs runtime statistics" })

  vim.api.nvim_create_user_command("SageFsPlayground", function()
    local name = "SageFs Playground.fsx"
    local existing = vim.fn.bufnr(name)
    if existing ~= -1 then
      vim.api.nvim_set_current_buf(existing)
      helpers.notify("Switched to existing playground", vim.log.levels.INFO)
      return
    end
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, name)
    vim.api.nvim_buf_set_option(buf, "filetype", "fsharp")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "// SageFs Playground — experiment with F# here",
      "// Press <Alt-Enter> to evaluate a cell",
      "",
      "let greeting = \"Hello from SageFs!\";;",
      "",
      "printfn \"%s\" greeting;;",
      "",
      "// Try defining types and functions:",
      "// type Person = { Name: string; Age: int };;",
      "// let alice = { Name = \"Alice\"; Age = 30 };;",
    })
    vim.api.nvim_set_current_buf(buf)
    helpers.notify("Playground ready — evaluate cells with <Alt-Enter>", vim.log.levels.INFO)
  end, { desc = "Open F# scratch playground" })

  vim.api.nvim_create_user_command("SageFsTimeline", function()
    local timeline = require("sagefs.timeline")
    if plugin.timeline_state then
      local chart = timeline.flame_chart(plugin.timeline_state, 80)
      render.show_float(chart, { title = "Eval Timeline" })
    else
      helpers.notify("No evaluations recorded yet", vim.log.levels.INFO)
    end
  end, { desc = "Show eval timeline flame chart" })

  vim.api.nvim_create_user_command("SageFsDiff", function()
    local diff = require("sagefs.diff")
    local buf = vim.api.nvim_get_current_buf()
    local cells_mod = require("sagefs.cells")
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local cell = cells_mod.find_cell(lines, row)
    if not cell then
      helpers.notify("No cell under cursor", vim.log.levels.WARN)
      return
    end
    local cell_id = cell.start_line
    local cell_data = plugin.state.cells[cell_id]
    if not cell_data or not cell_data.prev_output then
      helpers.notify("No previous output to diff", vim.log.levels.INFO)
      return
    end
    local d = diff.diff_lines(cell_data.prev_output, cell_data.output)
    local formatted = diff.format_diff(d)
    local display = { diff.diff_summary(d), string.rep("-", 40) }
    for _, f in ipairs(formatted) do
      display[#display + 1] = f.text
    end
    render.show_float(display, { title = "Eval Diff" })
  end, { desc = "Show diff between last two evals of cell" })

  vim.api.nvim_create_user_command("SageFsScopeMap", function()
    local scope_map = require("sagefs.scope_map")
    if plugin.binding_tracker then
      local cells_mod = require("sagefs.cells")
      local buf = vim.api.nvim_get_current_buf()
      local lines_arr = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local all_cells = cells_mod.find_all_cells(lines_arr)
      local cell_outputs = {}
      for _, c in ipairs(all_cells) do
        local cd = plugin.state.cells[c.start_line]
        if cd then cell_outputs[c.start_line] = cd.output end
      end
      local map = scope_map.build_scope_map(plugin.binding_tracker, all_cells, cell_outputs)
      local panel_lines = scope_map.format_panel(map)
      render.show_float(panel_lines, { title = "Binding Scope Map" })
    else
      helpers.notify("No bindings tracked yet", vim.log.levels.INFO)
    end
  end, { desc = "Show binding scope map" })

  vim.api.nvim_create_user_command("SageFsArrows", function()
    local depgraph = require("sagefs.depgraph")
    local depgraph_viz = require("sagefs.depgraph_viz")
    local cells_mod = require("sagefs.cells")
    local buf = vim.api.nvim_get_current_buf()
    local lines_arr = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local all_cells = cells_mod.find_all_cells(lines_arr)
    local cells_data, cells_layout = {}, {}
    for _, c in ipairs(all_cells) do
      local cd = plugin.state.cells[c.start_line]
      cells_data[#cells_data + 1] = {
        id = c.start_line,
        source = table.concat(c.lines or {}, "\n"),
        output = cd and cd.output or "",
      }
      cells_layout[c.start_line] = { start_line = c.start_line, end_line = c.end_line }
    end
    local graph = depgraph.build_graph(cells_data)
    local arrows = depgraph_viz.compute_arrows(graph, cells_layout)
    local panel_lines = depgraph_viz.format_panel(arrows, cells_layout)
    render.show_float(panel_lines, { title = "Dependency Arrows" })
  end, { desc = "Visualize cross-cell dependency arrows" })

  vim.api.nvim_create_user_command("SageFsHistory", function()
    local time_travel = require("sagefs.time_travel")
    local cells_mod = require("sagefs.cells")
    local buf = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local lines_arr = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local cell = cells_mod.find_cell(lines_arr, row)
    if not cell then
      helpers.notify("No cell under cursor", vim.log.levels.WARN)
      return
    end
    if not plugin.time_travel_state then
      helpers.notify("No eval history yet", vim.log.levels.INFO)
      return
    end
    local cell_id = cell.start_line
    local count = time_travel.history_count(plugin.time_travel_state, cell_id)
    if count == 0 then
      helpers.notify("No history for this cell", vim.log.levels.INFO)
      return
    end
    local display = { string.format("═══ Cell History (%d evals) ═══", count), "" }
    for i = count, 1, -1 do
      local nav = time_travel.navigate(plugin.time_travel_state, cell_id, i - count)
      local marker = i == count and " ◀ current" or ""
      display[#display + 1] = string.format("─── eval %d/%d (%dms)%s ───",
        nav.index, nav.total, nav.duration_ms, marker)
      for line in (nav.output or ""):gmatch("[^\n]+") do
        display[#display + 1] = "  " .. line
      end
    end
    render.show_float(display, { title = "Eval History" })
  end, { desc = "Show eval history for cell under cursor" })

  vim.api.nvim_create_user_command("SageFsTypeFlow", function()
    local depgraph = require("sagefs.depgraph")
    local type_flow = require("sagefs.type_flow")
    local cells_mod = require("sagefs.cells")
    local buf = vim.api.nvim_get_current_buf()
    local lines_arr = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local all_cells = cells_mod.find_all_cells(lines_arr)
    local cells_data, cell_outputs = {}, {}
    for _, c in ipairs(all_cells) do
      local cd = plugin.state.cells[c.start_line]
      cells_data[#cells_data + 1] = {
        id = c.start_line,
        source = table.concat(c.lines or {}, "\n"),
        output = cd and cd.output or "",
      }
      if cd then cell_outputs[c.start_line] = cd.output end
    end
    local graph = depgraph.build_graph(cells_data)
    local flows = type_flow.all_flows(graph, cell_outputs)
    if #flows == 0 then
      helpers.notify("No cross-cell type flows detected", vim.log.levels.INFO)
      return
    end
    local display = { string.format("═══ Type Flow (%d bindings) ═══", #flows), "" }
    for _, flow in ipairs(flows) do
      display[#display + 1] = type_flow.format_flow_path(flow)
    end
    render.show_float(display, { title = "Type Flow" })
  end, { desc = "Show cross-cell type flow" })

  vim.api.nvim_create_user_command("SageFsNotebook", function(opts)
    local notebook = require("sagefs.notebook")
    local cells_mod = require("sagefs.cells")
    local buf = vim.api.nvim_get_current_buf()
    local lines_arr = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local all_cells = cells_mod.find_all_cells(lines_arr)
    local nb_cells = {}
    for _, c in ipairs(all_cells) do
      local cd = plugin.state.cells[c.start_line]
      local source = table.concat(c.lines or {}, "\n")
      nb_cells[#nb_cells + 1] = {
        source = source,
        output = cd and cd.output or nil,
        duration_ms = cd and cd.duration_ms or nil,
        status = cd and cd.status or nil,
      }
    end
    local content = notebook.export_notebook(nb_cells, {
      project = plugin.active_session and plugin.active_session.name or "",
    })
    local fname = opts.args ~= "" and opts.args or "session_notebook.fsx"
    vim.fn.writefile(vim.split(content, "\n"), fname)
    helpers.notify("Exported notebook: " .. fname, vim.log.levels.INFO)
  end, { desc = "Export session as literate .fsx notebook", nargs = "?" })
end

--- Register keymaps
---@param plugin table  The sagefs plugin module
---@param helpers table  { smart_eval: fun(fn): fun(), clear_and_render: fun() }
function M.register_keymaps(plugin, helpers)
  local smart_eval = helpers.smart_eval(function() plugin.eval_cell() end)
  local smart_eval_sel = helpers.smart_eval(function() plugin.eval_selection() end)
  local hotreload = require("sagefs.hotreload")

  -- Alt-Enter keymaps (no prefix, always available)
  vim.keymap.set("n", "<A-CR>", smart_eval,
    { desc = "SageFs: Evaluate cell", silent = true })
  vim.keymap.set("v", "<A-CR>", smart_eval_sel,
    { desc = "SageFs: Evaluate selection", silent = true })
  vim.keymap.set("n", "<S-A-CR>", function() plugin.eval_cell_and_advance() end,
    { desc = "SageFs: Evaluate cell and advance", silent = true })

  -- Core eval
  vim.keymap.set("n", "<leader>re", smart_eval,
    { desc = "SageFs: Evaluate cell", silent = true })
  vim.keymap.set("n", "<leader>rl", function() plugin.eval_current_line() end,
    { desc = "SageFs: Evaluate current line", silent = true })
  vim.keymap.set("n", "<leader>rf", "<cmd>SageFsEvalFile<CR>",
    { desc = "SageFs: Evaluate file", silent = true })
  vim.keymap.set("n", "<leader>rc", function()
    helpers.clear_and_render()
  end, { desc = "SageFs: Clear results", silent = true })
  vim.keymap.set("n", "<leader>rx", "<cmd>SageFsCancel<CR>",
    { desc = "SageFs: Cancel eval", silent = true })

  -- Sessions & connection
  vim.keymap.set("n", "<leader>rs", function() plugin.session_picker() end,
    { desc = "SageFs: Sessions", silent = true })
  vim.keymap.set("n", "<leader>rC", "<cmd>SageFsConnect<CR>",
    { desc = "SageFs: Connect", silent = true })
  vim.keymap.set("n", "<leader>rX", "<cmd>SageFsDisconnect<CR>",
    { desc = "SageFs: Disconnect", silent = true })
  vim.keymap.set("n", "<leader>ri", "<cmd>SageFsStatus<CR>",
    { desc = "SageFs: Status info", silent = true })

  -- Testing
  vim.keymap.set("n", "<leader>rt", "<cmd>SageFsTestPanel<CR>",
    { desc = "SageFs: Test panel", silent = true })
  vim.keymap.set("n", "<leader>rT", "<cmd>SageFsRunTests<CR>",
    { desc = "SageFs: Run tests", silent = true })
  vim.keymap.set("n", "<leader>rth", "<cmd>SageFsTestsHere<CR>",
    { desc = "SageFs: Tests here (file)", silent = true })
  vim.keymap.set("n", "<leader>rtf", "<cmd>SageFsFailures<CR>",
    { desc = "SageFs: Test failures", silent = true })
  vim.keymap.set("n", "<leader>rtp", "<cmd>SageFsTestTrace<CR>",
    { desc = "SageFs: test trace", silent = true })
  vim.keymap.set("n", "<leader>rte", "<cmd>SageFsEnableTesting<CR>",
    { desc = "SageFs: Enable testing", silent = true })
  vim.keymap.set("n", "<leader>rtd", "<cmd>SageFsDisableTesting<CR>",
    { desc = "SageFs: Disable testing", silent = true })

  -- Browse & explore
  vim.keymap.set("n", "<leader>rb", "<cmd>SageFsBindings<CR>",
    { desc = "SageFs: Show bindings", silent = true })
  vim.keymap.set("n", "<leader>rd", "<cmd>SageFsDiff<CR>",
    { desc = "SageFs: Eval diff", silent = true })
  vim.keymap.set("n", "<leader>rg", "<cmd>SageFsScopeMap<CR>",
    { desc = "SageFs: Scope map", silent = true })
  vim.keymap.set("n", "<leader>rm", "<cmd>SageFsTimeline<CR>",
    { desc = "SageFs: Timeline", silent = true })
  vim.keymap.set("n", "<leader>ry", "<cmd>SageFsTypeExplorer<CR>",
    { desc = "SageFs: Type explorer", silent = true })
  vim.keymap.set("n", "<leader>ra", "<cmd>SageFsCallers<CR>",
    { desc = "SageFs: Callers", silent = true })
  vim.keymap.set("n", "<leader>ro", "<cmd>SageFsCallees<CR>",
    { desc = "SageFs: Callees", silent = true })
  vim.keymap.set("n", "<leader>rv", "<cmd>SageFsCoverage<CR>",
    { desc = "SageFs: Coverage", silent = true })

  -- Server & reload
  vim.keymap.set("n", "<leader>rh", function()
    local sid = plugin.active_session and plugin.active_session.id or nil
    hotreload.picker(sid)
  end, { desc = "SageFs: Hot reload files", silent = true })
  vim.keymap.set("n", "<leader>rr", "<cmd>SageFsReset<CR>",
    { desc = "SageFs: Soft reset", silent = true })
  vim.keymap.set("n", "<leader>rR", "<cmd>SageFsHardReset<CR>",
    { desc = "SageFs: Hard reset", silent = true })
  vim.keymap.set("n", "<leader>rS", "<cmd>SageFsStart<CR>",
    { desc = "SageFs: Start server", silent = true })
  vim.keymap.set("n", "<leader>rQ", "<cmd>SageFsStop<CR>",
    { desc = "SageFs: Stop server", silent = true })
  vim.keymap.set("n", "<leader>rD", function()
    local dens = require("sagefs.density")
    plugin.density_state = dens.cycle(plugin.density_state)
    vim.notify("[SageFs] Density: " .. plugin.density_state.preset, vim.log.levels.INFO)
    helpers.render_signs(vim.api.nvim_get_current_buf())
  end, { desc = "SageFs: Cycle density (minimal/normal/full)", silent = true })

  -- Misc
  vim.keymap.set("n", "<leader>rp", "<cmd>SageFsPlayground<CR>",
    { desc = "SageFs: Playground", silent = true })
  vim.keymap.set("n", "<leader>rn", "<cmd>SageFsNotebook<CR>",
    { desc = "SageFs: Notebook export", silent = true })
  vim.keymap.set("n", "<leader>rw", "<cmd>SageFsWatchAll<CR>",
    { desc = "SageFs: Watch all files", silent = true })
  vim.keymap.set("n", "<leader>rW", "<cmd>SageFsUnwatchAll<CR>",
    { desc = "SageFs: Unwatch all files", silent = true })
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

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.fsx",
    callback = function(ev)
      if not helpers.check_on_save() then return end
      local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
      helpers.check_code(table.concat(lines, "\n"))
    end,
  })

  -- Cell highlight: show eval region as cursor moves
  local cell_highlight = require("sagefs.cell_highlight")

  vim.api.nvim_create_autocmd(
    { "CursorMoved", "CursorMovedI" },
    {
      group = group,
      pattern = { "*.fs", "*.fsx" },
      callback = function()
        cell_highlight.update()
      end,
    }
  )

  vim.api.nvim_create_autocmd(
    { "TextChanged", "TextChangedI" },
    {
      group = group,
      pattern = { "*.fs", "*.fsx" },
      callback = function()
        cell_highlight.update(true)
      end,
    }
  )

  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    pattern = { "*.fs", "*.fsx" },
    callback = function()
      cell_highlight.update()
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    pattern = { "*.fs", "*.fsx" },
    callback = function(ev)
      cell_highlight.clear(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      cell_highlight.setup_highlights()
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      local render = require("sagefs.render")
      render.clear_sign_cache(ev.buf)
    end,
  })
end

return M
