-- :SageFsStop stops the daemon this Neovim started. For a daemon it did not start
-- (started in a terminal, by a service, or by another editor) it used to warn
-- "SageFs daemon is not running" while the daemon was up and connected. It now says
-- it will not touch that daemon and names the CLI command that does.
require("spec.helper")

describe("commands :SageFsStop", function()
  local registered, plugin, notifications, jobstops, sse_stops
  local saved = {}

  local function setup_with(state)
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
    saved.jobstop = vim.fn.jobstop
    jobstops = {}
    vim.fn.jobstop = function(id) table.insert(jobstops, id) end

    notifications, sse_stops = {}, 0
    plugin = {
      daemon_state = state,
      config = { port = 37749, sagefs_path = "sagefs" },
    }
    local helpers = {
      base_url = function() return "http://localhost:37749" end,
      notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end,
      stop_sse = function() sse_stops = sse_stops + 1 end,
    }
    require("sagefs.commands").register_commands(plugin, helpers)
  end

  after_each(function()
    for _, k in ipairs({ "nvim_create_user_command", "nvim_create_augroup", "nvim_create_autocmd" }) do
      vim.api[k] = saved[k]
    end
    vim.fn.jobstop = saved.jobstop
    package.loaded["sagefs.commands"] = nil
  end)

  describe("on a daemon this Neovim did not start", function()
    before_each(function() setup_with(require("sagefs.daemon").new()) end)

    it("does not claim the daemon is not running", function()
      registered["SageFsStop"].handler({})
      assert.is_nil(notifications[1].msg:find("is not running", 1, true), notifications[1].msg)
    end)

    it("says it did not start the daemon and names the port", function()
      registered["SageFsStop"].handler({})
      local m = notifications[1].msg
      assert.is_truthy(m:find("did not start", 1, true), m)
      assert.is_truthy(m:find("37749", 1, true), m)
    end)

    it("names the CLI command that stops it", function()
      registered["SageFsStop"].handler({})
      assert.is_truthy(notifications[1].msg:find("`sagefs stop`", 1, true), notifications[1].msg)
    end)

    it("stops nothing: no job is stopped and the event stream stays up", function()
      registered["SageFsStop"].handler({})
      assert.equals(0, #jobstops)
      assert.equals(0, sse_stops)
    end)
  end)

  describe("on the daemon this Neovim started", function()
    before_each(function()
      local daemon = require("sagefs.daemon")
      setup_with(daemon.mark_running(daemon.mark_starting(daemon.new(), "App.fsproj", 37749), 42))
    end)

    it("stops the job and the event stream and says the daemon stopped", function()
      registered["SageFsStop"].handler({})
      assert.same({ 42 }, jobstops)
      assert.equals(1, sse_stops)
      assert.is_truthy(notifications[1].msg:find("stopped", 1, true), notifications[1].msg)
    end)
  end)
end)
