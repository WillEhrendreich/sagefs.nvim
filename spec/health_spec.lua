require("spec.helper")

describe("sagefs.health", function()
  local original_system
  local original_trim
  local original_v
  local original_health
  local original_loaded_sagefs

  before_each(function()
    package.loaded["sagefs.health"] = nil
    original_system = vim.fn.system
    original_trim = vim.trim
    original_v = vim.v
    original_health = vim.health
    original_loaded_sagefs = package.loaded["sagefs"]

    vim.v = { shell_error = 0 }
    vim.trim = function(s)
      return (s:gsub("^%s+", ""):gsub("%s+$", ""))
    end
  end)

  after_each(function()
    vim.fn.system = original_system
    vim.trim = original_trim
    vim.v = original_v
    vim.health = original_health
    package.loaded["sagefs"] = original_loaded_sagefs
    package.loaded["sagefs.health"] = nil
  end)

  it("falls back to /version when /health payload is incomplete", function()
    local commands = {}
    local ok_messages = {}

    package.loaded["sagefs"] = {
      version = "test",
      state = { status = "disconnected" },
      config = {
        port = 37749,
        dashboard_port = 37750,
        auto_connect = false,
        check_on_save = false,
      },
      session_list = {},
      active_session = nil,
      testing_state = nil,
    }

    vim.health = {
      start = function(_) end,
      ok = function(msg) table.insert(ok_messages, msg) end,
      warn = function(_) end,
      info = function(_) end,
      error = function(_) end,
    }

    vim.fn.system = function(cmd)
      table.insert(commands, cmd)

      if cmd == "sagefs --version" then
        vim.v.shell_error = 0
        return "1.2.3"
      end

      if cmd == "curl --version" then
        vim.v.shell_error = 0
        return "curl 8.0.0"
      end

      if cmd:find("http://localhost:37749/health", 1, true) then
        vim.v.shell_error = 0
        return [[{"healthy":false,"status":"no session","features":[]}]] .. "\n200"
      end

      if cmd:find("http://localhost:37749/version", 1, true) then
        vim.v.shell_error = 0
        return [[{"version":"1.2.3","apiVersion":7,"server":"sagefs"}]] .. "\n200"
      end

      vim.v.shell_error = 1
      return ""
    end

    require("sagefs.health").check()

    local probe_commands = {}
    for _, cmd in ipairs(commands) do
      if cmd:find("http://localhost:37749/", 1, true) then
        table.insert(probe_commands, cmd)
      end
    end

    assert.are.same({
      "curl -s -w \"\\n%{http_code}\" --connect-timeout 2 http://localhost:37749/health",
      "curl -s -w \"\\n%{http_code}\" --connect-timeout 2 http://localhost:37749/version",
    }, probe_commands)

    local found_fallback_message = false
    for _, msg in ipairs(ok_messages) do
      if msg == "Daemon reachable on port 37749 via /version fallback" then
        found_fallback_message = true
        break
      end
    end

    assert.is_true(found_fallback_message)
  end)

  -- §5.12: `active` is a session TABLE (sagefs.active_session), never an id
  -- string — `s.id == active` compared a string to a table and was always
  -- false, so the "(active)" marker never rendered in :checkhealth's session
  -- list, and the fallback branch printed `table: 0x...` instead.
  it("marks the active session correctly by comparing ids, not a string to a table", function()
    local ok_messages = {}

    package.loaded["sagefs"] = {
      version = "test",
      state = { status = "connected" },
      config = { port = 37749, dashboard_port = 37750, auto_connect = false, check_on_save = false },
      session_list = {
        { id = "abc123", projects = { "X.fsproj" }, status = "Ready" },
        { id = "def456", projects = { "Y.fsproj" }, status = "Ready" },
      },
      active_session = { id = "abc123", projects = { "X.fsproj" }, status = "Ready" },
      testing_state = nil,
    }

    vim.health = {
      start = function(_) end,
      ok = function(msg) table.insert(ok_messages, msg) end,
      warn = function(_) end,
      info = function(_) end,
      error = function(_) end,
    }

    vim.fn.system = function(cmd)
      vim.v.shell_error = 1
      return ""
    end

    require("sagefs.health").check()

    local found_active_marker = false
    local found_table_leak = false
    for _, msg in ipairs(ok_messages) do
      if msg:find("abc123", 1, true) and msg:find("(active)", 1, true) then found_active_marker = true end
      if msg:find("table: 0x", 1, true) or msg:find("table: table", 1, true) then found_table_leak = true end
    end

    assert.is_true(found_active_marker, "the active session should carry the (active) marker")
    assert.is_false(found_table_leak, "must never print a raw table address")
  end)

  -- §5.12: the version-drift oracle shelled out to `sagefs --version` — the
  -- INSTALLED global tool — instead of the already-parsed `/version` probe
  -- (daemon_discovery.lua) or `apiVersion`/`version` off `/health`
  -- (init.lua's update_health_metadata), which is the actual PROCESS
  -- holding the port. A stale global-tool install can silently disagree
  -- with what's actually running — exactly the hazard this repo has been
  -- bitten by before (project_stale_deployed_daemon-class bugs). The
  -- authoritative, already-probed `state.daemon_version` must win when
  -- present; the CLI subprocess is only a fallback for when the plugin has
  -- never connected yet.
  it("uses the already-probed daemon version, not a stale installed CLI, for drift detection", function()
    local warn_messages = {}

    package.loaded["sagefs"] = {
      version = "0.5.543",
      state = { status = "connected", daemon_version = "0.6.708" },
      config = { port = 37749, dashboard_port = 37750, auto_connect = false, check_on_save = false },
      session_list = {},
      active_session = nil,
      testing_state = nil,
    }

    vim.health = {
      start = function(_) end,
      ok = function(_) end,
      warn = function(msg, hints) table.insert(warn_messages, msg) end,
      info = function(_) end,
      error = function(_) end,
    }

    vim.fn.system = function(cmd)
      if cmd == "sagefs --version" then
        vim.v.shell_error = 0
        return "0.6.283" -- a stale installed global tool — must NOT be used for drift
      end
      vim.v.shell_error = 1
      return ""
    end

    require("sagefs.health").check()

    local found_correct_drift = false
    local found_stale_drift = false
    for _, msg in ipairs(warn_messages) do
      if msg:find("0.6.708", 1, true) then found_correct_drift = true end
      if msg:find("0.6.283", 1, true) then found_stale_drift = true end
    end

    assert.is_true(found_correct_drift, "drift warning should cite the live daemon version (0.6.708)")
    assert.is_false(found_stale_drift, "drift warning must not cite the stale installed CLI version (0.6.283)")
  end)
end)

-- Pure version-drift check: catches the "plugin a minor behind the daemon" class
-- of bug (the 0.5 -> 0.6 SSE unification) loudly in :checkhealth. No vim needed.
describe("sagefs.health.version_drift", function()
  local health = require("sagefs.health")

  it("reports behind when the daemon minor is ahead", function()
    assert.are.equal("behind", health.version_drift("0.5.543", "0.6.551"))
  end)

  it("reports behind across a major bump", function()
    assert.are.equal("behind", health.version_drift("0.5.543", "1.0.0"))
  end)

  it("reports same on equal major.minor (patch ignored)", function()
    assert.are.equal("same", health.version_drift("0.6.1", "0.6.999"))
  end)

  it("reports ahead when the plugin is newer", function()
    assert.are.equal("ahead", health.version_drift("0.7.0", "0.6.999"))
  end)

  it("tolerates a build suffix on the daemon version", function()
    assert.are.equal("behind", health.version_drift("0.5.543", "0.6.551+abc123"))
  end)

  it("returns unknown for unparseable input", function()
    assert.are.equal("unknown", health.version_drift(nil, "0.6.0"))
    assert.are.equal("unknown", health.version_drift("0.6.0", "garbage"))
  end)
end)
