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

  -- §5.12 (kept): version information must come from the daemon actually
  -- holding the port (state.daemon_version), never from a stale installed
  -- CLI. Since the plugin and SageFs are released in lockstep, a different
  -- number is now only a quiet info line, never a warning.
  it("cites the live daemon version, not a stale installed CLI, in the version info line", function()
    local warn_messages, info_messages = {}, {}

    package.loaded["sagefs"] = {
      version = "0.6.875",
      state = { status = "connected", daemon_version = "0.6.880", api_version = 3 },
      config = { port = 37749, dashboard_port = 37750, auto_connect = false, check_on_save = false },
      session_list = {},
      active_session = nil,
      testing_state = nil,
    }

    vim.health = {
      start = function(_) end,
      ok = function(_) end,
      warn = function(msg, hints) table.insert(warn_messages, msg) end,
      info = function(msg) table.insert(info_messages, msg) end,
      error = function(_) end,
    }

    vim.fn.system = function(cmd)
      if cmd == "sagefs --version" then
        vim.v.shell_error = 0
        return "0.6.283" -- a stale installed global tool: must NOT be cited
      end
      vim.v.shell_error = 1
      return ""
    end

    require("sagefs.health").check()

    local found_correct, found_stale = false, false
    for _, msg in ipairs(info_messages) do
      if msg:find("0.6.880", 1, true) and msg:find("update the plugin when you can", 1, true) then found_correct = true end
      if msg:find("0.6.283", 1, true) then found_stale = true end
    end
    for _, msg in ipairs(warn_messages) do
      assert.is_nil(msg:find("version", 1, true) and msg:find("behind", 1, true),
        "a version-number difference must never be a warning: " .. msg)
    end

    assert.is_true(found_correct, "info line should cite the live daemon version (0.6.880)")
    assert.is_false(found_stale, "must not cite the stale installed CLI version (0.6.283)")
  end)

  -- roast §5.3: "Live testing: enabled, no tests discovered yet" used to
  -- render for BOTH "discovery hasn't run" and "discovery ran, genuinely
  -- zero tests" — the only surface that even tried to make this
  -- distinction (§5.13) still couldn't, because normalize_summary dropped
  -- DiscoveryState/ActivityText before they ever reached testing_state.
  local function base_sagefs(testing_state)
    return {
      version = "test",
      state = { status = "connected" },
      config = { port = 37749, dashboard_port = 37750, auto_connect = false, check_on_save = false },
      session_list = {},
      active_session = nil,
      testing_state = testing_state,
    }
  end

  local function no_probe_system(cmd)
    vim.v.shell_error = 1
    return ""
  end

  it("shows a distinct message while discovery is still running", function()
    local info_messages = {}
    package.loaded["sagefs"] = base_sagefs({
      enabled = true,
      summary = { total = 0, discovery_state = "discovering" },
      run_phase = "Idle",
    })
    vim.health = {
      start = function(_) end, ok = function(_) end, warn = function(_) end,
      info = function(msg) table.insert(info_messages, msg) end, error = function(_) end,
    }
    vim.fn.system = no_probe_system

    require("sagefs.health").check()

    local found = false
    for _, msg in ipairs(info_messages) do
      if msg:find("discover", 1, true) and msg:find("progress", 1, true) then found = true end
    end
    assert.is_true(found, "expected a 'discovery in progress' message")
  end)

  it("shows a distinct message when discovery completed with genuinely zero tests", function()
    local info_messages = {}
    package.loaded["sagefs"] = base_sagefs({
      enabled = true,
      summary = { total = 0, discovery_state = "ready_zero_tests", ready_zero_tests = true },
      run_phase = "Idle",
    })
    vim.health = {
      start = function(_) end, ok = function(_) end, warn = function(_) end,
      info = function(msg) table.insert(info_messages, msg) end, error = function(_) end,
    }
    vim.fn.system = no_probe_system

    require("sagefs.health").check()

    local found_zero, found_progress = false, false
    for _, msg in ipairs(info_messages) do
      if msg:find("no tests found", 1, true) then found_zero = true end
      if msg:find("progress", 1, true) then found_progress = true end
    end
    assert.is_true(found_zero, "expected a 'no tests found' message")
    assert.is_false(found_progress, "must not say discovery is still running")
  end)

  it("renders the server's own ActivityText verbatim when present", function()
    local info_messages = {}
    package.loaded["sagefs"] = base_sagefs({
      enabled = true,
      summary = { total = 0, discovery_state = "discovering", activity_text = "Compiling test assembly..." },
      run_phase = "Idle",
    })
    vim.health = {
      start = function(_) end, ok = function(_) end, warn = function(_) end,
      info = function(msg) table.insert(info_messages, msg) end, error = function(_) end,
    }
    vim.fn.system = no_probe_system

    require("sagefs.health").check()

    local found = false
    for _, msg in ipairs(info_messages) do
      if msg:find("Compiling test assembly...", 1, true) then found = true end
    end
    assert.is_true(found, "expected the server's ActivityText to be rendered")
  end)
