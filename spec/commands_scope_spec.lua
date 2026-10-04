-- Tests: the commands that act on ONE session name it in the request. The daemon
-- refuses these when several sessions exist and none is named (AmbiguousSessions,
-- seen against a 0.6.892 daemon), so a plugin that names none fails for exactly
-- the users with more than one session, and works in every single-session test.
-- Same stubbing as commands_app_run_spec: no daemon, no Neovim.
require("spec.helper")

local function unload()
  package.loaded["sagefs.commands"] = nil
  package.loaded["sagefs.transport"] = nil
end

describe("commands that act on one session", function()
  local commands, registered, plugin, helpers, http_calls
  local prev_create_user_command, prev_create_augroup, prev_create_autocmd, prev_ui, prev_getcwd, prev_fnamemodify

  before_each(function()
    unload()
    prev_create_user_command = vim.api.nvim_create_user_command
    registered = {}
    vim.api.nvim_create_user_command = function(name, handler, opts)
      registered[name] = { handler = handler, opts = opts }
    end
    prev_create_augroup, prev_create_autocmd = vim.api.nvim_create_augroup, vim.api.nvim_create_autocmd
    vim.api.nvim_create_augroup = function() return 1 end
    vim.api.nvim_create_autocmd = function() end
    prev_ui = vim.ui
    prev_getcwd, prev_fnamemodify = vim.fn.getcwd, vim.fn.fnamemodify
    vim.fn.getcwd = function() return "/cwd" end
    vim.fn.fnamemodify = function(path) return path end
    http_calls = {}
    package.loaded["sagefs.transport"] = { http_json = function(opts) table.insert(http_calls, opts) end }
    commands = require("sagefs.commands")
    plugin = { active_session = { id = "abc12345", working_directory = "/work/app" }, testing_state = {} }
    helpers = {
      base_url = function() return "http://localhost:37749" end,
      notify = function() end,
    }
    commands.register_commands(plugin, helpers)
  end)

  after_each(function()
    vim.api.nvim_create_user_command = prev_create_user_command
    vim.api.nvim_create_augroup, vim.api.nvim_create_autocmd = prev_create_augroup, prev_create_autocmd
    vim.ui = prev_ui
    vim.fn.getcwd, vim.fn.fnamemodify = prev_getcwd, prev_fnamemodify
    unload()
  end)

  local function sid_of(call)
    return call.body and call.body.sessionId
  end

  it(":SageFsRunTests names the session, and keeps the pattern", function()
    registered["SageFsRunTests"].handler({ args = "Cart" })
    assert.equals("abc12345", sid_of(http_calls[1]))
    assert.equals("Cart", http_calls[1].body.pattern)
  end)

  it(":SageFsEnableTesting names the session", function()
    registered["SageFsEnableTesting"].handler({})
    assert.equals("abc12345", sid_of(http_calls[1]))
  end)

  it(":SageFsDisableTesting names the session", function()
    registered["SageFsDisableTesting"].handler({})
    assert.equals("abc12345", sid_of(http_calls[1]))
  end)

  it(":SageFsCancel names the session, not only Neovim's directory", function()
    registered["SageFsCancel"].handler({})
    assert.equals("abc12345", sid_of(http_calls[1]))
  end)

  it(":SageFsTestTrace reads the session's own trace (?session=)", function()
    registered["SageFsTestTrace"].handler({})
    assert.equals("GET", http_calls[1].method)
    assert.equals("http://localhost:37749/api/live-testing/test-trace?session=abc12345", http_calls[1].url)
  end)

  it(":SageFsLoadScript loads into the session, not whichever the daemon last switched to", function()
    registered["SageFsLoadScript"].handler({ args = "/work/app/setup.fsx" })
    assert.equals("abc12345", sid_of(http_calls[1]))
    assert.equals("/work/app", http_calls[1].body.working_directory)
    assert.is_truthy(http_calls[1].body.code:find("setup.fsx", 1, true))
  end)

  it(":SageFsTestPolicy names the session when it sets a policy", function()
    local testing = require("sagefs.testing")
    plugin.testing_state = testing.new()
    -- The pickers' contents come from discovered tests; the request is what is tested here.
    local original_items, original_options = testing.format_picker_items, testing.format_policy_options
    testing.format_picker_items = function() return { "Unit 3 tests" } end
    testing.format_policy_options = function() return { "OnEveryChange" } end
    vim.ui = { select = function(items, _, cb) cb(items[1], 1) end }
    registered["SageFsTestPolicy"].handler({})
    local posted
    for _, c in ipairs(http_calls) do
      if c.url:find("/api/live-testing/policy", 1, true) then posted = c end
    end
    testing.format_picker_items, testing.format_policy_options = original_items, original_options
    assert.is_truthy(posted, "a policy request went out")
    assert.equals("abc12345", sid_of(posted))
  end)

  it("with no active session none of them invents one, and a single-session daemon still infers it", function()
    plugin.active_session = nil
    registered["SageFsEnableTesting"].handler({})
    registered["SageFsRunTests"].handler({ args = "" })
    registered["SageFsTestTrace"].handler({})
    for _, c in ipairs(http_calls) do
      assert.is_nil(sid_of(c))
      assert.is_nil(c.url:find("session=", 1, true))
    end
  end)
end)
