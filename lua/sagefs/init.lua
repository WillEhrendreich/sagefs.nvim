-- sagefs/init.lua — Thin coordinator for SageFs Neovim plugin
-- Wires pure modules to transport, render, and commands layers.

local cells = require("sagefs.cells")
local format = require("sagefs.format")
local model = require("sagefs.model")
local sessions = require("sagefs.sessions")
local sse_parser = require("sagefs.sse")
local hotreload = require("sagefs.hotreload")
local diagnostics = require("sagefs.diagnostics")
local testing = require("sagefs.testing")
local coverage = require("sagefs.coverage")
local events = require("sagefs.events")
local completions = require("sagefs.completions")
local daemon = require("sagefs.daemon")
local transport = require("sagefs.transport")
local render = require("sagefs.render")
local commands = require("sagefs.commands")

local M = {}

M.version = require("sagefs.version")

-- ─── Configuration ───────────────────────────────────────────────────────────

M.config = {
  port = 37749,
  dashboard_port = 37750,
  auto_connect = true,
  check_on_save = false,
  highlight = {
    success = { fg = "#a6e3a1", italic = true },
    error = { fg = "#f38ba8", italic = true },
    output = { fg = "#a6adc8", italic = true },
    running = { fg = "#f9e2af" },
    stale = { fg = "#6c7086", italic = true },
  },
}

-- ─── State ───────────────────────────────────────────────────────────────────

M.state = model.new()
M.testing_state = testing.new()
M.coverage_state = coverage.new()
M.daemon_state = daemon.new()
M.active_session = nil
M.session_list = {}

-- SSE connection handle (managed by transport.lua)
local events_sse = nil
local diag_ns = nil

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function base_url()
  return "http://localhost:" .. M.config.port
end

local function dashboard_url()
  return "http://localhost:" .. M.config.dashboard_port
end

local function notify(msg, level)
  vim.notify("[SageFs] " .. msg, level or vim.log.levels.INFO)
end

-- ─── SSE Dispatch ─────────────────────────────────────────────────────────────

local function decode_event_data(event)
  if not event.data then return nil end
  local ok, data = pcall(vim.json.decode, event.data)
  return ok and data or nil
end

local function fire_user_event(event_type, payload)
  local evt = events.build_autocmd_data(event_type, payload)
  if evt then
    vim.schedule(function()
      pcall(vim.api.nvim_exec_autocmds, "User", { pattern = evt.pattern, data = evt.data })
    end)
  end
end

-- Dispatch table: action string → handler(raw_event)
-- Each handler receives the raw SSE event and decodes data as needed.
local dispatch_table

