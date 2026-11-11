-- A second :SageFsStart while this Neovim already owns a daemon job used to say
-- "already running" and stop. A daemon that was still booting stayed unreachable
-- until the user found :SageFsConnect on their own. It now connects.
require("spec.helper")

describe("commands :SageFsStart when the daemon job already runs", function()
  local registered, plugin, notifications, checks, sse_starts
  local saved = {}

  before_each(function()
    package.loaded["sagefs.commands"] = nil
    for _, k in ipairs({ "nvim_create_user_command", "nvim_create_augroup", "nvim_create_autocmd" }) do
      saved[k] = vim.api[k]
    end
    registered = {}
    vim.api.nvim_create_user_command = function(name, handler, opts)
      registered[name] = { handler = handler, opts = opts }
    end
    vim.api.nvim_create_augroup = function() return 1 end
    vim.api.nvim_create_autocmd = function() end

    local daemon = require("sagefs.daemon")
    notifications, checks, sse_starts = {}, {}, 0
    local state = daemon.mark_running(daemon.mark_starting(daemon.new(), "App.fsproj", 37749), 42)
    plugin = {
      daemon_state = state,
      config = { port = 37749, sagefs_path = "sagefs" },
      health_check = function(cb) table.insert(checks, cb) end,
    }
    local helpers = {
      base_url = function() return "http://localhost:37749" end,
      notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end,
      start_sse = function() sse_starts = sse_starts + 1 end,
    }
    require("sagefs.commands").register_commands(plugin, helpers)
  end)

  after_each(function()
    for _, k in ipairs({ "nvim_create_user_command", "nvim_create_augroup", "nvim_create_autocmd" }) do
      vim.api[k] = saved[k]
    end
    package.loaded["sagefs.commands"] = nil
  end)

  it("probes the daemon instead of only refusing", function()
    registered["SageFsStart"].handler({ args = "" })
    assert.equals(1, #checks)
  end)

  it("starts the event stream when the probe finds the daemon healthy", function()
    registered["SageFsStart"].handler({ args = "" })
    checks[1](true)
    assert.equals(1, sse_starts)
  end)

  it("does not start the event stream when the daemon is still unreachable", function()
    registered["SageFsStart"].handler({ args = "" })
    checks[1](false)
    assert.equals(0, sse_starts)
  end)

  it("says the daemon was already started and names :SageFsConnect as the retry", function()
    registered["SageFsStart"].handler({ args = "" })
    local m = notifications[1].msg
    assert.is_truthy(m:find("already started", 1, true), m)
    assert.is_truthy(m:find(":SageFsConnect", 1, true), m)
  end)
end)
