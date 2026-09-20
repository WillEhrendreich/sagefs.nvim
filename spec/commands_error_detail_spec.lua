-- spec/commands_error_detail_spec.lua — §5.8: suggestedAction must reach the user
--
-- commands.lua's two local `err_detail(raw)` closures truncated the RAW
-- JSON body to 200 bytes before anyone parsed it — since `suggestedAction`
-- serializes last (SageFsError.toJson), that truncation typically cut off
-- exactly the remedy. Separately, five sites computed
-- `(resp and (resp.message or resp.reason)) or raw or "Unknown error"`,
-- discarding `suggestedAction` even though it had already been decoded.
-- Both patterns must now surface `message → suggestedAction` via
-- util.format_server_error.
require("spec.helper")

local function unload()
  package.loaded["sagefs.commands"] = nil
  package.loaded["sagefs.transport"] = nil
  package.loaded["sagefs.testing"] = nil
end

describe("commands.lua error sites surface suggestedAction (§5.8)", function()
  local commands
  local registered
  local plugin
  local helpers
  local notifications
  local http_calls
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

    http_calls = {}
    package.loaded["sagefs.transport"] = {
      http_json = function(opts) table.insert(http_calls, opts) end,
    }

    commands = require("sagefs.commands")

    notifications = {}
    plugin = { active_session = { id = "abc12345" }, testing_state = require("sagefs.testing").new() }
    helpers = {
      base_url = function() return "http://localhost:37749" end,
      dashboard_url = function() return "http://localhost:37750" end,
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

  describe(":SageFsRunTests — transport failure (err_detail)", function()
    it("shows the suggestedAction from a structured error body, not a raw JSON truncation", function()
      registered["SageFsRunTests"].handler({ args = "" })
      local long_case = string.rep("x", 250) -- forces the old 200-byte cut to land mid-JSON
      local body = vim.json.encode({
        case = long_case,
        message = "Cannot run tests — no active session",
        suggestedAction = "Run :SageFsCreateSession first",
      })
      http_calls[1].callback(false, body)

      assert.equals(1, #notifications)
      assert.is_truthy(notifications[1].msg:find("Run :SageFsCreateSession first", 1, true),
        "suggestedAction must survive even when the JSON is longer than the old 200-byte cut")
    end)
  end)

  describe(":SageFsEnableTesting — resp.message/resp.reason pattern", function()
    it("appends suggestedAction on a structured failure response", function()
      registered["SageFsEnableTesting"].handler({})
      local body = vim.json.encode({
        success = false,
        message = "No active session",
        suggestedAction = "Run :SageFsCreateSession to create one",
      })
      http_calls[1].callback(true, body)

      assert.equals(1, #notifications)
      assert.is_truthy(notifications[1].msg:find("No active session", 1, true))
      assert.is_truthy(notifications[1].msg:find("Run :SageFsCreateSession to create one", 1, true))
    end)
  end)

  describe(":SageFsTestTrace — err_detail on a plain fetch failure", function()
    it("falls back to raw text when the body isn't JSON (no crash, no silent swallow)", function()
      registered["SageFsTestTrace"].handler({})
      http_calls[1].callback(false, "connect: refused")

      assert.equals(1, #notifications)
      assert.is_truthy(notifications[1].msg:find("connect: refused", 1, true))
    end)
  end)
end)
