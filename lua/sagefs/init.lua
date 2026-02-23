-- sagefs/init.lua — Neovim integration for SageFs notebook experience
-- Connects pure modules (cells, format, model, sse) to Neovim APIs
local cells = require("sagefs.cells")
local format = require("sagefs.format")
local model = require("sagefs.model")
local sessions = require("sagefs.sessions")
local sse_parser = require("sagefs.sse")
local hotreload = require("sagefs.hotreload")

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
M.active_session = nil -- {id, status, projects, working_directory, ...}
M.session_list = {}    -- cached from last list_sessions call
local ns = nil -- extmark namespace, created on setup()
local sse_job = nil
local sse_buffer = ""

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

-- ─── Highlight Setup ─────────────────────────────────────────────────────────

local function setup_highlights()
  local hl = M.config.highlight
  vim.api.nvim_set_hl(0, "SageFsSuccess", hl.success)
  vim.api.nvim_set_hl(0, "SageFsError", hl.error)
  vim.api.nvim_set_hl(0, "SageFsOutput", hl.output)
  vim.api.nvim_set_hl(0, "SageFsRunning", hl.running)
  vim.api.nvim_set_hl(0, "SageFsStale", hl.stale)
  vim.api.nvim_set_hl(0, "SageFsCellBorder", { fg = "#585b70" })
end

-- ─── Extmark Rendering ──────────────────────────────────────────────────────

local function clear_extmarks(buf)
  if ns then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

local function render_cell_result(buf, boundary_line, cell_id)
  if not ns then return end
  local cell = model.get_cell_state(M.state, cell_id)
  if cell.status == "idle" then return end

  -- Gutter sign
  local sign = format.gutter_sign(cell.status)

  -- Inline result (on the ;; line)
  local inline = nil
  if cell.status == "success" or cell.status == "error" then
    inline = format.format_inline({
      ok = cell.status == "success" or cell.status == "stale",
      output = cell.output,
      error = cell.output,
    })
  end

  -- Virtual text on the boundary line
  local virt_text = {}
  if inline then
    table.insert(virt_text, { inline.text, inline.hl })
  end

  local opts = {
    id = cell_id * 1000, -- unique ID per cell
    virt_text = #virt_text > 0 and virt_text or nil,
    virt_text_pos = "eol",
    sign_text = sign.text,
    sign_hl_group = sign.hl,
    priority = 100,
  }

  -- boundary_line is 1-indexed, nvim_buf_set_extmark is 0-indexed
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, boundary_line - 1, 0, opts)

  -- Virtual lines for expanded output
  if cell.status == "success" or cell.status == "error" then
    local vlines = format.format_virtual_lines({
      ok = cell.status == "success",
      output = cell.output,
      error = cell.output,
    })
    if #vlines > 0 then
      local virt_lines = {}
      for _, vl in ipairs(vlines) do
        table.insert(virt_lines, { { vl.text, vl.hl } })
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, boundary_line - 1, 0, {
        id = cell_id * 1000 + 1,
        virt_lines = virt_lines,
        virt_lines_above = false,
      })
    end
  end
end

local function render_all_extmarks(buf)
  if not ns then return end
  clear_extmarks(buf)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local all_cells = cells.find_all_cells(lines)

  for _, cell in ipairs(all_cells) do
    render_cell_result(buf, cell.end_line, cell.id)
  end
end

-- ─── Flash Animation ─────────────────────────────────────────────────────────

local function flash_cell(buf, start_line, end_line)
  if not ns then return end
  local flash_ns = vim.api.nvim_create_namespace("sagefs_flash")

  for i = start_line, end_line do
    pcall(vim.api.nvim_buf_add_highlight, buf, flash_ns, "SageFsRunning", i - 1, 0, -1)
  end

  vim.defer_fn(function()
    pcall(vim.api.nvim_buf_clear_namespace, buf, flash_ns, 0, -1)
  end, 150)
end

-- ─── HTTP: POST /exec ────────────────────────────────────────────────────────

--- handle_result is the named seam the panel recommended.
--- Today it's called after sync POST; tomorrow from SSE handler.
local function handle_result(buf, cell_id, result)
  if result.ok then
    M.state = model.set_cell_state(M.state, cell_id, "success", result.output)
  else
    M.state = model.set_cell_state(M.state, cell_id, "error", result.error)
  end
  vim.schedule(function()
    render_all_extmarks(buf)
  end)
end