local function build_handlers()
  return sse_parser.build_dispatch_table({
    state_update = function(raw)
      M.state = model.set_status(M.state, "connected")
    end,

    -- Testing pipeline
    tests_discovered = function(raw)
      local data = decode_event_data(raw)
      if data then M.testing_state = testing.handle_tests_discovered(M.testing_state, data) end
    end,
    test_results_batch = function(raw)
      local data = decode_event_data(raw)
      if not data then return end
      M.testing_state = testing.handle_results_batch(M.testing_state, data)
      -- Fire per-test pass/fail events (enriched or legacy)
      local entries = data.Entries or data.entries or data.results
      if entries then
        for _, r in ipairs(entries) do
          local entry = testing.normalize_entry(r)
          local status = entry.status or entry.Status
          if status == "Passed" then
            fire_user_event("test_passed", entry)
          elseif status == "Failed" then
            fire_user_event("test_failed", entry)
          end
        end
      end
      -- Update test diagnostics for current buffer
      vim.schedule(function()
        local buf = vim.api.nvim_get_current_buf()
        local file = vim.api.nvim_buf_get_name(buf)
        if file and file ~= "" then
          local test_ns = vim.api.nvim_create_namespace("sagefs_test_diagnostics")
          local diags = testing.to_diagnostics(M.testing_state, file)
          vim.diagnostic.set(test_ns, buf, diags)
        end
      end)
    end,
    test_run_started = function(raw)
      local data = decode_event_data(raw)
      if data then
        M.testing_state = testing.handle_test_run_started(M.testing_state, data)
        fire_user_event("test_run_started", data)
      end
    end,
    test_run_completed = function(raw)
      local data = decode_event_data(raw)
      if data then
        M.testing_state = testing.handle_test_run_completed(M.testing_state, data)
        fire_user_event("test_run_completed", data)
      end
    end,
    live_testing_toggled = function(raw)
      local data = decode_event_data(raw)
      if data then M.testing_state = testing.handle_live_testing_toggled(M.testing_state, data) end
    end,
    run_policy_changed = function(raw)
      local data = decode_event_data(raw)
      if data then M.testing_state = testing.handle_run_policy_changed(M.testing_state, data) end
    end,
    test_locations_detected = function(raw)
      local data = decode_event_data(raw)
      if data then M.testing_state = testing.handle_test_locations(M.testing_state, data) end
    end,
    providers_detected = function(raw)
      local data = decode_event_data(raw)
      if data then
        M.testing_state = testing.handle_providers_detected(M.testing_state, data)
        fire_user_event("providers_detected", data)
      end
    end,
    affected_tests_computed = function(raw)
      local data = decode_event_data(raw)
      if data then fire_user_event("affected_tests_computed", data) end
    end,
    pipeline_timing_recorded = function(raw)
      local data = decode_event_data(raw)
      if data then fire_user_event("pipeline_timing_recorded", data) end
    end,
    run_tests_requested = function(raw)
      local data = decode_event_data(raw)
      if data then fire_user_event("run_tests_requested", data) end
    end,
    test_summary = function(raw)
      local data = decode_event_data(raw)
      if data then
        M.testing_state = testing.handle_test_summary(M.testing_state, data)
        fire_user_event("test_summary", data)
      end
    end,

    -- Coverage
    coverage_updated = function(raw)
      local data = decode_event_data(raw)
      if not data then return end
      local parsed = coverage.parse_coverage_response(vim.fn.json_encode(data))
      if parsed then
        M.coverage_state = coverage.apply_coverage_response(M.coverage_state, parsed)
        fire_user_event("coverage_updated", data)
      end
    end,
    coverage_cleared = function(raw)
      M.coverage_state = coverage.clear(M.coverage_state)
    end,

    -- Session lifecycle
    eval_completed = function(raw)
      local data = decode_event_data(raw)
      fire_user_event("eval_completed", data)
    end,
    hot_reload_triggered = function(raw)
      local data = decode_event_data(raw)
      fire_user_event("hot_reload_triggered", data)
    end,

    -- Diagnostics (from main SSE stream)
    diagnostics_updated = function(raw)
      local data = decode_event_data(raw)
      if data and data.diagnostics then
        M.apply_diagnostics(data.diagnostics)
      end
    end,
  })
end

local function on_sse_events(raw_events)
  if not dispatch_table then
    dispatch_table = build_handlers()
  end

  local classified = {}
  for _, event in ipairs(raw_events) do
    local c = sse_parser.classify_event(event)
    if c then
      -- Pass original event as data so handlers get the raw SSE event
      table.insert(classified, { action = c.action, data = event })
    end
  end

  local errors = sse_parser.safe_dispatch_batch(dispatch_table, classified)
  for _, e in ipairs(errors) do
    vim.schedule(function()
      vim.notify(string.format("[SageFs] SSE handler error (%s): %s", e.action, tostring(e.err)),
        vim.log.levels.WARN)
    end)
  end

  -- Refresh gutter signs for current buffer after processing events
  vim.schedule(function()
    local buf = vim.api.nvim_get_current_buf()
    render.render_test_signs(buf, M.testing_state)
    render.render_coverage_signs(buf, M.coverage_state)
  end)
end

-- ─── SSE Lifecycle ────────────────────────────────────────────────────────────

local function start_sse()
  -- Primary events SSE
  if events_sse then events_sse.stop() end
  events_sse = transport.connect_sse(base_url() .. "/events", {
    on_events = function(events)
      on_sse_events(events)
    end,
    on_connect = function()
      M.state = model.set_status(M.state, "connected")
      fire_user_event("connected")
      -- Test state recovery on (re)connect
      -- Note: /api/live-test-status is not an HTTP endpoint — it's only available
      -- as an MCP tool (get_live_test_status). Recovery will be enabled once SageFs
      -- adds an HTTP endpoint for test status, or sends typed events over SSE.
      if M.testing_state.enabled then
        fire_user_event("test_recovery_needed")
      end
    end,
    on_disconnect = function()
      M.state = model.set_status(M.state, "disconnected")
      fire_user_event("disconnected")
    end,
    auto_reconnect = true,
    reconnect_delay = 3000,
  })
  events_sse.start()
end

