-- sagefs/health.lua — :checkhealth sagefs integration
-- Comprehensive diagnostic dashboard: CLI, daemon, sessions,
-- testing, SSE, configuration, and optional dependencies.

local M = {}

--- Run SageFs CLI and extract version string, or nil on failure
local function get_cli_version()
  local ok, result = pcall(vim.fn.system, "sagefs --version")
  if not ok or vim.v.shell_error ~= 0 then return nil end
  return vim.trim(result or "")
end

--- Attempt a simple HTTP health check against the daemon
local function check_daemon_port(port)
  local ok, result = pcall(vim.fn.system,
    string.format("curl -s -o /dev/null -w \"%%{http_code}\" --connect-timeout 2 http://localhost:%d/health", port))
  if not ok or vim.v.shell_error ~= 0 then return false, nil end
  local code = vim.trim(result or "")
  return code == "200" or code == "204", code
end

function M.check()
  vim.health.start("sagefs")

  -- ── 1. SageFs CLI version ───────────────────────────────────────────────
  local cli_version = get_cli_version()
  if cli_version and cli_version ~= "" then
    vim.health.ok("SageFs CLI found: " .. cli_version)
  else
    vim.health.error("SageFs CLI not found", {
      "Install with: dotnet tool install -g sagefs",
      "See https://github.com/WillEhrendreich/SageFs",
    })
  end

  -- ── 2. Plugin loaded & configuration ────────────────────────────────────
  local ok_plugin, sagefs = pcall(require, "sagefs")
  if not ok_plugin or not sagefs.state then
    vim.health.info("sagefs.nvim not yet initialized (call require('sagefs').setup() first)")
    -- Can't check further without the plugin loaded
    M._check_dependencies()
    return
  end

  vim.health.ok("sagefs.nvim loaded (plugin v" .. (sagefs.version or "?") .. ")")

  -- ── 3. Plugin configuration ─────────────────────────────────────────────
  local cfg = sagefs.config or {}
  local config_lines = {
    "port = " .. tostring(cfg.port or 37749),
    "dashboard_port = " .. tostring(cfg.dashboard_port or 37750),
    "auto_connect = " .. tostring(cfg.auto_connect),
    "check_on_save = " .. tostring(cfg.check_on_save),
  }
  if cfg.cell_highlight then
    table.insert(config_lines, "cell_highlight.style = " .. tostring(cfg.cell_highlight.style or "normal"))
  end
  vim.health.ok("Configuration: " .. table.concat(config_lines, ", "))

  -- ── 4. Daemon connectivity ──────────────────────────────────────────────
  local port = cfg.port or 37749
  local daemon_ok, http_code = check_daemon_port(port)
  if daemon_ok then
    vim.health.ok("Daemon reachable on port " .. port)
  else
    local detail = http_code and (" (HTTP " .. http_code .. ")") or ""
    vim.health.warn("Daemon not reachable on port " .. port .. detail, {
      "Start the daemon: sagefs --proj <your.fsproj>",
      "Or run :SageFsStart from Neovim",
    })
  end

  -- ── 5. SSE connection status ────────────────────────────────────────────
  local status = sagefs.state and sagefs.state.status or "unknown"
  if status == "connected" then
    vim.health.ok("SSE event stream: connected")
  elseif status == "reconnecting" then
    vim.health.warn("SSE event stream: reconnecting", {
      "Check that the daemon is running: sagefs --proj <your.fsproj>",
      "Or run :SageFsReconnect to re-establish the connection",
    })
  else
    vim.health.warn("SSE event stream: " .. status, {
      "Run :SageFsStart or :SageFsConnect to connect",
    })
  end

  -- ── 6. Active sessions ─────────────────────────────────────────────────
  local session_list = sagefs.session_list or {}
  local active = sagefs.active_session
  if #session_list > 0 then
    local lines = {}
    for _, s in ipairs(session_list) do
      local projs = s.projects or {}
      local proj_str = #projs > 0 and table.concat(projs, ", ") or "no projects"
      local marker = (active and s.id == active) and " (active)" or ""
      table.insert(lines, string.format("  %s — %s [%s]%s",
        s.id or "?", proj_str, s.status or "?", marker))
    end
    vim.health.ok(#session_list .. " session(s) found:\n" .. table.concat(lines, "\n"))
  elseif active then
    vim.health.ok("Active session: " .. tostring(active))
  else
    vim.health.info("No active sessions. Run :SageFsCreateSession to create one")
  end

  -- ── 7. Live testing status ──────────────────────────────────────────────
  local ts = sagefs.testing_state
  if ts then
    local summary = ts.summary or {}
    local total = summary.total or 0
    if total > 0 then
      local parts = {}
      if (summary.passed or 0) > 0 then table.insert(parts, summary.passed .. " passed") end
      if (summary.failed or 0) > 0 then table.insert(parts, summary.failed .. " failed") end
      if (summary.stale or 0) > 0 then table.insert(parts, summary.stale .. " stale") end
      if (summary.running or 0) > 0 then table.insert(parts, summary.running .. " running") end
      if (summary.disabled or 0) > 0 then table.insert(parts, summary.disabled .. " disabled") end
      local status_str = table.concat(parts, ", ")
      local phase_str = ts.run_phase and (" [" .. ts.run_phase .. "]") or ""
      if (summary.failed or 0) > 0 then
        vim.health.warn("Live testing: " .. total .. " tests (" .. status_str .. ")" .. phase_str)
      else
        vim.health.ok("Live testing: " .. total .. " tests (" .. status_str .. ")" .. phase_str)
      end
    elseif ts.enabled then
      vim.health.info("Live testing: enabled, no tests discovered yet")
    else
      vim.health.info("Live testing: not enabled. Run :SageFsRunTests to trigger discovery")
    end
  end

  -- ── 8. Dependencies ─────────────────────────────────────────────────────
  M._check_dependencies()
end

--- Check optional and required dependencies (extracted for reuse)
function M._check_dependencies()
  -- Tree-sitter F# parser
  local ok_ts, parsers = pcall(require, "nvim-treesitter.parsers")
  if ok_ts and parsers then
    local has_fsharp = parsers.has_parser and parsers.has_parser("fsharp")
    if has_fsharp then
      vim.health.ok("Tree-sitter F# parser installed (improved cell detection)")
    else
      vim.health.info("Tree-sitter F# parser not installed (optional)", {
        "Install with: :TSInstall fsharp",
        "Improves cell boundary detection inside strings/comments",
      })
    end
  else
    vim.health.info("nvim-treesitter not found (optional, improves cell detection)")
  end

  -- curl
  local ok_curl = pcall(function()
    vim.fn.system("curl --version")
    if vim.v.shell_error ~= 0 then error("not found") end
  end)
  if ok_curl then
    vim.health.ok("curl available (required for SSE event stream)")
  else
    vim.health.error("curl not found", {
      "curl is required for the SSE event stream (live updates, test results, coverage)",
      "HTTP eval requests use vim.uv TCP and don't require curl",
    })
  end

  -- telescope.nvim (optional)
  local has_telescope = pcall(require, "telescope")
  if has_telescope then
    vim.health.ok("telescope.nvim available (enables :Telescope sagefs tests)")
  else
    vim.health.info("telescope.nvim not installed (optional)", {
      "Install: https://github.com/nvim-telescope/telescope.nvim",
      "Enables :Telescope sagefs tests, :Telescope sagefs failures, :SageFsPickTest",
    })
  end

  -- plenary.nvim (optional, used by telescope)
  local has_plenary = pcall(require, "plenary")
  if has_plenary then
    vim.health.ok("plenary.nvim available")
  else
    vim.health.info("plenary.nvim not installed (optional, required by telescope.nvim)")
  end
end

return M