local function post_exec(code, buf, cell_id)
  local json_body = vim.fn.json_encode({
    code = code,
    working_directory = vim.fn.getcwd(),
  })

  -- Use temp file for large payloads
  local use_temp = #json_body > 7000
  local temp_file = nil

  if use_temp then
    temp_file = vim.fn.tempname() .. ".json"
    local f = io.open(temp_file, "w")
    if f then
      f:write(json_body)
      f:close()
    end
  end

  local cmd
  if use_temp then
    cmd = {
      "curl", "-X", "POST", base_url() .. "/exec",
      "-H", "Content-Type: application/json",
      "-d", "@" .. temp_file,
      "--max-time", "60", "--silent", "--show-error",
    }
  else
    cmd = {
      "curl", "-X", "POST", base_url() .. "/exec",
      "-H", "Content-Type: application/json",
      "-d", json_body,
      "--max-time", "30", "--silent", "--show-error",
    }
  end

  local stdout_data = {}

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then stdout_data = data end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if temp_file then os.remove(temp_file) end

        if exit_code == 0 then
          local raw = table.concat(stdout_data, "\n")
          local result = format.parse_exec_response(raw)
          handle_result(buf, cell_id, result)
        else
          handle_result(buf, cell_id, { ok = false, error = "HTTP request failed" })
        end
      end)
    end,
  })
end

-- ─── Eval: <Alt-Enter> Handler ───────────────────────────────────────────────

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

  -- Find cell ID
  local all = cells.find_all_cells(lines)
  local cell_id = 1
  for _, c in ipairs(all) do
    if c.start_line == cell.start_line then
      cell_id = c.id
      break
    end
  end

  -- Mark as running + flash
  M.state = model.set_cell_state(M.state, cell_id, "running")
  render_all_extmarks(buf)
  flash_cell(buf, cell.start_line, cell.end_line)

  -- POST to SageFs
  post_exec(code, buf, cell_id)
end

-- ─── Eval visual selection ───────────────────────────────────────────────────

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

  -- Use cell_id 0 for ad-hoc selections
  M.state = model.set_cell_state(M.state, 0, "running")
  flash_cell(buf, start_pos[2], end_pos[2])
  post_exec(code, buf, 0)
end

-- ─── Eval file ───────────────────────────────────────────────────────────────

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
  flash_cell(buf, 1, #lines)
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

-- ─── SSE Subscription ────────────────────────────────────────────────────────

local function start_sse()
  if sse_job then
    pcall(vim.fn.jobstop, sse_job)
  end
  sse_buffer = ""

  sse_job = vim.fn.jobstart(
    { "curl", "--no-buffer", "-N", base_url() .. "/events", "--silent" },
    {
      on_stdout = function(_, data, _)
        for _, chunk in ipairs(data) do
          sse_buffer = sse_buffer .. chunk .. "\n"
          local events, remainder = sse_parser.parse_chunk(sse_buffer)
          sse_buffer = remainder

          for _, event in ipairs(events) do
            if event.type == "state" and event.data then
              -- Server pushed state — update connection status
              M.state = model.set_status(M.state, "connected")
            end
          end
        end
      end,
      on_exit = function(_, code, _)
        sse_job = nil
        if code ~= 0 then
          M.state = model.set_status(M.state, "disconnected")
          -- Reconnect after delay
          vim.defer_fn(function()
            if M.config.auto_connect then
              start_sse()
            end
          end, 3000)
        end
      end,
    }
  )

  if sse_job and sse_job > 0 then
    M.state = model.set_status(M.state, "connected")
    M.start_diagnostics()
  end
end

local function stop_sse()
  if sse_job then
    pcall(vim.fn.jobstop, sse_job)
    sse_job = nil
  end
  M.stop_diagnostics()
  M.state = model.set_status(M.state, "disconnected")
end

-- ─── Session API: generic HTTP helper ────────────────────────────────────────

local function session_http(method, path, body, callback)
  local cmd = { "curl", "-X", method, base_url() .. path,
    "-H", "Content-Type: application/json",
    "--max-time", "5", "--silent", "--show-error" }
  if body then
    table.insert(cmd, "-d")
    table.insert(cmd, vim.fn.json_encode(body))
  end

  local stdout_data = {}
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then stdout_data = data end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        local raw = table.concat(stdout_data, "\n")
        callback(exit_code == 0, raw)
      end)
    end,
  })
end

-- ─── Session API: public functions ───────────────────────────────────────────

function M.list_sessions(callback)
  session_http("GET", "/api/sessions", nil, function(ok, raw)
    local result = sessions.parse_sessions_response(ok and raw or nil)
    if result.ok then
      M.session_list = result.sessions
      -- Auto-detect active session for current working directory
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
      -- Refresh session list to pick up the new session
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
      M.list_sessions() -- refresh
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
      M.list_sessions() -- refresh
    else
      notify(result.error or "Failed to stop session", vim.log.levels.ERROR)
    end
    if callback then callback(result) end
  end)
