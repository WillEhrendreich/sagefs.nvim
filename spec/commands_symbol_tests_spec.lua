-- Tests: :SageFsSymbolTests and the retired :SageFsCallers / :SageFsCallees.
--
-- :SageFsCallers and :SageFsCallees asked the DASHBOARD port for /api/callers and /api/callees.
-- The daemon maps neither route, and its only symbol graph (GET /api/dependency-graph on the MCP
-- port) holds symbol -> covering tests, with no call edges. So the two commands could never have
-- worked and nothing honest could replace them. :SageFsSymbolTests asks the route that exists.
-- Same stubbing as commands_type_explorer_spec: no daemon, no Neovim.
require("spec.helper")

local function unload()
  package.loaded["sagefs.commands"] = nil
  package.loaded["sagefs.transport"] = nil
  package.loaded["sagefs.render"] = nil
  package.loaded["sagefs.symbol_tests"] = nil
end

local MCP = "http://localhost:37749"
local DASH = "http://localhost:37750"

describe("commands.register_commands: :SageFsSymbolTests", function()
  local registered, notifications, http_calls, floats
  local prev_create_user_command, prev_create_augroup, prev_create_autocmd

  local function run(arg)
    registered["SageFsSymbolTests"].handler({ args = arg })
  end

  local OVERVIEW = vim.json.encode({
    Symbols = { { Symbol = "Mod.add", TestCount = 2 }, { Symbol = "Mod.addAll", TestCount = 1 } },
    TotalSymbols = 2,
  })

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
    http_calls = {}
    package.loaded["sagefs.transport"] = { http_json = function(opts) table.insert(http_calls, opts) end }
    floats = {}
    local real_render = require("sagefs.render")
    package.loaded["sagefs.render"] = setmetatable({
      show_float = function(lines, opts) table.insert(floats, { lines = lines, opts = opts }) end,
    }, { __index = real_render })
    local commands = require("sagefs.commands")
    notifications = {}
    local plugin = { active_session = { id = "abc12345" } }
    commands.register_commands(plugin, {
      base_url = function() return MCP end,
      dashboard_url = function() return DASH end,
      notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end,
    })
  end)

  after_each(function()
    vim.api.nvim_create_user_command = prev_create_user_command
    vim.api.nvim_create_augroup = prev_create_augroup
    vim.api.nvim_create_autocmd = prev_create_autocmd
    unload()
  end)

  describe("the retired commands", function()
    it("no longer registers :SageFsCallers or :SageFsCallees, which asked for routes the daemon does not have", function()
      assert.is_nil(registered["SageFsCallers"])
      assert.is_nil(registered["SageFsCallees"])
    end)
  end)

  describe("the request", function()
    it("is registered and takes one argument", function()
      assert.is_not_nil(registered["SageFsSymbolTests"])
      assert.equals(1, registered["SageFsSymbolTests"].opts.nargs)
    end)

    it("asks the MCP port for the symbol overview, never the dashboard port", function()
      run("Mod.add")
      assert.equals(1, #http_calls)
      assert.equals("GET", http_calls[1].method)
      assert.equals(MCP .. "/api/dependency-graph?session=abc12345", http_calls[1].url)
    end)

    it("explains usage when given no symbol", function()
      run("")
      assert.equals(0, #http_calls)
      assert.is_truthy(notifications[1].msg:find("Usage: :SageFsSymbolTests", 1, true))
    end)

    it("asks for the named symbol's tests once the overview says the symbol is tracked", function()
      run("Mod.add")
      http_calls[1].callback(true, OVERVIEW, { status = 200 })
      assert.equals(2, #http_calls)
      assert.equals(MCP .. "/api/dependency-graph?symbol=Mod.add&session=abc12345", http_calls[2].url)
    end)
  end)

  describe("what the person sees", function()
    it("shows the tests covering the symbol in a float", function()
      run("Mod.add")
      http_calls[1].callback(true, OVERVIEW, { status = 200 })
      http_calls[2].callback(true, vim.json.encode({
        Symbol = "Mod.add",
        Tests = { { TestId = "t1", TestName = "adds two", Status = "passed" } },
        TotalSymbols = 2,
      }), { status = 200 })
      assert.equals(1, #floats)
      local text = table.concat(floats[1].lines, "\n")
      assert.is_truthy(text:find("Mod.add", 1, true))
      assert.is_truthy(text:find("adds two", 1, true))
    end)

    it("says a symbol is not in the graph, and does not request tests for it", function()
      run("Nope.nothing")
      http_calls[1].callback(true, OVERVIEW, { status = 200 })
      assert.equals(1, #http_calls)
      assert.equals(0, #floats)
      assert.is_truthy(notifications[1].msg:find("not in the graph", 1, true))
    end)

    it("lists near names when the query is part of a tracked name", function()
      run("addAl")
      http_calls[1].callback(true, OVERVIEW, { status = 200 })
      assert.equals(1, #http_calls)
      assert.is_truthy(notifications[1].msg:find("Mod.addAll", 1, true))
    end)

    it("says the graph is empty when the daemon tracks no symbols yet", function()
      run("Mod.add")
      http_calls[1].callback(true, '{"Symbols":[],"TotalSymbols":0}', { status = 200 })
      assert.is_truthy(notifications[1].msg:find("no test dependency graph", 1, true))
    end)
  end)

  describe("failures", function()
    it("names an unreachable daemon and the cause", function()
      run("Mod.add")
      http_calls[1].callback(false, "connect: ECONNREFUSED", nil)
      assert.equals(vim.log.levels.ERROR, notifications[1].level)
      assert.is_truthy(notifications[1].msg:find("Could not reach the SageFs daemon", 1, true))
      assert.is_truthy(notifications[1].msg:find("ECONNREFUSED", 1, true))
    end)

    it("names a non-200 with its status and message", function()
      run("Mod.add")
      http_calls[1].callback(false, '{"error":"Elm model not available"}', { status = 503 })
      assert.is_truthy(notifications[1].msg:find("503", 1, true))
      assert.is_truthy(notifications[1].msg:find("Elm model not available", 1, true))
    end)

    it("names a malformed body", function()
      run("Mod.add")
      http_calls[1].callback(true, "<html>", { status = 200 })
      assert.is_truthy(notifications[1].msg:find("not JSON", 1, true))
    end)

    it("names a failure on the second request too", function()
      run("Mod.add")
      http_calls[1].callback(true, OVERVIEW, { status = 200 })
      http_calls[2].callback(false, "timeout", nil)
      assert.equals(0, #floats)
      assert.is_truthy(notifications[1].msg:find("timeout", 1, true))
    end)
  end)
end)

-- The route answers about one session, so the command names the session it is bound to and
-- says plainly what an empty or refused answer means. Same stubs as above; the plugin table is
-- the only thing that changes.
describe("commands.register_commands: :SageFsSymbolTests and the session", function()
  local registered, notifications, http_calls, floats
  local prev_create_user_command, prev_create_augroup, prev_create_autocmd

  local function setup(active_session)
    package.loaded["sagefs.commands"] = nil
    package.loaded["sagefs.transport"] = nil
    package.loaded["sagefs.render"] = nil
    package.loaded["sagefs.symbol_tests"] = nil
    registered = {}
    vim.api.nvim_create_user_command = function(name, handler, opts)
      registered[name] = { handler = handler, opts = opts }
    end
    http_calls = {}
    package.loaded["sagefs.transport"] = { http_json = function(opts) table.insert(http_calls, opts) end }
    floats = {}
    local real_render = require("sagefs.render")
    package.loaded["sagefs.render"] = setmetatable({
      show_float = function(lines, opts) table.insert(floats, { lines = lines, opts = opts }) end,
    }, { __index = real_render })
    notifications = {}
    require("sagefs.commands").register_commands({ active_session = active_session }, {
      base_url = function() return MCP end,
      dashboard_url = function() return DASH end,
      notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end,
    })
  end

  local function run(arg) registered["SageFsSymbolTests"].handler({ args = arg }) end

  before_each(function()
    prev_create_user_command = vim.api.nvim_create_user_command
    prev_create_augroup, prev_create_autocmd = vim.api.nvim_create_augroup, vim.api.nvim_create_autocmd
    vim.api.nvim_create_augroup = function() return 1 end
    vim.api.nvim_create_autocmd = function() end
  end)

  after_each(function()
    vim.api.nvim_create_user_command = prev_create_user_command
    vim.api.nvim_create_augroup = prev_create_augroup
    vim.api.nvim_create_autocmd = prev_create_autocmd
    package.loaded["sagefs.commands"] = nil
    package.loaded["sagefs.transport"] = nil
    package.loaded["sagefs.render"] = nil
    package.loaded["sagefs.symbol_tests"] = nil
  end)

  describe("the request", function()
    it("carries the bound session on the overview request", function()
      setup({ id = "abc12345" })
      run("Mod.add")
      assert.equals(MCP .. "/api/dependency-graph?session=abc12345", http_calls[1].url)
    end)

    it("carries the symbol and the bound session on the detail request", function()
      setup({ id = "abc12345" })
      run("Mod.add")
      http_calls[1].callback(true, vim.json.encode({
        Session = "abc12345", State = "mapped",
        Symbols = { { Symbol = "Mod.add", TestCount = 1 } }, TotalSymbols = 1,
      }), { status = 200 })
      assert.equals(MCP .. "/api/dependency-graph?symbol=Mod.add&session=abc12345", http_calls[2].url)
    end)

    it("names no session when the plugin is bound to none", function()
      setup(nil)
      run("Mod.add")
      assert.equals(MCP .. "/api/dependency-graph", http_calls[1].url)
    end)
  end)

  describe("what the person sees", function()
    it("tells the person to pick a session when more than one exists and the plugin is bound to none", function()
      setup(nil)
      run("Mod.add")
      http_calls[1].callback(false, vim.json.encode({
        success = false,
        error = "Multiple sessions active. Specify sessionId:\ns1\ns2",
        errorDetails = { case = "AmbiguousSessions", fields = { sessionDescriptions = { "s1", "s2" } },
          message = "Multiple sessions active", suggestedAction = "Specify a sessionId explicitly" },
      }), { status = 400 })
      assert.equals(0, #floats)
      assert.equals(vim.log.levels.WARN, notifications[1].level)
      assert.is_truthy(notifications[1].msg:find(":SageFsSessions", 1, true))
    end)

    local EMPTY_BY_STATE = {
      nothing_analysed = "analysed",
      no_coverage_recorded = "no test has recorded coverage",
      coverage_of_another_build = "another build",
      nothing_reached = "compiled run",
    }
    for state, word in pairs(EMPTY_BY_STATE) do
      it("says " .. state .. " in its own words when the map is empty", function()
        setup({ id = "abc12345" })
        run("Mod.add")
        http_calls[1].callback(true, vim.json.encode({
          Session = "abc12345", State = state, Symbols = {}, TotalSymbols = 0,
        }), { status = 200 })
        assert.equals(1, #http_calls)
        assert.equals(0, #floats)
        assert.is_truthy(notifications[1].msg:find(word, 1, true), notifications[1].msg)
        assert.is_nil(notifications[1].msg:find("no test dependency graph", 1, true))
      end)
    end

    it("renders a mapped reply as before, with the session named", function()
      setup({ id = "abc12345" })
      run("Mod.add")
      http_calls[1].callback(true, vim.json.encode({
        Session = "abc12345", State = "mapped",
        Symbols = { { Symbol = "Mod.add", TestCount = 1 } }, TotalSymbols = 1,
      }), { status = 200 })
      http_calls[2].callback(true, vim.json.encode({
        Session = "abc12345", State = "mapped", Symbol = "Mod.add",
        Tests = { { TestId = "t1", TestName = "adds two", Status = "passed" } }, TotalSymbols = 1,
      }), { status = 200 })
      local text = table.concat(floats[1].lines, "\n")
      assert.is_truthy(text:find("adds two", 1, true))
      assert.is_truthy(text:find("1 test: 1 passed", 1, true))
    end)

    it("renders a reply from an older daemon, with no Session and no State, as before", function()
      setup({ id = "abc12345" })
      run("Mod.add")
      http_calls[1].callback(true, vim.json.encode({
        Symbols = { { Symbol = "Mod.add", TestCount = 1 } }, TotalSymbols = 1,
      }), { status = 200 })
      http_calls[2].callback(true, vim.json.encode({
        Symbol = "Mod.add", Tests = { { TestId = "t1", TestName = "adds two", Status = "passed" } }, TotalSymbols = 1,
      }), { status = 200 })
      assert.is_truthy(table.concat(floats[1].lines, "\n"):find("adds two", 1, true))
    end)

    it("keeps the old empty-graph sentence for an older daemon that sends no State", function()
      setup({ id = "abc12345" })
      run("Mod.add")
      http_calls[1].callback(true, '{"Symbols":[],"TotalSymbols":0}', { status = 200 })
      assert.is_truthy(notifications[1].msg:find("no test dependency graph", 1, true))
    end)
  end)
end)
