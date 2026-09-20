-- spec/commands_hotreload_spec.lua — :SageFsWatchAll / :SageFsUnwatchAll
--
-- §5.2/§5.9: these commands used to notify success unconditionally
-- (watch_all's callback fired the same way on failure) and used a bare
-- "No active session" message instead of the good one hotreload.lua:79
-- already gives for the identical precondition.
require("spec.helper")

local function unload()
  package.loaded["sagefs.commands"] = nil
  package.loaded["sagefs.hotreload"] = nil
end

describe("commands.register_commands — watch all / unwatch all", function()
  local commands
  local registered
  local plugin
  local helpers
  local notifications
  local hotreload_calls
  local prev_create_user_command
  local prev_create_augroup
  local prev_create_autocmd

  before_each(function()
    unload()

    prev_create_user_command = vim.api.nvim_create_user_command
    registered = {}
    vim.api.nvim_create_user_command = function(name, handler, opts)
      registered[name] = { handler = handler, opts = opts }
    end

    prev_create_augroup = vim.api.nvim_create_augroup
    prev_create_autocmd = vim.api.nvim_create_autocmd
    vim.api.nvim_create_augroup = function() return 1 end
    vim.api.nvim_create_autocmd = function() end

    hotreload_calls = {}
    package.loaded["sagefs.hotreload"] = {
      state = { files = { "A.fs", "B.fs" } },
      watch_all = function(sid, cb) table.insert(hotreload_calls, { fn = "watch_all", sid = sid, cb = cb }) end,
      unwatch_all = function(sid, cb) table.insert(hotreload_calls, { fn = "unwatch_all", sid = sid, cb = cb }) end,
      picker = function() end,
    }

    commands = require("sagefs.commands")

    notifications = {}
    plugin = { active_session = { id = "abc12345" } }
    helpers = {
      base_url = function() return "http://localhost:37749" end,
      notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end,
    }

    commands.register_commands(plugin, helpers)
  end)

  after_each(function()
    vim.api.nvim_create_user_command = prev_create_user_command
    vim.api.nvim_create_augroup = prev_create_augroup
    vim.api.nvim_create_autocmd = prev_create_autocmd
    unload()
  end)

  describe("SageFsWatchAll", function()
    it("warns with the good no-session message when there is no active session", function()
      plugin.active_session = nil
      registered["SageFsWatchAll"].handler({})

      assert.equals(0, #hotreload_calls)
      assert.equals(1, #notifications)
      assert.equals(vim.log.levels.WARN, notifications[1].level)
      assert.is_truthy(notifications[1].msg:find(":SageFsCreateSession", 1, true))
      assert.is_truthy(notifications[1].msg:find(":SageFsStart", 1, true))
    end)

    it("notifies success only when the request actually succeeded", function()
      registered["SageFsWatchAll"].handler({})
      hotreload_calls[1].cb(true)

      assert.equals(1, #notifications)
      assert.is_truthy(notifications[1].msg:find("Watching all 2 files", 1, true))
      assert.are_not.equal(vim.log.levels.ERROR, notifications[1].level)
    end)

    it("reports failure — never claims success for a failed watch-all", function()
      registered["SageFsWatchAll"].handler({})
      hotreload_calls[1].cb(false)

      assert.equals(1, #notifications)
      assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
      assert.is_falsy(notifications[1].msg:find("Watching all", 1, true))
    end)
  end)

  describe("SageFsUnwatchAll", function()
    it("warns with the good no-session message when there is no active session", function()
      plugin.active_session = nil
      registered["SageFsUnwatchAll"].handler({})

      assert.equals(0, #hotreload_calls)
      assert.is_truthy(notifications[1].msg:find(":SageFsCreateSession", 1, true))
    end)

    it("reports failure — never claims success for a failed unwatch-all", function()
      registered["SageFsUnwatchAll"].handler({})
      hotreload_calls[1].cb(false)

      assert.equals(1, #notifications)
      assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
      assert.is_falsy(notifications[1].msg:find("Unwatched", 1, true))
    end)
  end)
end)
