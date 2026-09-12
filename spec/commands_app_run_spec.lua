-- Tests — :SageFsRunApp / :SageFsStopApp registration and request construction.
-- No live daemon required: vim.api.nvim_create_user_command and
-- sagefs.transport are stubbed so we can inspect what commands.lua builds.
require("spec.helper")

local function unload()
  package.loaded["sagefs.commands"] = nil
  package.loaded["sagefs.app_run"] = nil
  package.loaded["sagefs.transport"] = nil
end

describe("commands.register_commands — run/stop app", function()
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

    -- register_commands() also wires an eager autocmd group for the test
    -- panel (unrelated to run/stop app) — stub the bits it touches so
    -- registration can run without a real Neovim instance.
    prev_create_augroup = vim.api.nvim_create_augroup
    prev_create_autocmd = vim.api.nvim_create_autocmd
    vim.api.nvim_create_augroup = function() return 1 end
    vim.api.nvim_create_autocmd = function() end

    http_calls = {}
    -- Stub the transport module the way commands.lua will `require` it,
    -- so we can inspect requests without a live daemon.
    package.loaded["sagefs.transport"] = {
      http_json = function(opts)
        table.insert(http_calls, opts)
      end,
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

  it("registers SageFsRunApp and SageFsStopApp", function()
    assert.is_not_nil(registered["SageFsRunApp"])
    assert.is_not_nil(registered["SageFsStopApp"])
  end)

  it("SageFsRunApp POSTs to /api/sessions/<sid>/run-app with no body by default", function()
    registered["SageFsRunApp"].handler({ args = "" })

    assert.are.equal(1, #http_calls)
    assert.are.equal("POST", http_calls[1].method)
    assert.are.equal("http://localhost:37749/api/sessions/abc12345/run-app", http_calls[1].url)
    assert.is_nil(http_calls[1].body)
  end)

  it("SageFsRunApp includes the named project in the request body", function()
    registered["SageFsRunApp"].handler({ args = "WebApp" })

    assert.same({ project = "WebApp" }, http_calls[1].body)
  end)

  it("SageFsRunApp warns and skips the request when there is no active session", function()
    plugin.active_session = nil
    registered["SageFsRunApp"].handler({ args = "" })

    assert.are.equal(0, #http_calls)
    assert.are.equal(1, #notifications)
    assert.are.equal(vim.log.levels.WARN, notifications[1].level)
  end)

  it("SageFsStopApp POSTs to /api/sessions/<sid>/stop-app with no body", function()
    registered["SageFsStopApp"].handler({})

    assert.are.equal(1, #http_calls)
    assert.are.equal("POST", http_calls[1].method)
    assert.are.equal("http://localhost:37749/api/sessions/abc12345/stop-app", http_calls[1].url)
    assert.is_nil(http_calls[1].body)
  end)

  it("SageFsStopApp warns and skips the request when there is no active session", function()
    plugin.active_session = nil
    registered["SageFsStopApp"].handler({})

    assert.are.equal(0, #http_calls)
    assert.are.equal(1, #notifications)
  end)

  it("notifies with the URL and stores app_run_state on a successful run response", function()
    registered["SageFsRunApp"].handler({ args = "" })
    local cb = http_calls[1].callback

    cb(true, vim.json.encode({ State = "Running", Message = "listening", Urls = { "http://localhost:5000" } }))

    assert.are.equal(1, #notifications)
    assert.truthy(notifications[1].msg:find("http://localhost:5000", 1, true))
    assert.are.equal(vim.log.levels.INFO, notifications[1].level)
    assert.are.equal("Running", plugin.app_run_state.kind)
  end)

  it("warns on a BuildFailed run response", function()
    registered["SageFsRunApp"].handler({ args = "" })
    local cb = http_calls[1].callback

    cb(true, vim.json.encode({ State = "BuildFailed", Message = "FS0039", Urls = {} }))

    assert.are.equal(vim.log.levels.WARN, notifications[1].level)
    assert.truthy(notifications[1].msg:find("FS0039", 1, true))
  end)

  it("surfaces message + suggestedAction on a non-200 error response", function()
    registered["SageFsStopApp"].handler({})
    local cb = http_calls[1].callback

    cb(false, vim.json.encode({ case = "NotFound", message = "Unknown session", suggestedAction = "Create one" }))

    assert.are.equal(1, #notifications)
    assert.truthy(notifications[1].msg:find("Unknown session", 1, true))
    assert.truthy(notifications[1].msg:find("Create one", 1, true))
    assert.are.equal(vim.log.levels.WARN, notifications[1].level)
  end)

  it("notifies stopped for a successful stop response", function()
    registered["SageFsStopApp"].handler({})
    local cb = http_calls[1].callback

    cb(true, vim.json.encode({ State = "NotRunning", Message = "", Urls = {} }))

    assert.truthy(notifications[1].msg:find("stopped"))
  end)
end)
