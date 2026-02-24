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
local transport = require("sagefs.transport")
local render = require("sagefs.render")
local commands = require("sagefs.commands")

local M = {}

-- ─── Configuration ───────────────────────────────────────────────────────────

M.config = {
  port = 37749,
  dashboard_port = 37750,
  auto_connect = true,
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
M.active_session = nil
M.session_list = {}

-- SSE connection handles (managed by transport.lua)
local events_sse = nil
local diag_sse = nil
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

local function on_sse_events(events)
  for _, event in ipairs(events) do
    local action = sse_parser.classify_event(event)
    if action == "state_changed" then
      M.state = model.set_status(M.state, "connected")
    elseif action == "tests_discovered" then
      local ok, data = pcall(vim.json.decode, event.data)
      if ok and data then
        M.testing_state = testing.handle_tests_discovered(M.testing_state, data)
      end
    elseif action == "test_result" then
      local ok, data = pcall(vim.json.decode, event.data)
      if ok and data then
        M.testing_state = testing.handle_test_result(M.testing_state, data)
      end
    elseif action == "test_run_started" then
      local ok, data = pcall(vim.json.decode, event.data)
      if ok and data then
        M.testing_state = testing.handle_run_started(M.testing_state, data)
      end
    elseif action == "test_run_completed" then
      local ok, data = pcall(vim.json.decode, event.data)
      if ok and data then
        M.testing_state = testing.handle_run_completed(M.testing_state, data)
      end
    end
  end
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
    end,
    on_disconnect = function()
      M.state = model.set_status(M.state, "disconnected")
    end,
    auto_reconnect = true,
    reconnect_delay = 3000,
  })
  events_sse.start()

  -- Diagnostics SSE (separate endpoint)
  start_diagnostics()
end

local function stop_sse()
  if events_sse then events_sse.stop(); events_sse = nil end
  stop_diagnostics()
  M.state = model.set_status(M.state, "disconnected")
end

-- ─── Diagnostics SSE ──────────────────────────────────────────────────────────

function start_diagnostics()
  if diag_sse then return end
  diag_ns = diag_ns or vim.api.nvim_create_namespace("sagefs_diagnostics")

  diag_sse = transport.connect_sse(
    string.format("http://localhost:%d/diagnostics", M.config.port), {
    on_events = function(events)
      for _, event in ipairs(events) do
        if event.data then
          vim.schedule(function()
            local ok, data = pcall(vim.json.decode, event.data)
            if ok and data and data.diagnostics then
              M.apply_diagnostics(data.diagnostics)
            end
          end)
        end
      end
    end,
    auto_reconnect = true,
    reconnect_delay = 3000,
  })
  diag_sse.start()
end

function stop_diagnostics()
  if diag_sse then diag_sse.stop(); diag_sse = nil end
  if diag_ns then vim.diagnostic.reset(diag_ns) end
end

function M.apply_diagnostics(diags)
  if not diag_ns then return end
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
    return col
  end

  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  local cursor = vim.api.nvim_win_get_cursor(0)
  local offset = 0
  for i = 1, cursor[1] - 1 do
    offset = offset + #lines[i] + 1
  end
  offset = offset + cursor[2]

  local json_body = vim.fn.json_encode({
    code = text,
    cursor_position = offset,
    working_directory = vim.fn.getcwd(),
  })

  -- Synchronous curl for omnifunc (must return results immediately)
  local result = vim.fn.system({
    "curl", "-X", "POST", dashboard_url() .. "/dashboard/completions",
    "-H", "Content-Type: application/json",
    "-d", json_body,
    "--max-time", "5", "--silent", "--show-error",
  })

  local ok, parsed = pcall(vim.fn.json_decode, result)
  if not ok or not parsed or not parsed.completions then
    return {}
  end

  local items = {}
  for _, c in ipairs(parsed.completions) do
    table.insert(items, {
      word = c.insertText or c.label,
      abbr = c.label,
      kind = c.kind or "",
      menu = "[SageFs]",
    })
  end
  return items
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

function M.health_check()
  local cmd = { "curl", "-s", "--max-time", "2", base_url() .. "/health" }
  local result = vim.fn.system(cmd)
  if result:match('"healthy"') then
    notify("Connected to SageFs on port " .. M.config.port)
    return true
  elseif result:match('"error"') or result:match('"success"') then
    notify("SageFs reachable (no session for this directory)")
    return true
  else
    notify("SageFs not available on port " .. M.config.port, vim.log.levels.ERROR)
    return false
  end
end

function M.statusline()
  if M.active_session then
    return sessions.format_statusline(M.active_session)
  end
  local icon = M.state.status == "connected" and "⚡" or "💤"
  local cell_count = model.cell_count(M.state)
  if cell_count > 0 then
    return icon .. " SageFs [" .. cell_count .. "]"
  end
  return icon .. " SageFs"
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
  }

  commands.register_commands(M, helpers)
  commands.register_keymaps(M, helpers)
  commands.register_autocmds(M, helpers)
  hotreload.setup(M.config.dashboard_port)

  if M.config.auto_connect then
    vim.defer_fn(function()
      if M.health_check() then
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
    end, 500)
  end

  _G.SageFs = M
end

return M
