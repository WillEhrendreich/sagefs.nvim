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

-- An inspect item as McpNudge.itemJson gives it: its place (`line` from 1, `column`
-- from 0 and `endColumn` exclusive, counted in characters) and, for a literal, the
-- typed `value`. `place` is { line, column, endLine, endColumn }; `value` is the
-- typed value (nil for a formula, and for a real the daemon cannot write as JSON).
local function item(address, text, kind, value_kind, place, value)
  local it = {
    address = address, text = text, hash = ("h:" .. address), kind = kind or "Knob", valueKind = value_kind,
  }
  if place then
    it.line, it.column, it.endLine, it.endColumn = place[1], place[2], place[3] or place[1], place[4]
  end
  it.value = value
  return it
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

  it("names the session by its id when it has one, so two sessions in one directory work", function()
    local args = nudge.build_args({ action = "inspect", file = "/w/Game.fs", working_directory = "/w", session_id = "sess-9" })
    assert.are.same({ action = "inspect", file = "/w/Game.fs", working_directory = "/w", session_id = "sess-9" }, args)
    assert.is_nil(nudge.build_args({ action = "inspect", session_id = "" }).session_id)
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
  -- The item as the daemon lists it: the typed value, and the text it stands as.
  local function listed(text)
    if text == "true" or text == "false" then return { text = text, valueKind = "Boolean", value = text == "true" } end
    local plain = text:gsub("<.*>$", ""):gsub("_", "")
    local hex = plain:match("^0[xX](%x+)$")
    if hex then return { text = text, valueKind = "Integer", value = tonumber(hex, 16) } end
    local number = tonumber(plain)
    if number and plain:find(".", 1, true) then return { text = text, valueKind = "Real", value = number } end
    if number then return { text = text, valueKind = "Integer", value = number } end
    return { text = text, valueKind = "UnionCase", value = text }
  end

  local function bump(text, dir, count, step)
    return nudge.bump(listed(text), dir, count, step)
  end

  it("the number is the daemon's typed value; the text only says how it is written", function()
    local item_with = { text = "12.5", valueKind = "Real", value = 20.0 }
    assert.are.equal("20.1", nudge.bump(item_with, 1))
    local hex = { text = "0x1F", valueKind = "Integer", value = 255 }
    assert.are.equal("256", nudge.bump(hex, 1))
    local flipped = { text = "true", valueKind = "Boolean", value = false }
    assert.are.equal("true", nudge.bump(flipped, -1), "the bool is the value, not the word")
  end)

  it("a real the daemon could not write as a number (it sends null) is not bumped, and says why", function()
    local literal, why = nudge.bump({ text = "1.7976931348623157e309", valueKind = "Real", value = nil }, 1)
    assert.is_nil(literal)
    assert.is_truthy(why:find("number", 1, true))
    local plain, plain_why = nudge.bump({ text = "9.5", valueKind = "Real", value = nil }, 1)
    assert.is_nil(plain, "no value, no bump, even when the text would parse")
    assert.is_truthy(plain_why)
  end)

  it("text, a character and a union case are not numbers whatever their text looks like", function()
    for _, kind in ipairs({ "Text", "Character", "UnionCase" }) do
      local literal, why = nudge.bump({ text = "12", valueKind = kind, value = "12" }, 1)
      assert.is_nil(literal, kind)
      assert.is_truthy(why:find(":SageFsNudge set", 1, true), kind)
    end
  end)

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
  -- Where the daemon says each one is: line from 1, column from 0, endColumn exclusive.
  local items = {
    item("Game.Tuning.tuning/{JumpVelocity}", "12.5", "Knob", "Real", { 6, 19, 6, 23 }, 12.5),
    item("Game.Tuning.tuning/{Gravity}", "9.8", "Knob", "Real", { 7, 14, 7, 17 }, 9.8),
    item("Game.Tuning.tuning/{Cap}", "12", "Knob", "Integer", { 8, 10, 8, 12 }, 12),
    item("Game.Tuning.other/{JumpVelocity}", "12.5", "Knob", "Real", { 11, 19, 11, 23 }, 12.5),
    item("Game.Tuning.other/{Gravity}", "3.0", "Knob", "Real", { 12, 14, 12, 17 }, 3.0),
    item("Game.Tuning.other/{Cap}", "9", "Knob", "Integer", { 13, 10, 13, 11 }, 9),
    item("Game.Tuning.speed", "1.0", "Knob", "Real", { 15, 12, 15, 15 }, 1.0),
    item("Game.Tuning.drag", "1.0", "Knob", "Real", { 16, 11, 16, 14 }, 1.0),
    item("Game.Tuning.pair/{Lo}", "2.0", "Knob", "Real", { 17, 18, 17, 21 }, 2.0),
    item("Game.Tuning.pair/{Hi}", "2.0", "Knob", "Real", { 17, 28, 17, 31 }, 2.0),
  }

  local function at(row, col)
    return nudge.locate(items, lines, row, col)
  end

  it("finds the one value whose range holds the cursor", function()
    local found = at(7, 14) -- on 9.8
    assert.are.equal("one", found.kind)
    assert.are.equal("Game.Tuning.tuning/{Gravity}", found.item.address)
  end)

  it("two bindings with the same text are told apart by where they are", function()
    assert.are.equal("Game.Tuning.tuning/{JumpVelocity}", at(6, 20).item.address)
    assert.are.equal("Game.Tuning.other/{JumpVelocity}", at(11, 20).item.address)
  end)

  it("a one-line binding is found on its own line", function()
    assert.are.equal("Game.Tuning.speed", at(15, 14).item.address)
    assert.are.equal("Game.Tuning.drag", at(16, 13).item.address)
  end)

  it("a range starts at its column and ends before its endColumn", function()
    assert.are.equal("Game.Tuning.speed", at(15, 12).item.address, "the first character is in")
    assert.are.equal("Game.Tuning.speed", at(15, 14).item.address, "the last character is in")
    assert.are.equal("none", at(15, 11).kind, "the character before it is not")
    assert.are.equal("none", at(15, 15).kind, "endColumn is one past the end")
  end)

  it("two values with the same text on one line are told apart by their columns, with no picker", function()
    local tuple = {
      item("A.x/Tuple.0", "5", "Knob", "Integer", { 1, 9, 1, 10 }, 5),
      item("A.x/Tuple.1", "5", "Knob", "Integer", { 1, 12, 1, 13 }, 5),
    }
    local row = { "let x = (5, 5)" }
    assert.are.equal("A.x/Tuple.0", nudge.locate(tuple, row, 1, 9).item.address)
    assert.are.equal("A.x/Tuple.1", nudge.locate(tuple, row, 1, 12).item.address)
    assert.are.equal("none", nudge.locate(tuple, row, 1, 10).kind, "the comma is neither")
  end)

  it("a field written after its own name is no longer needed to tell values apart: the range is", function()
    -- the same two 2.0s, with the items listed in the other order
    local reversed = { items[10], items[9] }
    assert.are.equal("Game.Tuning.pair/{Lo}", nudge.locate(reversed, lines, 17, 19).item.address)
    assert.are.equal("Game.Tuning.pair/{Hi}", nudge.locate(reversed, lines, 17, 30).item.address)
  end)

  it("off any value there is nothing, and it says what to do", function()
    local found = at(5, 2)
    assert.are.equal("none", found.kind)
    assert.is_truthy(found.reason:find("cursor", 1, true))
  end)

  it("a number in a binding the daemon does not list is not attributed to an earlier binding that has the same text", function()
    -- `fn` is a function the daemon does not list, and `drag` above it has 1.0
    assert.are.equal("none", at(18, 17).kind)
  end)

  it("when two items hold exactly the same range it offers them and never picks one", function()
    local twins = {
      item("A.x/Tuple.0", "5", "Knob", "Integer", { 1, 9, 1, 10 }, 5),
      item("A.x/Tuple.1", "5", "Knob", "Integer", { 1, 9, 1, 10 }, 5),
    }
    local found = nudge.locate(twins, { "let x = (5, 5)" }, 1, 9)
    assert.are.equal("many", found.kind)
    assert.are.equal(2, #found.items)
  end)

  it("a value that spans lines is found from any line it covers, not by its text", function()
    local multi = {
      item("M.f", "a\n      + b", "Formula", nil, { 1, 8, 2, 9 }),
      item("M.g", "7", "Knob", "Integer", { 3, 8, 3, 9 }, 7),
    }
    local text = { "let f = a", "      + b", "let g = 7" }
    assert.are.equal("M.f", nudge.locate(multi, text, 1, 8).item.address, "on its first line")
    assert.are.equal("M.f", nudge.locate(multi, text, 2, 6).item.address, "on its second line")
    assert.are.equal("none", nudge.locate(multi, text, 1, 7).kind, "before it starts")
    assert.are.equal("none", nudge.locate(multi, text, 2, 9).kind, "at its endColumn")
    assert.are.equal("M.g", nudge.locate(multi, text, 3, 8).item.address, "and the rest still are")
  end)

  it("a formula that holds the cursor is a candidate for set, with the literal inside it too", function()
    local list = {
      item("M.f", "x * 2.0", "Formula", nil, { 1, 10, 1, 17 }),
      item("M.f/BinOp.Right", "2.0", "Knob", "Real", { 1, 14, 1, 17 }, 2.0),
    }
    local row = { "let f x = x * 2.0" }
    local found = nudge.locate(list, row, 1, 15)
    assert.are.equal("many", found.kind)
    assert.are.equal("M.f/BinOp.Right", found.items[1].address, "the innermost first")
    local knob = nudge.locate(list, row, 1, 15, { knob_only = true })
    assert.are.equal("one", knob.kind)
    assert.are.equal("M.f/BinOp.Right", knob.item.address)
  end)

  -- The daemon counts columns in characters (UTF-16 code units, the parser's own),
  -- the cursor is a byte offset: text before a value that is not ASCII moves one
  -- onto the other.
  describe("with text before the value that is not ASCII", function()
    -- let t = ("éé", 7.5)   bytes: `"` 9, é 10-11, é 12-13, `"` 14, `,` 15, ` ` 16, `7` 17
    --                       chars: `"` 9, é 10, é 11, `"` 12, `,` 13, ` ` 14, `7` 15
    local accents = { 'let t = ("éé", 7.5)' }
    local accent_items = { item("T.t/Tuple.1", "7.5", "Knob", "Real", { 1, 15, 1, 18 }, 7.5) }

    it("a cursor on the value is found by its character column, not its byte column", function()
      assert.are.equal("T.t/Tuple.1", nudge.locate(accent_items, accents, 1, 17).item.address, "on the 7")
      assert.are.equal("T.t/Tuple.1", nudge.locate(accent_items, accents, 1, 19).item.address, "on the 5")
    end)

    it("a cursor that would be inside the range if bytes were characters is not", function()
      assert.are.equal("none", nudge.locate(accent_items, accents, 1, 15).kind, "byte 15 is the comma")
      assert.are.equal("none", nudge.locate(accent_items, accents, 1, 16).kind, "byte 16 is the space")
      assert.are.equal("none", nudge.locate(accent_items, accents, 1, 20).kind, "byte 20 is the paren")
    end)

    it("an emoji is two characters to the parser (two UTF-16 units) and four bytes to the cursor", function()
      local emoji = { 'let t = ("😀", 7.5)' }
      assert.are.equal("T.t/Tuple.1", nudge.locate(accent_items, emoji, 1, 17).item.address)
      assert.are.equal("none", nudge.locate(accent_items, emoji, 1, 15).kind)
    end)
  end)

  describe("nudge.char_column", function()
    it("is the byte column on an ASCII line", function()
      assert.are.equal(4, nudge.char_column("let x = 1", 4))
      assert.are.equal(0, nudge.char_column("let x = 1", 0))
    end)

    it("counts a two-byte character once and an astral character twice", function()
      assert.are.equal(1, nudge.char_column("éa", 2))
      assert.are.equal(2, nudge.char_column("😀a", 4))
      assert.are.equal(3, nudge.char_column("é😀a", 6))
    end)

    it("a byte column in the middle of a character is that character's own column", function()
      assert.are.equal(0, nudge.char_column("éa", 1))
      assert.are.equal(1, nudge.char_column("aéa", 2))
    end)

    it("a column past the end of the line is the line's length", function()
      assert.are.equal(2, nudge.char_column("é1", 30))
    end)
  end)

  it("items the daemon listed with no position are never located, and the reason says the daemon may be older", function()
    local bare = { { address = "M.x", text = "1.0", hash = "h", kind = "Knob", valueKind = "Real", value = 1.0 } }
    local found = nudge.locate(bare, { "let x = 1.0" }, 1, 9)
    assert.are.equal("none", found.kind)
    assert.is_truthy(found.reason:find("older", 1, true))
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
