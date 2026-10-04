-- Tests: :SageFsWorkflow switches the active session's workflow through the
-- daemon's POST /api/sessions/{sid}/workflow. Same stubbing as
-- commands_app_run_spec: no daemon, no Neovim.
require("spec.helper")

local function unload()
  package.loaded["sagefs.commands"] = nil
  package.loaded["sagefs.workflow"] = nil
  package.loaded["sagefs.transport"] = nil
end

describe("commands.register_commands: :SageFsWorkflow", function()
  local commands, registered, plugin, helpers, notifications, http_calls
  local prev_create_user_command, prev_create_augroup, prev_create_autocmd, prev_ui

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
    http_calls = {}
    package.loaded["sagefs.transport"] = { http_json = function(opts) table.insert(http_calls, opts) end }
    commands = require("sagefs.commands")
    notifications = {}
    plugin = { active_session = { id = "abc12345" }, workflow_label = "REPL" }
    helpers = {
      base_url = function() return "http://localhost:37749" end,
      notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end,
    }
    commands.register_commands(plugin, helpers)
  end)

  after_each(function()
    vim.api.nvim_create_user_command = prev_create_user_command
    vim.api.nvim_create_augroup, vim.api.nvim_create_autocmd = prev_create_augroup, prev_create_autocmd
    vim.ui = prev_ui
    unload()
  end)

  it("takes an optional workflow name and completes the three names", function()
    local opts = registered["SageFsWorkflow"].opts
    assert.are.equal("?", opts.nargs)
    assert.are.same({ "hotreload" }, opts.complete("hot"))
  end)

  it("posts the named workflow to the active session's workflow route", function()
    registered["SageFsWorkflow"].handler({ args = "hotreload" })
    assert.are.equal(1, #http_calls)
    assert.are.equal("POST", http_calls[1].method)
    assert.are.equal("http://localhost:37749/api/sessions/abc12345/workflow", http_calls[1].url)
    assert.are.same({ workflow = "hotreload" }, http_calls[1].body)
  end)

  it("claims nothing until the daemon answers, because it may refuse the name", function()
    registered["SageFsWorkflow"].handler({ args = "bogus" })
    assert.are.equal(0, #notifications)
  end)

  it("with no active session, warns and sends nothing", function()
    plugin.active_session = nil
    registered["SageFsWorkflow"].handler({ args = "hotreload" })
    assert.are.equal(0, #http_calls)
    assert.are.equal(vim.log.levels.WARN, notifications[1].level)
  end)

  it("reports the daemon's acceptance with its words and the label the session now runs", function()
    registered["SageFsWorkflow"].handler({ args = "hotreload" })
    http_calls[1].callback(true, '{"message":"Hard reset accepted - replacement worker spawning.","sessionId":"abc12345","success":true,"workflow":"Hot Reload"}')
    local last = notifications[#notifications]
    assert.are.equal(vim.log.levels.INFO, last.level)
    assert.is_truthy(last.msg:find("Hot Reload", 1, true))
    assert.is_truthy(last.msg:find("restarts in place", 1, true))
    assert.is_truthy(last.msg:find("replacement worker spawning", 1, true))
  end)

  it("reads the session list again once the daemon accepted, so the statusline shows the new workflow", function()
    local reads = 0
    plugin.list_sessions = function() reads = reads + 1 end
    registered["SageFsWorkflow"].handler({ args = "hotreload" })
    assert.are.equal(0, reads, "nothing to read before the answer")
    http_calls[1].callback(true, '{"message":"ok","sessionId":"abc12345","success":true,"workflow":"Hot Reload"}')
    assert.are.equal(1, reads)
  end)

  it("does not read the session list for a refusal", function()
    local reads = 0
    plugin.list_sessions = function() reads = reads + 1 end
    registered["SageFsWorkflow"].handler({ args = "bogus" })
    http_calls[1].callback(false, '{"error":"unknown workflow","success":false}')
    assert.are.equal(0, reads)
  end)

  it("shows the daemon's refusal as a warning, in its own words", function()
    registered["SageFsWorkflow"].handler({ args = "bogus" })
    http_calls[1].callback(false, [[{"error":"Error: unknown workflow 'bogus'. Valid values: 'interactive' (REPL), 'livetesting' (Live Testing), 'hotreload' (Hot Reload)","success":false}]])
    local last = notifications[#notifications]
    assert.are.equal(vim.log.levels.WARN, last.level)
    assert.is_truthy(last.msg:find("Valid values", 1, true))
  end)

  it("with no name, offers the three workflows, marks the current one, and switches to the one picked", function()
    local offered
    vim.ui = { select = function(items, opts, cb) offered = { items = items, opts = opts }; cb(items[3], 3) end }
    registered["SageFsWorkflow"].handler({ args = "" })
    assert.are.equal(3, #offered.items)
    assert.is_truthy(offered.opts.format_item(offered.items[1]):find("(current)", 1, true), "REPL is the current workflow")
    assert.are.equal(1, #http_calls)
    assert.are.same({ workflow = "hotreload" }, http_calls[1].body)
  end)

  it("with no name and nothing picked, sends nothing", function()
    vim.ui = { select = function(_, _, cb) cb(nil, nil) end }
    registered["SageFsWorkflow"].handler({ args = "" })
    assert.are.equal(0, #http_calls)
  end)
end)
