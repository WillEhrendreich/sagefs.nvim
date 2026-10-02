require("spec.helper")
local help = require("sagefs.help")

-- :SageFsHelp is generated from the registered command table, so it cannot
-- drift from what exists (a lemming found the plugin's commands by typing
-- :Sage<Tab>, with no help to read). The first-run hint names the three most
-- useful commands, only if they are registered.

-- nvim_get_commands() gives `desc` for a command registered with one (and
-- `definition` for a plain-text command): the help reads either.
local function cmds(t)
  local out = {}
  for name, desc in pairs(t) do out[name] = { name = name, desc = desc, definition = "" } end
  return out
end

describe("sagefs.help.command_rows", function()
  it("keeps only SageFs commands, sorted by name", function()
    local rows = help.command_rows(cmds({
      SageFsStatus = "Status", SageFsEval = "Eval", Other = "no", Sage = "no", SageFsAbc = "Abc",
    }))
    local names = {}
    for _, r in ipairs(rows) do names[#names + 1] = r.name end
    assert.are.same({ "SageFsAbc", "SageFsEval", "SageFsStatus" }, names)
  end)

  it("uses the command's own description", function()
    local rows = help.command_rows(cmds({ SageFsEval = "Evaluate current cell" }))
    assert.are.equal("Evaluate current cell", rows[1].desc)
  end)

  it("flags a command that has no description instead of printing a Lua function address", function()
    local rows = help.command_rows(cmds({ SageFsOops = "<Lua function>", SageFsBlank = "" }))
    for _, r in ipairs(rows) do
      assert.are.equal("(no description)", r.desc)
      assert.is_true(r.undescribed)
    end
  end)
end)

describe("sagefs.help.command_rows (definition-only commands)", function()
  it("falls back to the definition when there is no desc", function()
    local rows = help.command_rows({ SageFsPlain = { name = "SageFsPlain", definition = "echo 'hi'" } })
    assert.are.equal("echo 'hi'", rows[1].desc)
  end)
end)

describe("sagefs.help.lines", function()
  it("lists every registered command with its description (cannot drift)", function()
    -- generated command tables of varying shape
    for n = 1, 40 do
      local t = {}
      for i = 1, n do t["SageFsCmd" .. i] = "does thing " .. i end
      local lines = help.lines(help.command_rows(cmds(t)), {})
      local text = table.concat(lines, "\n")
      for i = 1, n do
        assert.is_truthy(text:find(":SageFsCmd" .. i .. " ", 1, true), "missing SageFsCmd" .. i)
        assert.is_truthy(text:find("does thing " .. i, 1, true))
      end
    end
  end)

  it("aligns descriptions in a column", function()
    local lines = help.lines(help.command_rows(cmds({ SageFsA = "first", SageFsLonger = "second" })), {})
    local col
    for _, l in ipairs(lines) do
      local c = l:find("first", 1, true) or l:find("second", 1, true)
      if c then
        col = col or c
        assert.are.equal(col, c)
      end
    end
    assert.is_truthy(col)
  end)

  it("says how many commands there are and how to find them by hand", function()
    local lines = help.lines(help.command_rows(cmds({ SageFsA = "a", SageFsB = "b" })), {})
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("2 commands", 1, true))
    assert.is_truthy(text:find(":Sage<Tab>", 1, true))
  end)

  it("adds the keymaps registered on this buffer, taken from their own descriptions", function()
    local lines = help.lines({}, {
      { lhs = "<M-CR>", desc = "SageFs: Evaluate cell" },
      { lhs = "<leader>rE", desc = "SageFs: Expand result" },
    })
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("<M-CR>", 1, true))
    assert.is_truthy(text:find("Evaluate cell", 1, true))
    assert.is_truthy(text:find("<leader>rE", 1, true))
  end)
end)

describe("sagefs.help.keymap_rows", function()
  it("keeps keymaps whose description starts with SageFs: and strips that prefix", function()
    local rows = help.keymap_rows({
      { lhs = "<M-CR>", desc = "SageFs: Evaluate cell" },
      { lhs = "gd", desc = "LSP definition" },
      { lhs = "x" },
    })
    assert.are.equal(1, #rows)
    assert.are.equal("Evaluate cell", rows[1].desc)
  end)
end)

describe("sagefs.help.hint_lines", function()
  local all = help.command_rows(cmds({
    SageFsEval = "Evaluate current cell", SageFsSessions = "Manage SageFs sessions", SageFsHelp = "List commands",
    SageFsStatus = "Status",
  }))

  it("names at most three commands", function()
    local text = table.concat(help.hint_lines(all), "\n")
    local count = 0
    for _ in text:gmatch(":SageFs%w+") do count = count + 1 end
    assert.is_true(count <= 3, text)
    assert.is_truthy(text:find(":SageFsHelp", 1, true))
  end)

  it("makes :Sage<Tab> completion obvious", function()
    assert.is_truthy(table.concat(help.hint_lines(all), "\n"):find(":Sage<Tab>", 1, true))
  end)

  it("never names a command that is not registered", function()
    local rows = help.command_rows(cmds({ SageFsHelp = "List commands" }))
    local text = table.concat(help.hint_lines(rows), "\n")
    assert.is_falsy(text:find(":SageFsSessions", 1, true))
    assert.is_falsy(text:find(":SageFsEval", 1, true))
  end)

  it("says how to dismiss itself and that it will not come back", function()
    local text = table.concat(help.hint_lines(all), "\n")
    assert.is_truthy(text:find("dismiss", 1, true))
  end)
end)
