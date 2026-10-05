-- Tests: the pure side of nudging a value from the editor (sagefs.nudge).
--
-- The daemon's nudge_value tool (SageFs/McpNudge.fs) lists the values of a file
-- (inspect), then writes one back (set, with the hash inspect gave), and steps
-- through what it wrote (undo, redo). The reply is one JSON object with an
-- `outcome` token. Everything the plugin decides without touching the editor is
-- here: the request, the reply, which value the cursor means, what a bump of a
-- literal comes to, and the words for the notice.
require("spec.helper")

local nudge = require("sagefs.nudge")

local function item(address, text, kind, value_kind)
  return {
    address = address, text = text, hash = ("h:" .. address), kind = kind or "Knob", valueKind = value_kind,
  }
end

-- The shape McpNudge.render gives, from the daemon's own field names.
local function inspect_reply(items, extra)
  local reply = {
    outcome = "Inspected", file = "/w/Game.fs", fileHash = "fh", journaled = 0, undoSteps = 2, redoSteps = 1,
    listing = "Complete", items = items, notes = {},
  }
  for k, v in pairs(extra or {}) do reply[k] = v end
  return vim.json.encode(reply)
end

describe("nudge.build_args", function()
  it("names the tool's own parameters and leaves out what is empty", function()
    local args = nudge.build_args({ action = "set", file = "/w/Game.fs", address = "M.x", seen = "abc", literal = "13.5", working_directory = "/w" })
    assert.are.same({ action = "set", file = "/w/Game.fs", address = "M.x", seen = "abc", literal = "13.5", working_directory = "/w" }, args)
    local inspect = nudge.build_args({ action = "inspect", file = "/w/Game.fs", working_directory = "/w", address = "", literal = nil })
    assert.are.same({ action = "inspect", file = "/w/Game.fs", working_directory = "/w" }, inspect)
  end)

  it("sends an expression under its own name, never inside literal", function()
    local args = nudge.build_args({ action = "set", file = "f", address = "a", seen = "s", expression = "gravity * 2.0" })
    assert.are.equal("gravity * 2.0", args.expression)
    assert.is_nil(args.literal)
  end)
end)

