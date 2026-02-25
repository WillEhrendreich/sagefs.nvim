-- spec/e2e/e2e_harness.lua — E2E integration test harness for sagefs.nvim
-- Runs INSIDE a real Neovim instance (nvim --headless --clean -u NONE -l)
-- Manages SageFs daemon lifecycle, temp dirs, and provides test utilities.

local H = {}

-- ─── Configuration ───────────────────────────────────────────────────────────

H.SAGEFS_PORT = 47749
H.HEALTH_TIMEOUT_MS = 120000
H.EVENT_TIMEOUT_MS = 15000
H.TEST_TIMEOUT_MS = 30000
H.RESET_TIMEOUT_MS = 5000
H.POLL_INTERVAL_MS = 500

-- ─── Test Framework ──────────────────────────────────────────────────────────

local passed = 0
local failed = 0
local errors = {}
local current_suite = ""

function H.describe(name, fn)
  current_suite = name
  io.write("\n  " .. name .. "\n")
  fn()
  current_suite = ""
end

function H.it(name, fn)
  local label = current_suite ~= "" and (current_suite .. " > " .. name) or name
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write("    ✓ " .. label .. "\n")
  else
    failed = failed + 1
    table.insert(errors, { label = label, err = tostring(err) })
    io.write("    ✖ " .. label .. "\n")
    io.write("      " .. tostring(err) .. "\n")
  end
end

function H.assert_eq(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s",
      msg or "assertion failed", tostring(expected), tostring(actual)), 2)
  end
end

function H.assert_truthy(val, msg)
  if not val then
    error(msg or "expected truthy value, got " .. tostring(val), 2)
  end
end

function H.assert_falsy(val, msg)
  if val then
    error(msg or "expected falsy value, got " .. tostring(val), 2)
  end
end

function H.assert_contains(haystack, needle, msg)
  if type(haystack) == "string" then
    if not haystack:find(needle, 1, true) then
      error(string.format("%s: '%s' not found in '%s'",
        msg or "assert_contains", needle, haystack), 2)
    end
  elseif type(haystack) == "table" then
    for _, v in ipairs(haystack) do
      if v == needle then return end
    end
    error(string.format("%s: '%s' not found in table",
      msg or "assert_contains", tostring(needle)), 2)
  end
end

function H.assert_match(pattern, str, msg)
  if not str:match(pattern) then
    error(string.format("%s: pattern '%s' not found in '%s'",
      msg or "assert_match", pattern, str), 2)
  end
end

-- ─── Path Utilities ──────────────────────────────────────────────────────────

local function is_windows()
  return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

local function path_sep()
  return is_windows() and "\\" or "/"
end

-- Find the plugin root (parent of spec/)
function H.plugin_root()
  local info = debug.getinfo(1, "S").source:match("@(.*[/\\])")
  return vim.fn.fnamemodify(info .. ".." .. path_sep() .. "..", ":p"):gsub("[/\\]$", "")
end

-- ─── Preflight Checks ────────────────────────────────────────────────────────

function H.check_prerequisites()
  local errs = {}
  if vim.fn.executable("sagefs") ~= 1 then
    table.insert(errs, "sagefs not found on PATH")
  end
  if vim.fn.executable("dotnet") ~= 1 then
    table.insert(errs, "dotnet SDK not found on PATH")
  end
  if vim.fn.executable("curl") ~= 1 then
    table.insert(errs, "curl not found on PATH")
  end
  return #errs == 0, errs
end

-- ─── Temp Directory Management ───────────────────────────────────────────────

function H.create_temp_project(sample_name)
  local root = H.plugin_root()
  local src = root .. path_sep() .. "samples" .. path_sep() .. sample_name
  if vim.fn.isdirectory(src) ~= 1 then
    error("Sample project not found: " .. src)
  end

  local tmp_base = vim.fn.tempname()
  local tmp_dir = tmp_base .. "-sagefs-e2e"
  vim.fn.mkdir(tmp_dir, "p")

  -- Copy sample project
  if is_windows() then
    vim.fn.system(string.format('xcopy /E /I /Q "%s" "%s"', src, tmp_dir .. path_sep() .. sample_name))
  else
    vim.fn.system(string.format('cp -r "%s" "%s/"', src, tmp_dir))
  end

  local project_dir = tmp_dir .. path_sep() .. sample_name
  if vim.fn.isdirectory(project_dir) ~= 1 then
    error("Failed to copy sample project to: " .. project_dir)
  end

  return { base = tmp_dir, project = project_dir }
end

function H.cleanup_temp_dir(temp)
  if not temp or not temp.base then return end
  local path = temp.base
  if vim.fn.isdirectory(path) ~= 1 then return end

  if is_windows() then
    -- Retry up to 3 times (Windows file locking)
    for _ = 1, 3 do
      vim.fn.system(string.format('rmdir /S /Q "%s" 2>nul', path))
      if vim.fn.isdirectory(path) ~= 1 then return end
      vim.wait(1000, function() return false end)
    end
  else
    vim.fn.system(string.format('rm -rf "%s"', path))
  end