end)

-- The :checkhealth compatibility section: wire (apiVersion) compatibility is
-- the thing that can fail; the version-number comparison is information.
describe("sagefs.health compatibility section", function()
  local original_system, original_v, original_trim, original_health, original_loaded

  before_each(function()
    package.loaded["sagefs.health"] = nil
    package.loaded["sagefs.compat"] = nil
    original_system, original_v, original_trim = vim.fn.system, vim.v, vim.trim
    original_health, original_loaded = vim.health, package.loaded["sagefs"]
    vim.v = { shell_error = 1 }
    vim.trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
  end)

  after_each(function()
    vim.fn.system, vim.v, vim.trim = original_system, original_v, original_trim
    vim.health, package.loaded["sagefs"] = original_health, original_loaded
    package.loaded["sagefs.health"] = nil
  end)

  -- A healthy, reachable daemon, so a test that expects no warnings and no
  -- errors is not tripped by an unrelated "daemon not reachable".
  local REACHABLE = [[{"healthy":true,"status":"ready","apiVersion":3,"version":"0.6.875","features":[]}]]
  local function run(plugin, state, health_json)
    health_json = health_json or REACHABLE
    local out = { ok = {}, info = {}, warn = {}, error = {}, hints = {} }
    package.loaded["sagefs"] = {
      version = plugin,
      state = state,
      config = { port = 37749, dashboard_port = 37750, auto_connect = false, check_on_save = false },
      session_list = {}, active_session = nil, testing_state = nil,
    }
    vim.health = {
      start = function(_) end,
      ok = function(m) table.insert(out.ok, m) end,
      info = function(m) table.insert(out.info, m) end,
      warn = function(m, h) table.insert(out.warn, m); out.hints[m] = h end,
      error = function(m, h) table.insert(out.error, m); out.hints[m] = h end,
    }
    vim.fn.system = function(cmd)
      if health_json and cmd:find("localhost:37749/health", 1, true) then
        vim.v.shell_error = 0
        return health_json .. "\n200"
      end
      -- The CLI and curl are installed; anything else (other probes) is unreachable.
      if cmd == "sagefs --version" or cmd == "curl --version" then
        vim.v.shell_error = 0
        return "0.6.875"
      end
      vim.v.shell_error = 1
      return ""
    end
    require("sagefs.health").check()
    return out
  end

  local function has(list, needle)
    for _, m in ipairs(list) do if m:find(needle, 1, true) then return true end end
    return false
  end

  it("says compatible when plugin and daemon agree on the api version", function()
    local out = run("0.6.875", { status = "connected", api_version = 3, daemon_version = "0.6.875" })
    assert.is_true(has(out.ok, "plugin understands api 3, daemon speaks api 3: compatible"))
    assert.equals(0, #out.warn)
    assert.equals(0, #out.error)
  end)

  it("reads the api version off the /health probe when the plugin has not connected", function()
    local out = run("0.6.875", { status = "disconnected" },
      [[{"healthy":true,"status":"Ready","apiVersion":3,"version":"0.6.875.0","features":[]}]])
    assert.is_true(has(out.ok, "plugin understands api 3, daemon speaks api 3: compatible"))
  end)

  it("names the incompatibility and the fix when the daemon is newer than the plugin understands", function()
    local out = run("0.6.875", { status = "connected", api_version = 99, daemon_version = "0.6.875" })
    local msg
    for _, m in ipairs(out.error) do if m:find("api 99", 1, true) then msg = m end end
    assert.is_truthy(msg, "a real incompatibility is reported as an error")
    assert.is_truthy(table.concat(out.hints[msg], "\n"):find("update the plugin", 1, true))
  end)

  it("names the incompatibility and the fix when the daemon is older than the plugin needs", function()
    local out = run("0.6.875", { status = "connected", api_version = 2, daemon_version = "0.6.700" })
    local msg
    for _, m in ipairs(out.error) do if m:find("api 2", 1, true) then msg = m end end
    assert.is_truthy(msg)
    assert.is_truthy(table.concat(out.hints[msg], "\n"):find("dotnet tool update --global sagefs", 1, true))
  end)

  it("stays silent about versions when plugin and daemon numbers match", function()
    local out = run("0.6.875", { status = "connected", api_version = 3, daemon_version = "0.6.875.0" })
    assert.is_false(has(out.info, "update the plugin when you can"))
    assert.is_false(has(out.info, "update the daemon when you can"))
    assert.equals(0, #out.warn)
  end)

  it("prints a quiet info line, not a warning, when the daemon number is higher", function()
    local out = run("0.6.875", { status = "connected", api_version = 3, daemon_version = "0.6.880" })
    assert.is_true(has(out.info, "plugin 0.6.875, daemon 0.6.880: update the plugin when you can"))
    assert.equals(0, #out.warn)
    assert.equals(0, #out.error)
  end)

  it("prints a quiet info line when the plugin number is higher", function()
    local out = run("0.6.880", { status = "connected", api_version = 3, daemon_version = "0.6.875" })
    assert.is_true(has(out.info, "plugin 0.6.880, daemon 0.6.875: update the daemon when you can"))
    assert.equals(0, #out.warn)
  end)

  it("never says the plugin is behind just because the numbers differ", function()
    local out = run("0.5.543", { status = "connected", api_version = 3, daemon_version = "0.6.875" })
    for _, list in ipairs({ out.warn, out.error }) do
      assert.is_false(has(list, "behind"))
    end
  end)
end)

describe("sagefs.health when the sagefs binary is missing", function()
  local original_system, original_v, original_health, original_loaded

  before_each(function()
    package.loaded["sagefs.health"] = nil
    original_system, original_v = vim.fn.system, vim.v
    original_health, original_loaded = vim.health, package.loaded["sagefs"]
    vim.v = { shell_error = 127 }
    vim.fn.system = function() return "" end
  end)

  after_each(function()
    vim.fn.system, vim.v = original_system, original_v
    vim.health, package.loaded["sagefs"] = original_health, original_loaded
    package.loaded["sagefs.health"] = nil
  end)

  it("says it is not on PATH, how to install it, and how to point the plugin at a binary", function()
    local errors = {}
    package.loaded["sagefs"] = {} -- not initialised: only the CLI section runs
    vim.health = {
      start = function() end, ok = function() end, info = function() end, warn = function() end,
      error = function(m, hints) table.insert(errors, { msg = m, hints = hints or {} }) end,
    }
    require("sagefs.health").check()
    local found
    for _, e in ipairs(errors) do
      if e.msg:find("SageFs CLI not found", 1, true) then found = e end
    end
    assert.is_truthy(found)
    local text = found.msg .. "\n" .. table.concat(found.hints, "\n")
    assert.is_truthy(text:find("PATH", 1, true))
    assert.is_truthy(text:find("dotnet tool install --global sagefs", 1, true))
    assert.is_truthy(text:find("sagefs_path", 1, true))
  end)
end)

describe("sagefs.health with a ~ in sagefs_path", function()
  local original_system, original_v, original_health, original_loaded, original_expand, original_trim

  before_each(function()
    package.loaded["sagefs.health"] = nil
    original_system, original_v, original_expand = vim.fn.system, vim.v, vim.fn.expand
    original_health, original_loaded, original_trim = vim.health, package.loaded["sagefs"], vim.trim
    vim.trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
  end)

  after_each(function()
    vim.fn.system, vim.v, vim.fn.expand, vim.trim = original_system, original_v, original_expand, original_trim
    vim.health, package.loaded["sagefs"] = original_health, original_loaded
    package.loaded["sagefs.health"] = nil
  end)

  it("runs the expanded path, so a ~/.dotnet/tools/sagefs install is found", function()
    local commands, oks = {}, {}
    vim.v = { shell_error = 0 }
    vim.fn.expand = function(p) return (p:gsub("^~", "/home/u")) end
    vim.fn.system = function(cmd) table.insert(commands, cmd); return "0.6.875" end
    package.loaded["sagefs"] = { config = { sagefs_path = "~/.dotnet/tools/sagefs" } }
    vim.health = {
      start = function() end, info = function() end, warn = function() end, error = function() end,
      ok = function(m) table.insert(oks, m) end,
    }
    require("sagefs.health").check()
    assert.equals("/home/u/.dotnet/tools/sagefs --version", commands[1])
    assert.is_truthy(oks[1] and oks[1]:find("SageFs CLI found", 1, true))
  end)
end)