describe("nudge.parse_reply", function()
  it("reads an inspect reply into items, history and listing", function()
    local reply = nudge.parse_reply(true, inspect_reply({
      item("Game.Tuning.tuning/{JumpVelocity}", "12.5", "Knob", "Real"),
      item("Game.Tuning.tuning/{Gravity}", "g * 2.0", "Formula"),
    }))
    assert.are.equal("Inspected", reply.outcome)
    assert.are.equal(2, #reply.items)
    assert.are.equal("Game.Tuning.tuning/{JumpVelocity}", reply.items[1].address)
    assert.are.equal("Real", reply.items[1].valueKind)
    assert.are.equal(2, reply.undoSteps)
    assert.are.equal(1, reply.redoSteps)
    assert.are.equal("Complete", reply.listing)
  end)

  it("reads a Written receipt", function()
    local reply = nudge.parse_reply(true, vim.json.encode({
      outcome = "Written", file = "/w/Game.fs", address = "M.x", before = "12.5", after = "13.5", hashAfter = "h2",
      fileHashBefore = "a", fileHashAfter = "b", eventId = 4, notes = { "FileNotWatched" },
    }))
    assert.are.equal("Written", reply.outcome)
    assert.are.equal("12.5", reply.before)
    assert.are.equal("13.5", reply.after)
    assert.are.same({ "FileNotWatched" }, reply.notes)
  end)

  it("reads a refusal with its token, rule and next action", function()
    local reply = nudge.parse_reply(true, vim.json.encode({
      outcome = "Refused", refusal = "SourceMoved", rule = "The expression changed since you inspected it.",
      nextAction = "Run action=inspect again.",
    }))
    assert.are.equal("Refused", reply.outcome)
    assert.are.equal("SourceMoved", reply.refusal)
    assert.are.equal("Run action=inspect again.", reply.nextAction)
  end)

  it("a call the daemon failed is its own words, never an error raised here", function()
    local reply = nudge.parse_reply(false, "Role 'Observer' may not call nudge_value.")
    assert.are.equal("Failed", reply.outcome)
    assert.is_truthy(reply.message:find("Observer", 1, true))
  end)

  it("a body that is not the daemon's JSON (an older daemon) says so and shows what came back", function()
    local reply = nudge.parse_reply(true, "Unknown tool: nudge_value")
    assert.are.equal("Failed", reply.outcome)
    assert.is_truthy(reply.message:find("Unknown tool", 1, true))
    assert.is_truthy(reply.message:find("older", 1, true), "it says the daemon may be older than the plugin")
  end)

  it("a JSON object with no outcome is not mistaken for a reply", function()
    local reply = nudge.parse_reply(true, '{"hello":1}')
    assert.are.equal("Failed", reply.outcome)
  end)

  -- The daemon's event echo is its own content block and the client hands over
  -- only the first block (mcp_client.tool_text), so the reply is JSON on its own.
  -- Nothing here cuts a reply out of text any more.
  it("reads a reply whose text carries braces and quotes", function()
    local body = '{"outcome":"Unchanged","address":"M.x","text":"} { \\" \\\\","notes":[]}'
    local reply = nudge.parse_reply(true, body)
    assert.are.equal("Unchanged", reply.outcome)
    assert.are.equal('} { " \\', reply.text)
  end)

  it("an object that never closes is not a reply", function()
    local reply = nudge.parse_reply(true, '{"outcome":"Written","address":"M.x"')
    assert.are.equal("Failed", reply.outcome)
  end)
end)

describe("nudge.describe", function()
  it("a write shows the address and the old and new text", function()
    local text, level = nudge.describe({ outcome = "Written", address = "Game.Tuning.tuning/{JumpVelocity}", before = "12.5", after = "13.5", notes = {} })
    assert.is_truthy(text:find("Game.Tuning.tuning/{JumpVelocity}", 1, true))
    assert.is_truthy(text:find("12.5", 1, true))
    assert.is_truthy(text:find("13.5", 1, true))
    assert.are.equal(vim.log.levels.INFO, level)
  end)

  it("a refusal shows the token, the rule and the next action, as a warning", function()
    local text, level = nudge.describe({
      outcome = "Refused", refusal = "AddressMoved", rule = "x moved to y.", nextAction = "Send it again with y.",
    })
    assert.is_truthy(text:find("AddressMoved", 1, true))
    assert.is_truthy(text:find("x moved to y.", 1, true))
    assert.is_truthy(text:find("Send it again with y.", 1, true))
    assert.are.equal(vim.log.levels.WARN, level)
  end)

  it("undo and redo say which they were", function()
    local undone = nudge.describe({ outcome = "Undone", address = "M.x", before = "13.5", after = "12.5", notes = {} })
    local redone = nudge.describe({ outcome = "Redone", address = "M.x", before = "12.5", after = "13.5", notes = {} })
    assert.is_truthy(undone:lower():find("undone", 1, true))
    assert.is_truthy(redone:lower():find("redone", 1, true))
  end)

  it("an unchanged value says nothing was written", function()
    local text = nudge.describe({ outcome = "Unchanged", address = "M.x", text = "12.5", notes = {} })
    assert.is_truthy(text:find("nothing was written", 1, true))
  end)

  it("every note the daemon can add is said in words, and an unknown one is shown as it came", function()
    for _, token in ipairs({ "TornJournalTailRemoved", "UnlandedWriteMarkedUndone", "ExpressionNotTypeChecked", "FileNotWatched" }) do
      local text = nudge.describe({ outcome = "Written", address = "M.x", before = "1", after = "2", notes = { token } })
      assert.is_falsy(text:find(token, 1, true), token .. " is turned into a sentence")
    end
    local text = nudge.describe({ outcome = "Written", address = "M.x", before = "1", after = "2", notes = { "SomethingNew" } })
    assert.is_truthy(text:find("SomethingNew", 1, true))
  end)

  it("a failure is an error and carries the daemon's words", function()
    local text, level = nudge.describe({ outcome = "Failed", message = "no route" })
    assert.is_truthy(text:find("no route", 1, true))
    assert.are.equal(vim.log.levels.ERROR, level)
  end)
end)

describe("nudge.read_literal", function()
  it("reads the kinds a bump works on", function()
    assert.are.same({ kind = "int", value = 150, base = "dec", unit = "" }, nudge.read_literal("150"))
    assert.are.same({ kind = "int", value = -3, base = "dec", unit = "" }, nudge.read_literal("-3"))
    assert.are.same({ kind = "real", value = 12.5, decimals = 1, unit = "" }, nudge.read_literal("12.5"))
    assert.are.same({ kind = "real", value = 1, decimals = 1, unit = "" }, nudge.read_literal("1.0"))
    assert.are.same({ kind = "bool", value = true }, nudge.read_literal("true"))
    assert.are.same({ kind = "bool", value = false }, nudge.read_literal("false"))
  end)

  it("keeps hex as a number in its own base, and a unit of measure aside", function()
    local hex = nudge.read_literal("0x1F")
    assert.are.equal("int", hex.kind)
    assert.are.equal(31, hex.value)
    assert.are.equal("hex", hex.base)
    local measure = nudge.read_literal("12.5<m/s>")
    assert.are.equal("real", measure.kind)
    assert.are.equal(12.5, measure.value)
    assert.are.equal("<m/s>", measure.unit)
    assert.are.equal(1024, nudge.read_literal("1_024").value)
  end)

  it("anything else is not a number to bump", function()
    for _, text in ipairs({ "Hard", '"hi"', "'c'", "1e3", "gravity * 2.0", "", "0x", "1.2.3" }) do
      assert.are.equal("other", nudge.read_literal(text).kind, text)
    end
  end)
end)

describe("nudge.bump", function()
  local function bump(text, dir, count, step)
    return nudge.bump({ text = text }, dir, count, step)
  end

  it("an integer goes up and down by one, by a count, and by a step", function()
    assert.are.equal("151", bump("150", 1))
    assert.are.equal("149", bump("150", -1))
    assert.are.equal("155", bump("150", 1, 5))
    assert.are.equal("170", bump("150", 1, 2, "10"))
    assert.are.equal("-1", bump("0", -1))
  end)

  it("a real moves by the last decimal place it already has, with no drift", function()
    assert.are.equal("12.6", bump("12.5", 1))
    assert.are.equal("0.3", bump("0.2", 1))
    assert.are.equal("0.3", bump("0.4", -1))
    assert.are.equal("1.01", bump("1.00", 1))
    assert.are.equal("0.1", bump("0.0", 1))
    assert.are.equal("0.0", bump("0.1", -1))
    assert.are.equal("12.6", bump("12.1", 5))
  end)

  it("a step with more decimals than the literal widens it", function()
    assert.are.equal("12.75", bump("12.5", 1, 1, "0.25"))
    assert.are.equal("13.0", bump("12.5", 1, 1, "0.5"))
  end)

  it("a unit of measure is left to the daemon, which keeps it", function()
    assert.are.equal("12.6", bump("12.5<m/s>", 1))
  end)

  it("a bool toggles, whatever the direction or count", function()
    assert.are.equal("false", bump("true", 1))
    assert.are.equal("true", bump("false", -1, 7))
  end)

  it("hex and the other bases are bumped as the number they are, written in decimal for the daemon", function()
    assert.are.equal("32", bump("0x1F", 1))
  end)

  it("says why, in words, when the value is not a number", function()
    local text, why = bump("Hard", 1)
    assert.is_nil(text)
    assert.is_truthy(why:find(":SageFsNudge set", 1, true))
    local bad_text, bad_why = bump("12.5", 1, 1, "abc")
    assert.is_nil(bad_text)
    assert.is_truthy(bad_why:find("step", 1, true))
    local whole, whole_why = bump("150", 1, 1, "0.5")
    assert.is_nil(whole)
    assert.is_truthy(whole_why:find("whole", 1, true))
  end)
end)

describe("nudge.locate", function()
  local lines = {
    "module Game.Tuning",            -- 1
    "",                              -- 2
    "type Tuning = { JumpVelocity: float; Gravity: float; Cap: int }", -- 3
    "",                              -- 4
    "let tuning =",                  -- 5
    "  { JumpVelocity = 12.5",       -- 6
    "    Gravity = 9.8",             -- 7
    "    Cap = 12 }",                -- 8
    "",                              -- 9
    "let other =",                   -- 10
    "  { JumpVelocity = 12.5",       -- 11
    "    Gravity = 3.0",             -- 12
    "    Cap = 9 }",                 -- 13
    "",                              -- 14
    "let speed = 1.0",               -- 15
    "let drag = 1.0",                -- 16
    "let pair = { Lo = 2.0; Hi = 2.0 }", -- 17
    "let fn x = x * 1.0",            -- 18
  }
  local items = {
    item("Game.Tuning.tuning/{JumpVelocity}", "12.5", "Knob", "Real"),
    item("Game.Tuning.tuning/{Gravity}", "9.8", "Knob", "Real"),
    item("Game.Tuning.tuning/{Cap}", "12", "Knob", "Integer"),
    item("Game.Tuning.other/{JumpVelocity}", "12.5", "Knob", "Real"),
    item("Game.Tuning.other/{Gravity}", "3.0", "Knob", "Real"),
    item("Game.Tuning.other/{Cap}", "9", "Knob", "Integer"),
    item("Game.Tuning.speed", "1.0", "Knob", "Real"),
    item("Game.Tuning.drag", "1.0", "Knob", "Real"),
    item("Game.Tuning.pair/{Lo}", "2.0", "Knob", "Real"),
    item("Game.Tuning.pair/{Hi}", "2.0", "Knob", "Real"),
  }

  local function at(row, col)
    return nudge.locate(items, lines, row, col)
  end

  it("finds the one value whose text is under the cursor", function()
    local found = at(7, 14) -- on 9.8
    assert.are.equal("one", found.kind)
    assert.are.equal("Game.Tuning.tuning/{Gravity}", found.item.address)
  end)

  it("two bindings with the same text are told apart by the binding the cursor is in", function()
    local first = at(6, 20)   -- 12.5 inside `tuning`
    assert.are.equal("Game.Tuning.tuning/{JumpVelocity}", first.item.address)
    local second = at(11, 20) -- 12.5 inside `other`
    assert.are.equal("Game.Tuning.other/{JumpVelocity}", second.item.address)
  end)

  it("a one-line binding is found on its own line, not by an earlier binding with the same text", function()
    assert.are.equal("Game.Tuning.speed", at(15, 14).item.address)
    assert.are.equal("Game.Tuning.drag", at(16, 13).item.address)
  end)

  it("two fields on one line with the same text are told apart by the field name before them", function()
    local lo = at(17, 19) -- on the first 2.0
    local hi = at(17, 30) -- on the second 2.0
    assert.are.equal("Game.Tuning.pair/{Lo}", lo.item.address)
    assert.are.equal("Game.Tuning.pair/{Hi}", hi.item.address)
  end)

  it("off any value there is nothing, and it says what the line has", function()
    local found = at(5, 2)
    assert.are.equal("none", found.kind)
    assert.is_truthy(found.reason:find("cursor", 1, true))
  end)

  it("a number in a binding the daemon does not list is not attributed to an earlier binding that has the same text", function()
    -- `fn` is a function the daemon does not list, and `drag` above it has 1.0
    local found = at(18, 17)
    assert.are.equal("none", found.kind)
  end)

  it("when it cannot tell two apart it offers them, innermost first, and never picks one", function()
    local tied = {
      item("A.x/Tuple.0", "5", "Knob", "Integer"),
      item("A.x/Tuple.1", "5", "Knob", "Integer"),
    }
    local found = nudge.locate(tied, { "let x = (5, 5)" }, 1, 9)
    assert.are.equal("many", found.kind)
    assert.are.equal(2, #found.items)
  end)

  it("a value that spans lines is not located by text, but the rest still are", function()
    local multi = { item("M.f", "a\n+ b", "Formula"), item("M.g", "7", "Knob", "Integer") }
    local found = nudge.locate(multi, { "let g = 7" }, 1, 8)
    assert.are.equal("one", found.kind)
    assert.are.equal("M.g", found.item.address)
  end)

  it("a formula that holds the cursor is a candidate for set, with the literal inside it too", function()
    local list = {
      item("M.f", "x * 2.0", "Formula"),
      item("M.f/BinOp.Right", "2.0", "Knob", "Real"),
    }
    local found = nudge.locate(list, { "let f x = x * 2.0" }, 1, 16)
    assert.are.equal("many", found.kind)
    assert.are.equal("M.f/BinOp.Right", found.items[1].address, "the innermost first")
    local knob = nudge.locate(list, { "let f x = x * 2.0" }, 1, 16, { knob_only = true })
    assert.are.equal("one", knob.kind)
    assert.are.equal("M.f/BinOp.Right", knob.item.address)
  end)
end)

describe("nudge.unsaved_refusal", function()
  it("a buffer with edits is refused by name, because the daemon writes the file on disk", function()
    local text = nudge.unsaved_refusal({ modified = true, name = "/w/Game.fs" })
    assert.is_truthy(text:find("unsaved", 1, true))
    assert.is_truthy(text:find(":write", 1, true))
    assert.is_truthy(text:find("on disk", 1, true))
  end)

  it("a clean named buffer is fine, and a buffer with no file is refused", function()
    assert.is_nil(nudge.unsaved_refusal({ modified = false, name = "/w/Game.fs" }))
    assert.is_truthy(nudge.unsaved_refusal({ modified = false, name = "" }):find("file", 1, true))
  end)
end)

describe("nudge.working_directory", function()
  it("is the active session's own directory, and the editor's only when the session has none", function()
    assert.are.equal("/w", nudge.working_directory({ working_directory = "/w" }, "/cwd"))
    assert.are.equal("/cwd", nudge.working_directory({ working_directory = "" }, "/cwd"))
    assert.are.equal("/cwd", nudge.working_directory(nil, "/cwd"))
  end)
end)

describe("nudge.parse_command", function()
  it("reads the sub-commands and their arguments", function()
    assert.are.same({ action = "up", step = nil }, nudge.parse_command("up"))
    assert.are.same({ action = "down", step = "0.5" }, nudge.parse_command("down 0.5"))
    assert.are.same({ action = "set", value = "13.5" }, nudge.parse_command("set 13.5"))
    assert.are.same({ action = "set", value = nil }, nudge.parse_command("set"))
    assert.are.same({ action = "expr", value = "gravity * 2.0" }, nudge.parse_command("expr gravity * 2.0"))
    assert.are.same({ action = "undo" }, nudge.parse_command("undo"))
    assert.are.same({ action = "redo" }, nudge.parse_command("redo"))
    assert.are.same({ action = "list" }, nudge.parse_command("list"))
  end)

  it("with nothing it bumps up, and an unknown word is refused with the list", function()
    assert.are.equal("up", nudge.parse_command("").action)
    local bad = nudge.parse_command("sideways")
    assert.is_nil(bad.action)
    assert.is_truthy(bad.error:find("up, down", 1, true))
  end)
end)
