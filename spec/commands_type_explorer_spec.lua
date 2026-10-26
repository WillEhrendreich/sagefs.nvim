-- Tests: :SageFsTypeExplorer asks /api/completions for a bounded number of
-- members, says so when the set was larger, and says why when the daemon could
-- not list. Same stubbing as commands_workflow_spec: no daemon, no Neovim.
require("spec.helper")

local function unload()
  package.loaded["sagefs.commands"] = nil
  package.loaded["sagefs.transport"] = nil
  package.loaded["sagefs.render"] = nil
  package.loaded["sagefs.type_explorer_cache"] = nil
end

describe("commands.register_commands: :SageFsTypeExplorer", function()
  local registered, plugin, notifications, http_calls, selects, floats
  local prev_create_user_command, prev_create_augroup, prev_create_autocmd, prev_ui

  local function explore_system_io()
    registered["SageFsTypeExplorer"].handler({})
    -- the first picker is the root list; pick "System.IO"
    local root = selects[1]
    for _, label in ipairs(root.items) do
      if label == "System.IO" then root.on_choice(label) return end
    end
    error("System.IO is not among the roots")
  end

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
    selects = {}
    vim.ui = {
      select = function(items, opts, on_choice)
        table.insert(selects, { items = items, prompt = opts and opts.prompt, on_choice = on_choice })
      end,
      input = function() end,
    }
    http_calls = {}
    package.loaded["sagefs.transport"] = { http_json = function(opts) table.insert(http_calls, opts) end }
    floats = {}
    local real_render = require("sagefs.render")
    package.loaded["sagefs.render"] = setmetatable({
      show_float = function(lines, opts) table.insert(floats, { lines = lines, opts = opts }) end,
    }, { __index = real_render })
    local commands = require("sagefs.commands")
    notifications = {}
    plugin = { active_session = { id = "abc12345" } }
    local helpers = {
      base_url = function() return "http://localhost:37749" end,
      dashboard_url = function() return "http://localhost:37750" end,
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

  it("asks the JSON completions route, not the dashboard's SSE one, with a limit and the session", function()
    explore_system_io()
    assert.are.equal(1, #http_calls)
    assert.are.equal("POST", http_calls[1].method)
    assert.are.equal("http://localhost:37749/api/completions", http_calls[1].url)
    assert.are.equal("System.IO.", http_calls[1].body.code)
    assert.are.equal(#"System.IO.", http_calls[1].body.cursor_position)
    assert.are.equal("abc12345", http_calls[1].body.sessionId)
    assert.are.equal(200, http_calls[1].body.limit)
  end)

  it("lists the members and a Showing N of M row when the daemon cut the set", function()
    explore_system_io()
    http_calls[1].callback(true, vim.json.encode({
      completions = { { label = "File", kind = "Class", insertText = "File" },
                      { label = "Path", kind = "Class", insertText = "Path" } },
      count = 2, total = 64, totalKind = "exact",
    }))
    local picker = selects[2]
    assert.are.equal(3, #picker.items)
    assert.truthy(picker.items[3]:find("Showing 2 of 64", 1, true))
  end)

  it("choosing the Showing row does nothing", function()
    explore_system_io()
    http_calls[1].callback(true, vim.json.encode({
      completions = { { label = "File", kind = "Class", insertText = "File" } },
      count = 1, total = 64, totalKind = "exact",
    }))
    local picker = selects[2]
    picker.on_choice(picker.items[#picker.items])
    assert.are.equal(1, #http_calls)
    assert.are.equal(0, #floats)
    assert.are.equal(2, #selects)
  end)

  it("shows the member panel's size line for a leaf picked from a cut set", function()
    explore_system_io()
    http_calls[1].callback(true, vim.json.encode({
      completions = { { label = "Combine", kind = "Method", insertText = "Combine" } },
      count = 1, total = 9, totalKind = "atLeast",
    }))
    local picker = selects[2]
    picker.on_choice(picker.items[1])
    assert.are.equal(1, #floats)
    assert.truthy(table.concat(floats[1].lines, "\n"):find("Showing 1 of at least 9", 1, true))
  end)

  it("warns with the daemon's reason and opens no picker when it could not list", function()
    explore_system_io()
    http_calls[1].callback(true, vim.json.encode({
      completions = {}, count = 0,
      unavailable = "SessionNotActive", reason = "the session is not active",
    }))
    assert.are.equal(1, #selects)
    local last = notifications[#notifications]
    assert.are.equal(vim.log.levels.WARN, last.level)
    assert.truthy(last.msg:find("the session is not active", 1, true))
    assert.is_nil(last.msg:find("No members", 1, true))
  end)

  it("a name asked twice is answered from the cache and still says it was cut", function()
    explore_system_io()
    http_calls[1].callback(true, vim.json.encode({
      completions = { { label = "File", kind = "Class", insertText = "File" } },
      count = 1, total = 64, totalKind = "exact",
    }))
    registered["SageFsTypeExplorer"].handler({})
    selects[3].on_choice("System.IO")
    assert.are.equal(1, #http_calls)
    assert.truthy(selects[4].items[#selects[4].items]:find("Showing 1 of 64", 1, true))
  end)

  it("does not cache an unavailable answer, so asking again asks the daemon again", function()
    explore_system_io()
    http_calls[1].callback(true, vim.json.encode({
      completions = {}, unavailable = "SessionNotActive", reason = "warming up",
    }))
    registered["SageFsTypeExplorer"].handler({})
    local root = selects[2]
    root.on_choice("System.IO")
    assert.are.equal(2, #http_calls)
  end)

  it("says No members found for an empty list that the daemon vouches for", function()
    explore_system_io()
    http_calls[1].callback(true, vim.json.encode({
      completions = {}, count = 0, total = 0, totalKind = "exact",
    }))
    assert.truthy(notifications[#notifications].msg:find("No members found", 1, true))
  end)

  it("renders an older daemon's reply, with no total, as before", function()
    explore_system_io()
    http_calls[1].callback(true, vim.json.encode({
      completions = { { label = "File", kind = "Class", insertText = "File" } },
      count = 1,
    }))
    assert.are.equal(1, #selects[2].items)
  end)
end)
