require("spec.helper")

local function unload_commands()
  package.loaded["sagefs.commands"] = nil
end

describe("commands.register_simple_commands", function()
  local commands
  local registered
  local plugin
  local helpers
  local calls

  before_each(function()
    unload_commands()

    commands = require("sagefs.commands")
    registered = {}
    calls = {}

    plugin = {
      eval_cell = function() table.insert(calls, "eval_cell") end,
      eval_cell_and_advance = function() table.insert(calls, "eval_cell_and_advance") end,
      eval_file = function() table.insert(calls, "eval_file") end,
      eval_current_line = function() table.insert(calls, "eval_current_line") end,
      session_picker = function() table.insert(calls, "session_picker") end,
      discover_and_create = function() table.insert(calls, "discover_and_create") end,
      configure_warmup_auto_open = function() table.insert(calls, "configure_warmup_auto_open") end,
      reset_session = function() table.insert(calls, "reset_session") end,
      show_session_context = function() table.insert(calls, "show_session_context") end,
    }

    helpers = {
      clear_and_render = function() table.insert(calls, "clear_and_render") end,
      stop_sse = function() table.insert(calls, "stop_sse") end,
      notify = function(msg) table.insert(calls, "notify:" .. msg) end,
    }
  end)

  after_each(function()
    unload_commands()
  end)

  it("registers the simple delegate command surface with working handlers", function()
    commands.register_simple_commands(plugin, helpers, function(name, handler, opts)
      registered[name] = {
        handler = handler,
        opts = opts,
      }
    end)

    local expected = {
      { name = "SageFsEval", desc = "Evaluate current cell" },
      { name = "SageFsEvalAdvance", desc = "Evaluate current cell and move to next" },
      { name = "SageFsEvalFile", desc = "Evaluate entire file" },
      { name = "SageFsEvalLine", desc = "Evaluate current line only" },
      { name = "SageFsClear", desc = "Clear all cell results" },
      { name = "SageFsDisconnect", desc = "Disconnect from SageFs" },
      { name = "SageFsSessions", desc = "Manage SageFs sessions" },
      { name = "SageFsCreateSession", desc = "Create new SageFs session" },
      { name = "SageFsConfig", desc = "Create or open .SageFs/config.fsx for warmup auto-open" },
      { name = "SageFsReset", desc = "Reset active FSI session" },
      { name = "SageFsContext", desc = "Show session context (assemblies, namespaces, warmup)" },
    }

    for _, command in ipairs(expected) do
      assert.is_not_nil(registered[command.name], "missing command: " .. command.name)
      assert.same({ desc = command.desc }, registered[command.name].opts)
      registered[command.name].handler()
    end

    assert.same({
      "eval_cell",
      "eval_cell_and_advance",
      "eval_file",
      "eval_current_line",
      "clear_and_render",
      "stop_sse",
      "notify:Disconnected",
      "session_picker",
      "discover_and_create",
      "configure_warmup_auto_open",
      "reset_session",
      "show_session_context",
    }, calls)
  end)
end)