end

-- ─── HTTP Helpers (synchronous) ──────────────────────────────────────────────

function H.http_get(path, port)
  port = port or H.SAGEFS_PORT
  local url = string.format("http://localhost:%d%s", port, path)
  local result = vim.fn.system({ "curl", "-s", "-w", "\n%{http_code}", url })
  local lines = vim.split(result, "\n")
  local status = tonumber(lines[#lines]) or 0
  table.remove(lines, #lines)
  local body = table.concat(lines, "\n")
  return { status = status, body = body }
end

function H.http_post(path, body_str, port)
  port = port or H.SAGEFS_PORT
  local url = string.format("http://localhost:%d%s", port, path)
  local cmd = { "curl", "-s", "-w", "\n%{http_code}",
    "-X", "POST", "-H", "Content-Type: application/json" }
  if body_str then
    table.insert(cmd, "-d")
    table.insert(cmd, body_str)
  end
  table.insert(cmd, url)
  local result = vim.fn.system(cmd)
  local lines = vim.split(result, "\n")
  local status = tonumber(lines[#lines]) or 0
  table.remove(lines, #lines)
  local resp_body = table.concat(lines, "\n")
  return { status = status, body = resp_body }
end

-- ─── Eval Helper ─────────────────────────────────────────────────────────────

-- Current project directory (set by run_suite for session resolution)
local current_project_dir = nil

-- Eval F# code via POST /exec with working_directory for session resolution
function H.eval(code, port)
  port = port or H.SAGEFS_PORT
  local body = { code = code }
  if current_project_dir then
    body.working_directory = current_project_dir
  end
  return H.http_post("/exec", vim.fn.json_encode(body), port)
end

-- ─── Daemon Lifecycle ────────────────────────────────────────────────────────

-- Active daemon handle (module-level for cleanup)
local active_daemon = nil

function H.find_fsproj(project_dir)
  local files = vim.fn.glob(project_dir .. path_sep() .. "*.fsproj", false, true)
  if #files == 0 then
    error("No .fsproj found in: " .. project_dir)
  end
  return files[1]
end

function H.find_sagefs_binary()
  -- Try PATH first
  local which = vim.fn.exepath("sagefs")
  if which ~= "" then return which end
  -- Try common dotnet tool locations
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
  local candidates = {
    home .. "/.dotnet/tools/sagefs",
    home .. "\\.dotnet\\tools\\sagefs.exe",
  }
  for _, path in ipairs(candidates) do
    if vim.fn.filereadable(path) == 1 then return path end
  end
  error("sagefs binary not found on PATH or in ~/.dotnet/tools/")
end

function H.start_daemon(project_dir, port)
  port = port or H.SAGEFS_PORT
  local fsproj = H.find_fsproj(project_dir)
  local sagefs_bin = H.find_sagefs_binary()

  io.write(string.format("    [harness] Starting SageFs (%s) on port %d: %s\n", sagefs_bin, port, fsproj))

  local stdout_lines = {}
  local stderr_lines = {}

  local job_id = vim.fn.jobstart({
    sagefs_bin, "--supervised", "--proj", fsproj, "--mcp-port", tostring(port)
  }, {
    cwd = project_dir,
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then table.insert(stdout_lines, line) end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then table.insert(stderr_lines, line) end
      end
    end,
  })

  if job_id <= 0 then
    error("Failed to start SageFs daemon (jobstart returned " .. tostring(job_id) .. ")")
  end

  local handle = {
    job_id = job_id,
    port = port,
    project_dir = project_dir,
    stdout = stdout_lines,
    stderr = stderr_lines,
  }
  active_daemon = handle
  return handle
end

function H.wait_for_health(port, timeout_ms)
  port = port or H.SAGEFS_PORT
  timeout_ms = timeout_ms or H.HEALTH_TIMEOUT_MS

  io.write(string.format("    [harness] Waiting for health on port %d (timeout %ds)...\n",
    port, timeout_ms / 1000))

  local ok = vim.wait(timeout_ms, function()
    local resp = H.http_get("/health", port)
    return resp.status == 200
  end, H.POLL_INTERVAL_MS)

  if not ok then
    -- Dump daemon stderr for diagnostics
    if active_daemon and #active_daemon.stderr > 0 then
      io.write("    [harness] Daemon stderr:\n")
      for _, line in ipairs(active_daemon.stderr) do
        io.write("      | " .. line .. "\n")
      end
    end
    if active_daemon and #active_daemon.stdout > 0 then
      io.write("    [harness] Daemon stdout:\n")
      for i = math.max(1, #active_daemon.stdout - 20), #active_daemon.stdout do
        io.write("      | " .. active_daemon.stdout[i] .. "\n")
      end
    end
    error(string.format("SageFs daemon failed to become healthy within %ds on port %d",
      timeout_ms / 1000, port))
  end

  io.write("    [harness] SageFs is healthy.\n")
  return true
end

function H.reset_session(port)
  port = port or H.SAGEFS_PORT
  local resp = H.http_post("/reset", nil, port)
  if resp.status ~= 200 then
    io.write(string.format("    [harness] Warning: reset returned %d\n", resp.status))
  end
  -- Give it a moment to settle
  vim.wait(500, function() return false end)
  return resp
end

function H.stop_daemon(handle)
  if not handle then return end
  io.write("    [harness] Stopping SageFs daemon...\n")

  -- Try graceful stop first
  pcall(function() vim.fn.jobstop(handle.job_id) end)
  local result = vim.fn.jobwait({ handle.job_id }, 5000)

  -- If still running, force kill
  if result[1] == -1 then
    io.write("    [harness] Force-killing daemon...\n")
    if is_windows() then
      -- Use jobstop again (more forceful on Windows)
      pcall(function() vim.fn.jobstop(handle.job_id) end)
      vim.fn.jobwait({ handle.job_id }, 3000)
    else
      pcall(function() vim.fn.jobstop(handle.job_id) end)
    end
  end

  if handle == active_daemon then
    active_daemon = nil
  end

  io.write("    [harness] Daemon stopped.\n")
end

-- ─── Wait Utilities ──────────────────────────────────────────────────────────

function H.wait_for(predicate, timeout_ms, poll_ms)
  timeout_ms = timeout_ms or H.EVENT_TIMEOUT_MS
  poll_ms = poll_ms or 100
  local ok = vim.wait(timeout_ms, predicate, poll_ms)
  return ok
end

-- ─── Plugin Integration ──────────────────────────────────────────────────────

function H.setup_plugin(port)
  port = port or H.SAGEFS_PORT
  local root = H.plugin_root()
  vim.opt.rtp:prepend(root)
  package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

  local sagefs = require("sagefs")
  sagefs.setup({
    port = port,
    dashboard_port = port + 1,
    auto_connect = false,
  })
  return sagefs
end

-- ─── Suite Lifecycle ─────────────────────────────────────────────────────────

-- Run a complete test suite: copy sample, start daemon, run tests, cleanup
function H.run_suite(opts)
  local sample = opts.sample or "Minimal"
  local port = opts.port or H.SAGEFS_PORT
  local suite_fn = opts.fn

  io.write("\n=== E2E Suite: " .. (opts.name or sample) .. " ===\n")

  -- Preflight
  local ok, errs = H.check_prerequisites()
  if not ok then
    io.write("  SKIPPED: Missing prerequisites:\n")
    for _, e in ipairs(errs) do io.write("    - " .. e .. "\n") end
    return
  end

  local temp = nil
  local handle = nil
  local suite_ok, suite_err = pcall(function()
    -- Copy sample to temp
    temp = H.create_temp_project(sample)
    io.write("    [harness] Temp project: " .. temp.project .. "\n")

    -- Set project dir for session resolution
    current_project_dir = temp.project

    -- Start daemon
    handle = H.start_daemon(temp.project, port)

    -- Wait for health
    H.wait_for_health(port)

    -- Warmup: send a trivial eval to ensure FSI session is fully loaded
    -- Must check body too — SageFs returns 200 even with "No active session" error
    local warmup_ok = vim.wait(30000, function()
      local r = H.eval("1 + 1;;", port)
      if r.status ~= 200 then return false end
      -- Body must NOT contain "No active session" error
      if r.body and r.body:find("No active session") then return false end
      return true
    end, 1000)
    if warmup_ok then
      io.write("    [harness] FSI session warmed up.\n")
    else
      io.write("    [harness] Warning: FSI warmup did not succeed within 30s.\n")
    end

    -- Setup plugin
    local sagefs = H.setup_plugin(port)

    -- Run test function
    suite_fn(sagefs, temp, handle)
  end)

  -- Always cleanup
  current_project_dir = nil
  if handle then
    pcall(H.stop_daemon, handle)
  end
  if temp then
    pcall(H.cleanup_temp_dir, temp)
  end

  if not suite_ok then
    io.write("  SUITE ERROR: " .. tostring(suite_err) .. "\n")
    failed = failed + 1
    table.insert(errors, { label = opts.name or sample, err = tostring(suite_err) })
  end
end

-- ─── Report ──────────────────────────────────────────────────────────────────

function H.report()
  io.write(string.format("\n%d passed, %d failed\n", passed, failed))
  if #errors > 0 then
    io.write("\nFailures:\n")
    for _, e in ipairs(errors) do
      io.write("  ✖ " .. e.label .. "\n")
      io.write("    " .. e.err .. "\n")
    end
  end
  vim.cmd("cquit " .. (failed > 0 and "1" or "0"))
end

-- ─── Cleanup on exit ─────────────────────────────────────────────────────────

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    if active_daemon then
      pcall(H.stop_daemon, active_daemon)
    end
  end,
})

return H