end

-- ─── Reset / Hard-Reset ──────────────────────────────────────────────────────

function M.reset_session(callback)
  session_http("POST", "/reset", {}, function(ok, raw)
    if ok then
      notify("Session reset")
    else
      notify("Failed to reset session", vim.log.levels.ERROR)
    end
    if callback then callback(ok) end
  end)
end

function M.hard_reset(callback)
  session_http("POST", "/hard-reset", { rebuild = true }, function(ok, raw)
    if ok then
      notify("Hard reset complete (rebuild)")
    else
      notify("Failed to hard reset", vim.log.levels.ERROR)
    end
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
  local url = string.format(
    "http://localhost:%d/api/sessions/%s/warmup-context",
    M.config.dashboard_port, sid)
  local cmd = { "curl", "-X", "GET", url,
    "--max-time", "5", "--silent", "--show-error" }
  local stdout_data = {}
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then stdout_data = data end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        local raw = table.concat(stdout_data, "\n")
        if exit_code ~= 0 or raw == "" then
          notify("Failed to fetch session context", vim.log.levels.ERROR)
          return
        end
        local ok, ctx = pcall(vim.json.decode, raw)
        if not ok or type(ctx) ~= "table" then
          notify("Invalid session context response", vim.log.levels.ERROR)
          return
        end
        -- Build display lines
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
        -- Show in floating window
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
        vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
        local width = 60
        for _, l in ipairs(lines) do
          if #l + 2 > width then width = #l + 2 end
        end
        local height = math.min(#lines, 30)
        local win = vim.api.nvim_open_win(buf, true, {
          relative = "editor",
          width = width,
          height = height,
          row = math.floor((vim.o.lines - height) / 2),
          col = math.floor((vim.o.columns - width) / 2),
          style = "minimal",
          border = "rounded",
          title = " Session Context ",
          title_pos = "center",
        })
        vim.keymap.set("n", "q", function()
          vim.api.nvim_win_close(win, true)
        end, { buffer = buf, nowait = true })
      end)
    end,
  })
end

-- ─── Diagnostics Integration ─────────────────────────────────────────────────

local diag_ns = nil
local diag_sse_job = nil
local diag_buffer = ""

function M.start_diagnostics()
  if diag_sse_job then return end
  diag_ns = diag_ns or vim.api.nvim_create_namespace("sagefs_diagnostics")
  local url = string.format("http://localhost:%d/diagnostics", M.config.port)
  diag_buffer = ""

  diag_sse_job = vim.fn.jobstart({ "curl", "-N", "--silent", "--show-error", url }, {
    on_stdout = function(_, data)
      if not data then return end
      for _, chunk in ipairs(data) do
        diag_buffer = diag_buffer .. chunk .. "\n"
      end
      -- Parse SSE events
      while true do
        local idx = diag_buffer:find("\n\n")
        if not idx then break end
        local event = diag_buffer:sub(1, idx - 1)
        diag_buffer = diag_buffer:sub(idx + 2)
        for line in event:gmatch("[^\n]+") do
          if line:sub(1, 6) == "data: " then
            vim.schedule(function()
              local ok, data_obj = pcall(vim.json.decode, line:sub(7))
              if ok and data_obj and data_obj.diagnostics then
                M.apply_diagnostics(data_obj.diagnostics)
              end
            end)
          end
        end
      end
    end,
    on_exit = function()
      diag_sse_job = nil
      -- Auto-reconnect after delay
      vim.defer_fn(function()
        if M.state.status == "connected" then
          M.start_diagnostics()
        end
      end, 3000)
    end,
  })
end

function M.stop_diagnostics()
  if diag_sse_job then
    vim.fn.jobstop(diag_sse_job)
    diag_sse_job = nil
  end
  if diag_ns then
    vim.diagnostic.reset(diag_ns)
  end
end