local function stop_sse()
  if events_sse then events_sse.stop(); events_sse = nil end
  if diag_ns then vim.diagnostic.reset(diag_ns) end
  M.state = model.set_status(M.state, "disconnected")
  fire_user_event("disconnected")
end

-- ─── Diagnostics ─────────────────────────────────────────────────────────────

function M.apply_diagnostics(diags)
  diag_ns = diag_ns or vim.api.nvim_create_namespace("sagefs_diagnostics")
  local grouped = diagnostics.group_by_file(diags)
  for file, file_diags in pairs(grouped) do
    local vim_diags = diagnostics.to_vim_diagnostics(file_diags)
    local bufnr = vim.fn.bufnr(file)
    if bufnr ~= -1 then
      vim.diagnostic.set(diag_ns, bufnr, vim_diags)
    end
  end
end

-- ─── HTTP: eval + session API ─────────────────────────────────────────────────

local function handle_result(buf, cell_id, result)
  if result.ok then
    M.state = model.set_cell_state(M.state, cell_id, "success", result.output)
  else
    M.state = model.set_cell_state(M.state, cell_id, "error", result.error)
  end
  vim.schedule(function()
    render.render_all(buf, M.state)
  end)
end

local function post_exec(code, buf, cell_id)
  transport.http_json({
    method = "POST",
    url = base_url() .. "/exec",
    body = { code = code, working_directory = vim.fn.getcwd() },
    timeout = 60,
    callback = function(ok, raw)
      if ok then
        local result = format.parse_exec_response(raw)
        handle_result(buf, cell_id, result)
      else
        handle_result(buf, cell_id, { ok = false, error = "HTTP request failed" })
      end
    end,
  })
end

local function session_http(method, path, body, callback)
  transport.http_json({
    method = method,
    url = base_url() .. path,
    body = body,
    timeout = 5,
    callback = callback,
  })
end

-- ─── Eval Functions ───────────────────────────────────────────────────────────

function M.eval_cell()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cell = cells.find_cell(lines, cursor_line)

  if not cell then
    notify("No cell found at cursor", vim.log.levels.WARN)
    return
  end

  local code = cells.prepare_code(cell.text)
  if not code then
    notify("Cell is empty", vim.log.levels.WARN)
    return
  end

  local all = cells.find_all_cells(lines)
  local cell_id = 1
  for _, c in ipairs(all) do
    if c.start_line == cell.start_line then
      cell_id = c.id
      break
    end
  end

  M.state = model.set_cell_state(M.state, cell_id, "running")
  render.render_all(buf, M.state)
  render.flash_cell(buf, cell.start_line, cell.end_line)
  post_exec(code, buf, cell_id)
end

function M.eval_cell_and_advance()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local cell = cells.find_cell(lines, cursor_line)
  if not cell then
    notify("No cell found at cursor", vim.log.levels.WARN)
    return
  end

  local code = cells.prepare_code(cell.text)
  if not code then
    notify("Cell is empty", vim.log.levels.WARN)
    return
  end

  local all = cells.find_all_cells(lines)
  local cell_id = 1
  for _, c in ipairs(all) do
    if c.start_line == cell.start_line then
      cell_id = c.id
      break
    end
  end

  M.state = model.set_cell_state(M.state, cell_id, "running")
  render.render_all(buf, M.state)
  render.flash_cell(buf, cell.start_line, cell.end_line)
  post_exec(code, buf, cell_id)

  -- Move cursor to next cell start
  local next_start = cells.find_next_cell_start(lines, cursor_line)
  if next_start then
    vim.api.nvim_win_set_cursor(0, { next_start, 0 })
  end
end

function M.eval_selection()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)

  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local buf = vim.api.nvim_get_current_buf()

  local sel_lines = vim.api.nvim_buf_get_lines(buf, start_pos[2] - 1, end_pos[2], false)
  local text = table.concat(sel_lines, "\n")
  local code = cells.prepare_code(text)

  if not code then
    notify("Selection is empty", vim.log.levels.WARN)
    return
  end

  M.state = model.set_cell_state(M.state, 0, "running")
  render.flash_cell(buf, start_pos[2], end_pos[2])
  post_exec(code, buf, 0)
end

