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
end)