function M.apply_diagnostics(diags)
  if not diag_ns then return end
  -- Group by file
  local by_file = {}
  for _, d in ipairs(diags) do
    local file = d.file
    if file then
      by_file[file] = by_file[file] or {}
      local severity = vim.diagnostic.severity.HINT
      if d.severity == "error" then severity = vim.diagnostic.severity.ERROR
      elseif d.severity == "warning" then severity = vim.diagnostic.severity.WARN
      elseif d.severity == "info" then severity = vim.diagnostic.severity.INFO
      end
      table.insert(by_file[file], {
        lnum = (d.startLine or 1) - 1,
        col = (d.startColumn or 1) - 1,
        end_lnum = (d.endLine or d.startLine or 1) - 1,
        end_col = (d.endColumn or d.startColumn or 1) - 1,
        message = d.message or "",
        severity = severity,
        source = "sagefs",
      })
    end
  end
  -- Apply to each buffer
  for file, file_diags in pairs(by_file) do
    local bufnr = vim.fn.bufnr(file)
    if bufnr ~= -1 then
      vim.diagnostic.set(diag_ns, bufnr, file_diags)
    end
  end
end

-- ─── Session Picker (vim.ui.select) ──────────────────────────────────────────

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

    -- Always add "Create new session..." option
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

      -- Sub-menu: what to do with this session?
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
            if a.name == "switch" then
              M.switch_session(session.id)
            elseif a.name == "stop" then
              M.stop_session(session.id)
            elseif a.name == "reset" then
              M.reset_session()
            elseif a.name == "hard_reset" then
              M.hard_reset()
            elseif a.name == "create" then
              M.discover_and_create()
            end
            return
          end
        end
      end)
    end)
  end)
end

-- ─── Auto-discover projects and offer creation ───────────────────────────────