function M.eval_file()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  local code = cells.prepare_code(text)

  if not code then
    notify("File is empty", vim.log.levels.WARN)
    return
  end

  notify("Evaluating file: " .. vim.fn.expand("%:t"))
  M.state = model.set_cell_state(M.state, 0, "running")
  render.flash_cell(buf, 1, #lines)
  post_exec(code, buf, 0)
end

-- ─── Code Completion ─────────────────────────────────────────────────────────

function M.omnifunc(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.fn.col(".") - 1
    while col > 0 and line:sub(col, col):match("[%w_]") do
      col = col - 1
    end
    M._completion_col = col
    return col
  end

  -- Async: fire HTTP request, call vim.fn.complete() when results arrive
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  local cursor = vim.api.nvim_win_get_cursor(0)
  local offset = 0
  for i = 1, cursor[1] - 1 do
    offset = offset + #lines[i] + 1
  end
  offset = offset + cursor[2]

  local body = completions.build_request_body(text, offset, vim.fn.getcwd())
  local col = (M._completion_col or 0) + 1

  transport.http_json({
    method = "POST",
    url = dashboard_url() .. "/dashboard/completions",
    body = body,
    timeout = 5,
    callback = function(ok, raw)
      if not ok or not raw then return end
      vim.schedule(function()
        local items = completions.parse_response(raw)
        if #items > 0 then
          vim.fn.complete(col, items)
        end
      end)
    end,
  })

  -- Return empty — results arrive asynchronously via vim.fn.complete()
  return {}
end

-- ─── Session API ──────────────────────────────────────────────────────────────

function M.list_sessions(callback)
  session_http("GET", "/api/sessions", nil, function(ok, raw)
    local result = sessions.parse_sessions_response(ok and raw or nil)
    if result.ok then
      M.session_list = result.sessions
      local cwd_session = sessions.find_session_for_dir(result.sessions, vim.fn.getcwd())
      if cwd_session then
        M.active_session = cwd_session
      end
    end
    if callback then callback(result) end
  end)
end

function M.create_session(projects, working_dir, callback)
  working_dir = working_dir or vim.fn.getcwd()
  session_http("POST", "/api/sessions/create", {
    projects = projects,
    workingDirectory = working_dir,
  }, function(ok, raw)
    local result = sessions.parse_action_response(ok and raw or nil)
    if result.ok then
      notify(result.message or "Session created")
      M.list_sessions()
    else
      notify(result.error or "Failed to create session", vim.log.levels.ERROR)
    end
    if callback then callback(result) end
  end)
end

function M.switch_session(session_id, callback)
  session_http("POST", "/api/sessions/switch", {
    sessionId = session_id,
  }, function(ok, raw)
    local result = sessions.parse_action_response(ok and raw or nil)
    if result.ok then
      notify("Switched to session " .. (result.session_id or session_id))
      M.list_sessions()
    else
      notify(result.error or "Failed to switch", vim.log.levels.ERROR)
    end
    if callback then callback(result) end
  end)
end

function M.stop_session(session_id, callback)
  session_http("POST", "/api/sessions/stop", {
    sessionId = session_id,
  }, function(ok, raw)
    local result = sessions.parse_action_response(ok and raw or nil)
    if result.ok then
      notify(result.message or "Session stopped")
      if M.active_session and M.active_session.id == session_id then
        M.active_session = nil
      end
      M.list_sessions()
    else
      notify(result.error or "Failed to stop session", vim.log.levels.ERROR)
    end
    if callback then callback(result) end
  end)
end

function M.reset_session(callback)
  session_http("POST", "/reset", {}, function(ok, raw)
    if ok then notify("Session reset")
    else notify("Failed to reset session", vim.log.levels.ERROR) end
    if callback then callback(ok) end
  end)
end

function M.hard_reset(callback)
  session_http("POST", "/hard-reset", { rebuild = true }, function(ok, raw)
    if ok then notify("Hard reset complete (rebuild)")
    else notify("Failed to hard reset", vim.log.levels.ERROR) end
    if callback then callback(ok) end
  end)
end

-- ─── Session Context ─────────────────────────────────────────────────────────

function M.show_session_context()
  local sid = M.active_session and M.active_session.id or nil
  if not sid then
    notify("No active session", vim.log.levels.WARN)
    return
  end
  transport.http_json({
    method = "GET",
    url = string.format("http://localhost:%d/api/sessions/%s/warmup-context",
      M.config.dashboard_port, sid),
    timeout = 5,
    callback = function(ok, raw)
      if not ok or raw == "" then
        notify("Failed to fetch session context", vim.log.levels.ERROR)
        return
      end
      local parse_ok, ctx = pcall(vim.json.decode, raw)
      if not parse_ok or type(ctx) ~= "table" then
        notify("Invalid session context response", vim.log.levels.ERROR)
        return
      end
      local lines = { "SageFs Session Context", string.rep("─", 40) }
      table.insert(lines, string.format("Session: %s", sid))
      if ctx.WarmupDurationMs then
        table.insert(lines, string.format("Warmup: %dms", ctx.WarmupDurationMs))
      end
      if ctx.AssembliesLoaded then
        table.insert(lines, "")
        table.insert(lines, string.format("Assemblies (%d):", #ctx.AssembliesLoaded))
        for _, a in ipairs(ctx.AssembliesLoaded) do
          table.insert(lines, string.format("  %s (%d ns, %d mod)",
            a.Name or "?", a.NamespaceCount or 0, a.ModuleCount or 0))
        end
      end
      if ctx.NamespacesOpened then
        table.insert(lines, "")
        table.insert(lines, string.format("Namespaces Opened (%d):", #ctx.NamespacesOpened))
        for _, n in ipairs(ctx.NamespacesOpened) do
          local kind = n.IsModule and "module" or "namespace"
          table.insert(lines, string.format("  %s (%s, %s)",
            n.Name or "?", kind, n.Source or "?"))
        end
      end
      if ctx.FailedOpens and #ctx.FailedOpens > 0 then
        table.insert(lines, "")
        table.insert(lines, string.format("Failed Opens (%d):", #ctx.FailedOpens))
        for _, f in ipairs(ctx.FailedOpens) do
          if type(f) == "table" then
            table.insert(lines, "  " .. table.concat(f, " → "))
          else
            table.insert(lines, "  " .. tostring(f))
          end
        end
      end
      render.show_float(lines, { title = "Session Context" })
    end,
  })
end

-- ─── Session Picker ──────────────────────────────────────────────────────────

function M.session_picker()
  M.list_sessions(function(result)
    if not result.ok then
      notify("Failed to list sessions: " .. (result.error or ""), vim.log.levels.ERROR)
      return
    end

    local items = {}
    local lookup = {}
    for _, s in ipairs(result.sessions) do
      local line = sessions.format_session_line(s)
      table.insert(items, line)
      lookup[line] = s
    end

    local create_label = "+ Create new session..."
    table.insert(items, create_label)

    vim.ui.select(items, { prompt = "SageFs Sessions:" }, function(choice)
      if not choice then return end
      if choice == create_label then
        M.discover_and_create()
        return
      end

      local session = lookup[choice]
      if not session then return end

      local actions = sessions.session_actions(session)
      local action_labels = {}
      for _, a in ipairs(actions) do
        table.insert(action_labels, a.label)
      end

      vim.ui.select(action_labels, {
        prompt = session.id .. ":",
      }, function(action_choice)
        if not action_choice then return end
        for _, a in ipairs(actions) do
          if a.label == action_choice then
            if a.name == "switch" then M.switch_session(session.id)
            elseif a.name == "stop" then M.stop_session(session.id)
            elseif a.name == "reset" then M.reset_session()
            elseif a.name == "hard_reset" then M.hard_reset()
            elseif a.name == "create" then M.discover_and_create()
            end
            return
          end
        end
      end)
    end)
  end)
end

function M.discover_and_create(working_dir)
  working_dir = working_dir or vim.fn.getcwd()
  local fsproj_files = vim.fn.glob(working_dir .. "/**/*.fsproj", false, true)

  if #fsproj_files == 0 then
    notify("No .fsproj files found in " .. working_dir, vim.log.levels.WARN)
    return
  end

  local items = {}
  for _, path in ipairs(fsproj_files) do
    table.insert(items, path:sub(#working_dir + 2))
  end

  vim.ui.select(items, { prompt = "Select project to load:" }, function(choice)
    if not choice then return end
    M.create_session({ choice }, working_dir)
  end)
end

-- ─── Check on Save ────────────────────────────────────────────────────────────

local function check_code(code)
  transport.http_json({
    method = "POST",
    url = base_url() .. "/diagnostics",
    body = { code = code },
    timeout = 10,
    callback = function() end, -- fire-and-forget; diagnostics arrive via SSE
  })
end

-- ─── Smart Eval ───────────────────────────────────────────────────────────────

local function smart_eval_with_session_check(eval_fn)
  return function()
    if M.active_session then
      eval_fn()
      return
    end

    M.list_sessions(function(result)
      if result.ok and #result.sessions > 0 then
        local cwd_session = sessions.find_session_for_dir(result.sessions, vim.fn.getcwd())
        if cwd_session then
          M.active_session = cwd_session
          eval_fn()
          return
        end
      end

      notify("No active session for this directory", vim.log.levels.WARN)
      vim.ui.select({ "Create session now", "Cancel" }, {
        prompt = "No SageFs session found. Create one?",
      }, function(choice)
        if choice == "Create session now" then
          M.discover_and_create(vim.fn.getcwd())
        end
      end)
    end)
  end
end

-- ─── Health Check & Statusline ────────────────────────────────────────────────

function M.health_check(callback)
  transport.http_json({
    method = "GET",
    url = base_url() .. "/health",
    timeout = 2,
    callback = function(ok, raw)
      vim.schedule(function()
        if ok and raw and raw:match('"healthy"') then
          notify("Connected to SageFs on port " .. M.config.port)
          if callback then callback(true) end
        elseif ok and raw and (raw:match('"error"') or raw:match('"success"')) then
          notify("SageFs reachable (no session for this directory)")
          if callback then callback(true) end
        else
          notify("SageFs not available on port " .. M.config.port .. ". Run :SageFsStart or start SageFs externally.", vim.log.levels.ERROR)
          if callback then callback(false) end
        end
      end)
    end,
  })
end

function M.statusline()
  local parts = {}

  if M.active_session then
    table.insert(parts, sessions.format_statusline(M.active_session))
  else
    local icon = M.state.status == "connected" and "⚡" or "💤"
    local cell_count = model.cell_count(M.state)
    if cell_count > 0 then
      table.insert(parts, icon .. " SageFs [" .. cell_count .. "]")
    else
      table.insert(parts, icon .. " SageFs")
    end
  end

  local test_sl = testing.format_statusline(M.testing_state)
  if test_sl ~= "" then table.insert(parts, test_sl) end

  local cov_sl = coverage.format_statusline(M.coverage_state)
  if cov_sl ~= "" then table.insert(parts, cov_sl) end

  return table.concat(parts, " │ ")
end

-- ─── Setup ───────────────────────────────────────────────────────────────────

function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", M.config, opts)
  M.config.port = tonumber(vim.env.SAGEFS_MCP_PORT) or M.config.port

  render.get_namespace()
  render.setup_highlights(M.config.highlight)

  -- Helper closures that commands/keymaps/autocmds need
  local helpers = {
    notify = notify,
    start_sse = start_sse,
    stop_sse = stop_sse,
    base_url = function() return "http://localhost:" .. M.config.port end,
    dashboard_url = function() return "http://localhost:" .. M.config.dashboard_port end,
    clear_and_render = function()
      M.state = model.clear_cells(M.state)
      render.clear_extmarks(vim.api.nvim_get_current_buf())
      notify("Cleared all results")
    end,
    smart_eval = smart_eval_with_session_check,
    mark_stale_and_render = function(buf)
      M.state = model.mark_all_stale(M.state)
      render.render_all(buf, M.state)
    end,
    render_all = function(buf)
      render.render_all(buf, M.state)
    end,
    render_signs = function(buf)
      render.render_test_signs(buf, M.testing_state)
      render.render_coverage_signs(buf, M.coverage_state)
    end,
    check_code = check_code,
    check_on_save = function() return M.config.check_on_save end,
  }

  commands.register_commands(M, helpers)
  commands.register_keymaps(M, helpers)
  commands.register_autocmds(M, helpers)
  hotreload.setup(M.config.dashboard_port)

  if M.config.auto_connect then
    vim.defer_fn(function()
      M.health_check(function(healthy)
        if healthy then
          start_sse()
          M.list_sessions(function(result)
            if result.ok and not M.active_session and #result.sessions == 0 then
              local fsproj_files = vim.fn.glob(vim.fn.getcwd() .. "/**/*.fsproj", false, true)
              if #fsproj_files > 0 then
                local names = {}
                for _, f in ipairs(fsproj_files) do
                  table.insert(names, vim.fn.fnamemodify(f, ":~:."))
                end
                vim.ui.select(names, { prompt = "SageFs: Create session with project:" }, function(choice)
                  if choice then M.create_session(choice) end
                end)
              end
            end
          end)
        end
      end)
    end, 500)
  end

  _G.SageFs = M
end

return M
