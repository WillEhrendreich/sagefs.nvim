-- :SageFsStart with no sagefs binary used to die with a raw Lua traceback
-- (E475 from jobstart). It must say what is wrong and what to do.
require("spec.helper")

local function unload()
  package.loaded["sagefs.commands"] = nil
  package.loaded["sagefs.transport"] = nil
  package.loaded["sagefs.spawn"] = nil
end

describe("commands :SageFsStart without a sagefs binary", function()
  local registered, plugin, helpers, notifications, jobstarts
  local saved = {}

  before_each(function()
    unload()
    for _, k in ipairs({ "nvim_create_user_command", "nvim_create_augroup", "nvim_create_autocmd" }) do
      saved[k] = vim.api[k]
    end
    registered = {}
    vim.api.nvim_create_user_command = function(name, handler, opts)
      registered[name] = { handler = handler, opts = opts }
    end
    vim.api.nvim_create_augroup = function() return 1 end
    vim.api.nvim_create_autocmd = function() end

    saved.fn = vim.fn
    vim.fn = setmetatable({}, { __index = saved.fn })
    jobstarts = {}
    vim.fn.executable = function() return 0 end
    vim.fn.jobstart = function(cmd)
      table.insert(jobstarts, cmd)
      error("Vim:E475: Invalid value for argument cmd: 'sagefs' is not executable", 0)
    end

    package.loaded["sagefs.transport"] = { http_json = function() end }
    local commands = require("sagefs.commands")
    local daemon = require("sagefs.daemon")
    notifications = {}
    plugin = {
      daemon_state = daemon.new(),
      config = { port = 37749, sagefs_path = "sagefs" },
    }
    helpers = {
      base_url = function() return "http://localhost:37749" end,
      notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end,
      start_sse = function() end,
    }
    commands.register_commands(plugin, helpers)
  end)

  after_each(function()
    for _, k in ipairs({ "nvim_create_user_command", "nvim_create_augroup", "nvim_create_autocmd" }) do
      vim.api[k] = saved[k]
    end
    vim.fn = saved.fn
    unload()
  end)

  it("gives an actionable message instead of a traceback", function()
    assert.has_no.errors(function() registered["SageFsStart"].handler({ args = "App.fsproj" }) end)
    assert.equals(1, #notifications)
    local m = notifications[1].msg
    assert.equals(vim.log.levels.ERROR, notifications[1].level)
    assert.is_truthy(m:find("sagefs is not on PATH", 1, true))
    assert.is_truthy(m:find("dotnet tool install --global sagefs", 1, true))
    assert.is_truthy(m:find("sagefs_path", 1, true))
  end)

  it("never tries to spawn when the binary is missing", function()
    registered["SageFsStart"].handler({ args = "App.fsproj" })
    assert.equals(0, #jobstarts)
  end)

  it("leaves the daemon state failed, not stuck in starting", function()
    registered["SageFsStart"].handler({ args = "App.fsproj" })
    assert.equals("failed", plugin.daemon_state.status)
  end)

  it("handles a spawn that fails even though the binary looked present", function()
    vim.fn.executable = function() return 1 end
    assert.has_no.errors(function() registered["SageFsStart"].handler({ args = "App.fsproj" }) end)
    assert.equals(1, #jobstarts)
    assert.equals(vim.log.levels.ERROR, notifications[#notifications].level)
    assert.is_truthy(notifications[#notifications].msg:find("sagefs", 1, true))
    assert.equals("failed", plugin.daemon_state.status)
  end)

  it("uses the configured sagefs_path as the command", function()
    plugin.config.sagefs_path = "/opt/tools/sagefs"
    vim.fn.executable = function(b) return b == "/opt/tools/sagefs" and 1 or 0 end
    registered["SageFsStart"].handler({ args = "App.fsproj" })
    assert.equals("/opt/tools/sagefs", jobstarts[1][1])
  end)

  it("names a configured path that is not executable", function()
    plugin.config.sagefs_path = "/opt/nope/sagefs"
    registered["SageFsStart"].handler({ args = "App.fsproj" })
    assert.is_truthy(notifications[1].msg:find("/opt/nope/sagefs", 1, true))
  end)
end)