function M.discover_and_create(working_dir)
  working_dir = working_dir or vim.fn.getcwd()

  -- Find .fsproj files in the working directory
  local fsproj_files = vim.fn.glob(working_dir .. "/**/*.fsproj", false, true)

  if #fsproj_files == 0 then
    notify("No .fsproj files found in " .. working_dir, vim.log.levels.WARN)
    return
  end

  -- Make paths relative for display
  local items = {}
  for _, path in ipairs(fsproj_files) do
    local rel = path:sub(#working_dir + 2) -- strip working_dir + separator
    table.insert(items, rel)
  end

  vim.ui.select(items, {
    prompt = "Select project to load:",
  }, function(choice)
    if not choice then return end
    M.create_session({ choice }, working_dir)
  end)
end

-- ─── Smart eval: intercept "no session" and offer creation ───────────────────

local function smart_eval_with_session_check(eval_fn)
  return function()
    -- If we have a known active session, just eval
    if M.active_session then
      eval_fn()
      return
    end

    -- Check if SageFs has any sessions for our cwd
    M.list_sessions(function(result)
      if result.ok and #result.sessions > 0 then
        local cwd_session = sessions.find_session_for_dir(result.sessions, vim.fn.getcwd())
        if cwd_session then
          M.active_session = cwd_session
          eval_fn()
          return
        end
      end

      -- No session — offer to create one
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

-- ─── Health Check ────────────────────────────────────────────────────────────

function M.health_check()
  local cmd = { "curl", "-s", "--max-time", "2", base_url() .. "/health" }
  local result = vim.fn.system(cmd)
  -- SageFs is "up" if we get any JSON back (even error = no session)
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

-- ─── Statusline Component ────────────────────────────────────────────────────

function M.statusline()
  -- Session-aware statusline
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

-- ─── Commands & Keymaps ──────────────────────────────────────────────────────

local function register_commands()
  vim.api.nvim_create_user_command("SageFsEval", function()
    M.eval_cell()
  end, { desc = "Evaluate current cell" })

  vim.api.nvim_create_user_command("SageFsEvalFile", function()
    M.eval_file()
  end, { desc = "Evaluate entire file" })

  vim.api.nvim_create_user_command("SageFsClear", function()
    M.state = model.clear_cells(M.state)
    local buf = vim.api.nvim_get_current_buf()
    clear_extmarks(buf)
    notify("Cleared all results")
  end, { desc = "Clear all cell results" })

  vim.api.nvim_create_user_command("SageFsConnect", function()
    if M.health_check() then
      start_sse()
    end
  end, { desc = "Connect to SageFs" })

  vim.api.nvim_create_user_command("SageFsDisconnect", function()
    stop_sse()
    notify("Disconnected")
  end, { desc = "Disconnect from SageFs" })

  vim.api.nvim_create_user_command("SageFsStatus", function()
    M.health_check()
  end, { desc = "Check SageFs status" })

  vim.api.nvim_create_user_command("SageFsSessions", function()
    M.session_picker()
  end, { desc = "Manage SageFs sessions" })

  vim.api.nvim_create_user_command("SageFsCreateSession", function()
    M.discover_and_create()
  end, { desc = "Create new SageFs session" })

  vim.api.nvim_create_user_command("SageFsHotReload", function()
    local sid = M.active_session and M.active_session.id or nil
    hotreload.picker(sid)
  end, { desc = "Manage hot-reload file selection" })

  vim.api.nvim_create_user_command("SageFsWatchAll", function()
    local sid = M.active_session and M.active_session.id or nil
    if not sid then
      notify("No active session", vim.log.levels.WARN)
      return
    end
    hotreload.watch_all(sid, function()
      notify(string.format("Watching all %d files", #hotreload.files))
    end)
  end, { desc = "Watch all files for hot reload" })

  vim.api.nvim_create_user_command("SageFsUnwatchAll", function()
    local sid = M.active_session and M.active_session.id or nil
    if not sid then
      notify("No active session", vim.log.levels.WARN)
      return
    end
    hotreload.unwatch_all(sid, function()
      notify("Unwatched all files")
    end)
  end, { desc = "Unwatch all files for hot reload" })

  vim.api.nvim_create_user_command("SageFsReset", function()
    M.reset_session()
  end, { desc = "Reset active FSI session" })

  vim.api.nvim_create_user_command("SageFsHardReset", function()
    M.hard_reset()
  end, { desc = "Hard reset (rebuild) active FSI session" })

  vim.api.nvim_create_user_command("SageFsContext", function()
    M.show_session_context()
  end, { desc = "Show session context (assemblies, namespaces, warmup)" })
end

local function register_keymaps()
  -- Alt-Enter: evaluate current cell (with smart session check)
  local smart_eval = smart_eval_with_session_check(function() M.eval_cell() end)
  local smart_eval_sel = smart_eval_with_session_check(function() M.eval_selection() end)

  vim.keymap.set("n", "<A-CR>", smart_eval,
    { desc = "SageFs: Evaluate cell", silent = true })

  vim.keymap.set("v", "<A-CR>", smart_eval_sel,
    { desc = "SageFs: Evaluate selection", silent = true })

  -- Leader mappings
  vim.keymap.set("n", "<leader>se", smart_eval,
    { desc = "SageFs: Evaluate cell", silent = true })
  vim.keymap.set("n", "<leader>sc", function()
    M.state = model.clear_cells(M.state)
    clear_extmarks(vim.api.nvim_get_current_buf())
  end, { desc = "SageFs: Clear results", silent = true })
  vim.keymap.set("n", "<leader>ss", function() M.session_picker() end,
    { desc = "SageFs: Sessions", silent = true })
  vim.keymap.set("n", "<leader>sh", function()
    local sid = M.active_session and M.active_session.id or nil
    hotreload.picker(sid)
  end, { desc = "SageFs: Hot Reload Files", silent = true })
end

local function register_autocmds()
  local group = vim.api.nvim_create_augroup("SageFs", { clear = true })

  -- Mark cells as stale when buffer changes
  vim.api.nvim_create_autocmd("TextChanged", {
    group = group,
    pattern = "*.fsx",
    callback = function(ev)
      M.state = model.mark_all_stale(M.state)
      render_all_extmarks(ev.buf)
    end,
  })

  -- Re-render extmarks when entering an .fsx buffer
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = "*.fsx",
    callback = function(ev)
      render_all_extmarks(ev.buf)
    end,
  })

  -- Set omnifunc for F# files
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "fsharp", "fsx" },
    callback = function()
      vim.bo.omnifunc = "v:lua.require'sagefs'.omnifunc"
    end,
  })
end

-- ─── Setup ───────────────────────────────────────────────────────────────────

function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", M.config, opts)
  M.config.port = tonumber(vim.env.SAGEFS_MCP_PORT) or M.config.port

  ns = vim.api.nvim_create_namespace("sagefs")

  setup_highlights()
  register_commands()
  register_keymaps()
  register_autocmds()
  hotreload.setup(M.config.dashboard_port)

  -- Auto-connect
  if M.config.auto_connect then
    vim.defer_fn(function()
      if M.health_check() then
        start_sse()
        M.list_sessions(function(result)
          if result.ok and not M.active_session and #result.sessions == 0 then
            -- No sessions — look for .fsproj files and offer to create one
            local fsproj_files = vim.fn.glob(vim.fn.getcwd() .. "/**/*.fsproj", false, true)
            if #fsproj_files > 0 then
              local names = {}
              for _, f in ipairs(fsproj_files) do
                table.insert(names, vim.fn.fnamemodify(f, ":~:."))
              end
              vim.ui.select(names, { prompt = "SageFs: Create session with project:" }, function(choice)
                if choice then
                  M.create_session(choice)
                end
              end)
            end
          end
        end)
      end
    end, 500)
  end

  -- Export for statusline
  _G.SageFs = M
end

return M
