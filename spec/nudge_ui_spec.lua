-- Tests: the flow of :SageFsNudge (sagefs.nudge_ui), with the daemon, the buffer
-- and the pickers replaced by fakes, so every step runs under busted:
-- refuse an unsaved buffer, inspect, find the value under the cursor, bump or
-- set it with the hash inspect gave, show the reply, and reload the buffer when
-- the daemon wrote the file.
require("spec.helper")

local ui = require("sagefs.nudge_ui")

local LINES = {
  "module Game.Tuning",            -- 1
  "",                              -- 2
  "let tuning =",                  -- 3
  "  { JumpVelocity = 12.5",       -- 4
  "    Gravity = 9.8",             -- 5
  "    Cap = 12 }",                -- 6
  "let mode = Hard",               -- 7
}

local function item(address, text, kind, value_kind)
  return { address = address, text = text, hash = "hash-" .. address, kind = kind or "Knob", valueKind = value_kind }
end

local ITEMS = {
  item("Game.Tuning.tuning/{JumpVelocity}", "12.5", "Knob", "Real"),
  item("Game.Tuning.tuning/{Gravity}", "9.8", "Knob", "Real"),
  item("Game.Tuning.tuning/{Cap}", "12", "Knob", "Integer"),
  item("Game.Tuning.mode", "Hard", "Knob", "UnionCase"),
}

local function inspected(items, extra)
  local reply = { outcome = "Inspected", file = "/w/Game.fs", fileHash = "fh", items = items or ITEMS, undoSteps = 0, redoSteps = 0,
    listing = "Complete", notes = {} }
  for k, v in pairs(extra or {}) do reply[k] = v end
  return vim.json.encode(reply)
end

--- A harness: fake deps that record what happened.
local function harness(opts)
  opts = opts or {}
  local h = { calls = {}, notes = {}, reloads = 0, selects = {}, inputs = {} }
  local replies = opts.replies or {}
  h.deps = {
    buffer = function()
      return {
        name = opts.name == nil and "/w/Game.fs" or opts.name,
        modified = opts.modified or false,
        lines = LINES,
        row = opts.row or 4,
        col = opts.col or 20,
        tick = h.tick or 1,
      }
    end,
    working_directory = function() return opts.working_directory or "/w" end,
    call = function(args, cb)
      table.insert(h.calls, args)
      local reply = table.remove(replies, 1)
      if type(reply) == "function" then reply = reply(args) end
      assert(reply, "no scripted reply for call " .. #h.calls .. " (" .. tostring(args.action) .. ")")
      cb(require("sagefs.nudge").parse_reply(reply.ok ~= false, reply.body))
    end,
    notify = function(msg, level) table.insert(h.notes, { msg = msg, level = level }) end,
    select = function(list, sel_opts, cb)
      table.insert(h.selects, { items = list, prompt = sel_opts.prompt })
      cb(opts.pick and list[opts.pick] or nil)
    end,
    input = function(in_opts, cb)
      table.insert(h.inputs, in_opts)
      cb(opts.typed)
    end,
    reload = function() h.reloads = h.reloads + 1 end,
  }
  return h
end

local function written(address, before, after, notes)
  return { body = vim.json.encode({ outcome = "Written", file = "/w/Game.fs", address = address, before = before, after = after,
    hashAfter = "h2", fileHashBefore = "a", fileHashAfter = "b", eventId = 3, notes = notes or {} }) }
end

describe("nudge_ui.execute: bump", function()
  it("inspects the file, finds the number under the cursor, and sets it with the hash inspect gave", function()
    local h = harness({ replies = { { body = inspected() }, written("Game.Tuning.tuning/{JumpVelocity}", "12.5", "12.6") } })
    ui.execute(h.deps, { action = "up" }, 1)
    assert.are.equal(2, #h.calls)
    assert.are.same({ action = "inspect", file = "/w/Game.fs", working_directory = "/w" }, h.calls[1])
    assert.are.same({
      action = "set", file = "/w/Game.fs", address = "Game.Tuning.tuning/{JumpVelocity}",
      seen = "hash-Game.Tuning.tuning/{JumpVelocity}", literal = "12.6", working_directory = "/w",
    }, h.calls[2])
    assert.is_truthy(h.notes[#h.notes].msg:find("12.5", 1, true))
    assert.is_truthy(h.notes[#h.notes].msg:find("12.6", 1, true))
  end)

  it("down and a count move by that many steps", function()
    local h = harness({ row = 5, col = 14, replies = { { body = inspected() }, written("Game.Tuning.tuning/{Gravity}", "9.8", "9.3") } })
    ui.execute(h.deps, { action = "down" }, 5)
    assert.are.equal("9.3", h.calls[2].literal)
  end)

  it("an explicit step is used", function()
    local h = harness({ row = 6, col = 12, replies = { { body = inspected() }, written("Game.Tuning.tuning/{Cap}", "12", "22") } })
    ui.execute(h.deps, { action = "up", step = "10" }, 1)
    assert.are.equal("22", h.calls[2].literal)
  end)

  it("the buffer is reloaded after a write, so the file the daemon wrote is what the editor shows", function()
    local h = harness({ replies = { { body = inspected() }, written("Game.Tuning.tuning/{JumpVelocity}", "12.5", "12.6") } })
    ui.execute(h.deps, { action = "up" }, 1)
    assert.are.equal(1, h.reloads)
  end)

  it("a value that is not a number says so and sends nothing", function()
    local h = harness({ row = 7, col = 13, replies = { { body = inspected() } } })
    ui.execute(h.deps, { action = "up" }, 1)
    assert.are.equal(1, #h.calls, "only the inspect went out")
    assert.is_truthy(h.notes[#h.notes].msg:find(":SageFsNudge set", 1, true))
    assert.are.equal(0, h.reloads)
  end)

  it("with no value under the cursor it says so and sends nothing", function()
    local h = harness({ row = 3, col = 2, replies = { { body = inspected() } } })
    ui.execute(h.deps, { action = "up" }, 1)
    assert.are.equal(1, #h.calls)
    assert.is_truthy(h.notes[#h.notes].msg:find("cursor", 1, true))
  end)

  it("says when the daemon listed only part of a big file", function()
    local h = harness({ row = 3, col = 2, replies = { { body = inspected(ITEMS, { listing = "Truncated", shown = 200, total = 340 }) } } })
    ui.execute(h.deps, { action = "up" }, 1)
    assert.is_truthy(h.notes[#h.notes].msg:find("340", 1, true))
  end)
end)

describe("nudge_ui.execute: refusals and failures", function()
  it("a buffer with unsaved edits is refused before anything goes to the daemon", function()
    local h = harness({ modified = true })
    ui.execute(h.deps, { action = "up" }, 1)
    assert.are.equal(0, #h.calls)
    assert.is_truthy(h.notes[1].msg:find("unsaved", 1, true))
    assert.are.equal(vim.log.levels.WARN, h.notes[1].level)
  end)

  it("a buffer that is no file is refused", function()
    local h = harness({ name = "" })
    ui.execute(h.deps, { action = "undo" }, 1)
    assert.are.equal(0, #h.calls)
  end)

  it("a refusal from the daemon shows its rule and next action, and the buffer is left alone", function()
    local h = harness({ replies = { { body = inspected() }, { body = vim.json.encode({
      outcome = "Refused", refusal = "SourceMoved", rule = "The expression changed since you inspected it.",
      nextAction = "Run action=inspect again.",
    }) } } })
    ui.execute(h.deps, { action = "up" }, 1)
    local note = h.notes[#h.notes]
    assert.is_truthy(note.msg:find("SourceMoved", 1, true))
    assert.is_truthy(note.msg:find("Run action=inspect again.", 1, true))
    assert.are.equal(vim.log.levels.WARN, note.level)
    assert.are.equal(0, h.reloads)
  end)

  it("a refusal to inspect (a file the session does not own) is shown as it came", function()
    local h = harness({ replies = { { body = vim.json.encode({
      outcome = "Refused", refusal = "NotOwned", rule = "/w/Other.fs is not a source file of any project this session loaded.",
      nextAction = "Pass a source file of one of the session's projects.",
    }) } } })
    ui.execute(h.deps, { action = "up" }, 1)
    assert.are.equal(1, #h.calls)
    assert.is_truthy(h.notes[#h.notes].msg:find("NotOwned", 1, true))
  end)

  it("a failed call (an older daemon, a token without the role) shows the daemon's words as an error", function()
    local h = harness({ replies = { { ok = false, body = "Role 'Observer' may not call nudge_value." } } })
    ui.execute(h.deps, { action = "up" }, 1)
    assert.is_truthy(h.notes[#h.notes].msg:find("Observer", 1, true))
    assert.are.equal(vim.log.levels.ERROR, h.notes[#h.notes].level)
  end)

  it("a buffer that changed while the daemon was answering is not written to from a stale picture of it", function()
    local h = harness({ replies = { function() h.tick = 2; return { body = inspected() } end } })
    ui.execute(h.deps, { action = "up" }, 1)
    assert.are.equal(1, #h.calls, "no write went out")
    assert.is_truthy(h.notes[#h.notes].msg:find("changed", 1, true))
  end)
end)

describe("nudge_ui.execute: set, expr, list", function()
  it("set with a typed value sends it as the literal", function()
    local h = harness({ replies = { { body = inspected() }, written("Game.Tuning.tuning/{JumpVelocity}", "12.5", "20.0") } })
    ui.execute(h.deps, { action = "set", value = "20.0" }, 1)
    assert.are.equal("20.0", h.calls[2].literal)
    assert.is_nil(h.calls[2].expression)
  end)

  it("set with no value asks for one, starting from the current text", function()
    local h = harness({ typed = "99.5", replies = { { body = inspected() }, written("Game.Tuning.tuning/{JumpVelocity}", "12.5", "99.5") } })
    ui.execute(h.deps, { action = "set" }, 1)
    assert.are.equal(1, #h.inputs)
    assert.are.equal("12.5", h.inputs[1].default)
    assert.are.equal("99.5", h.calls[2].literal)
  end)

  it("cancelling the prompt sends nothing", function()
    local h = harness({ typed = nil, replies = { { body = inspected() } } })
    ui.execute(h.deps, { action = "set" }, 1)
    assert.are.equal(1, #h.calls)
  end)

  it("a union case is set by name", function()
    local h = harness({ row = 7, col = 13, replies = { { body = inspected() }, written("Game.Tuning.mode", "Hard", "Easy") } })
    ui.execute(h.deps, { action = "set", value = "Easy" }, 1)
    assert.are.equal("Easy", h.calls[2].literal)
  end)

  it("expr sends an expression, never a literal", function()
    local h = harness({ replies = { { body = inspected() }, written("Game.Tuning.tuning/{JumpVelocity}", "12.5", "gravity * 2.0", { "ExpressionNotTypeChecked" }) } })
    ui.execute(h.deps, { action = "expr", value = "gravity * 2.0" }, 1)
    assert.are.equal("gravity * 2.0", h.calls[2].expression)
    assert.is_nil(h.calls[2].literal)
    assert.is_truthy(h.notes[#h.notes].msg:find("type%-checked"), "the type-check note is passed on")
  end)

  it("a formula is set as an expression even by set", function()
    local items = { item("M.f", "x * 2.0", "Formula") }
    local h = harness({ row = 1, col = 12, replies = { { body = inspected(items) }, written("M.f", "x * 2.0", "x * 3.0") } })
    h.deps.buffer = function() return { name = "/w/F.fs", modified = false, lines = { "let f x = x * 2.0" }, row = 1, col = 12, tick = 1 } end
    ui.execute(h.deps, { action = "set", value = "x * 3.0" }, 1)
    assert.are.equal("x * 3.0", h.calls[2].expression)
    assert.is_nil(h.calls[2].literal)
  end)

  it("with nothing under the cursor, set offers every value of the file", function()
    local h = harness({ row = 3, col = 2, pick = 2, replies = { { body = inspected() }, written("Game.Tuning.tuning/{Gravity}", "9.8", "1.0") } })
    ui.execute(h.deps, { action = "set", value = "1.0" }, 1)
    assert.are.equal(1, #h.selects)
    assert.are.equal(4, #h.selects[1].items)
    assert.are.equal("Game.Tuning.tuning/{Gravity}", h.calls[2].address)
  end)

  it("list shows the values, and the one picked is set to what is typed", function()
    local h = harness({ pick = 3, typed = "30", replies = { { body = inspected() }, written("Game.Tuning.tuning/{Cap}", "12", "30") } })
    ui.execute(h.deps, { action = "list" }, 1)
    assert.are.equal("Game.Tuning.tuning/{Cap}", h.calls[2].address)
    assert.are.equal("30", h.calls[2].literal)
  end)

  it("when two values tie, they are offered and the one picked is bumped", function()
    local tied = { item("A.x/Tuple.0", "5", "Knob", "Integer"), item("A.x/Tuple.1", "5", "Knob", "Integer") }
    local h = harness({ pick = 2, replies = { { body = inspected(tied) }, written("A.x/Tuple.1", "5", "6") } })
    h.deps.buffer = function() return { name = "/w/A.fs", modified = false, lines = { "let x = (5, 5)" }, row = 1, col = 9, tick = 1 } end
    ui.execute(h.deps, { action = "up" }, 1)
    assert.are.equal(1, #h.selects)
    assert.are.equal("A.x/Tuple.1", h.calls[2].address)
    assert.are.equal("6", h.calls[2].literal)
  end)
end)

describe("nudge_ui.execute: undo and redo", function()
  it("undo goes straight to the daemon for this file and reloads the buffer", function()
    local h = harness({ replies = { { body = vim.json.encode({ outcome = "Undone", file = "/w/Game.fs", address = "M.x", before = "12.6", after = "12.5", notes = {} }) } } })
    ui.execute(h.deps, { action = "undo" }, 1)
    assert.are.equal(1, #h.calls)
    assert.are.same({ action = "undo", file = "/w/Game.fs", working_directory = "/w" }, h.calls[1])
    assert.are.equal(1, h.reloads)
    assert.is_truthy(h.notes[#h.notes].msg:lower():find("undone", 1, true))
  end)

  it("redo likewise", function()
    local h = harness({ replies = { { body = vim.json.encode({ outcome = "Redone", file = "/w/Game.fs", address = "M.x", before = "12.5", after = "12.6", notes = {} }) } } })
    ui.execute(h.deps, { action = "redo" }, 1)
    assert.are.equal("redo", h.calls[1].action)
    assert.are.equal(1, h.reloads)
  end)

  it("nothing to undo is the daemon's refusal, shown with its next action, and the buffer is not reloaded", function()
    local h = harness({ replies = { { body = vim.json.encode({ outcome = "Refused", refusal = "NothingToUndo",
      rule = "This door has written nothing to this file that is left to undo.", nextAction = "Nothing to do." }) } } })
    ui.execute(h.deps, { action = "undo" }, 1)
    assert.is_truthy(h.notes[#h.notes].msg:find("NothingToUndo", 1, true))
    assert.are.equal(0, h.reloads)
  end)
end)

describe("nudge_ui.execute: the session is named on every call", function()
  it("every call carries the working directory the deps name", function()
    local h = harness({ working_directory = "/work/other-repo",
      replies = { { body = inspected() }, written("Game.Tuning.tuning/{JumpVelocity}", "12.5", "12.6") } })
    ui.execute(h.deps, { action = "up" }, 1)
    for _, call in ipairs(h.calls) do
      assert.are.equal("/work/other-repo", call.working_directory)
    end
  end)
end)

describe("nudge_ui registration", function()
  it("registers :SageFsNudge with a count and sub-command completion", function()
    local registered = {}
    ui.register({}, { notify = function() end }, function(name, handler, opts) registered[name] = { handler = handler, opts = opts } end)
    local command = registered.SageFsNudge
    assert.is_truthy(command)
    assert.are.equal("*", command.opts.nargs)
    assert.is_truthy(command.opts.count ~= nil)
    local completed = command.opts.complete("", "SageFsNudge ", 12)
    assert.are.same({ "up", "down", "set", "expr", "undo", "redo", "list" }, completed)
    assert.are.same({ "up", "undo" }, command.opts.complete("u", "SageFsNudge u", 13))
  end)

  it("an unknown sub-command is said, with the list, and nothing is sent", function()
    local registered, notes = {}, {}
    ui.register({}, { notify = function(msg) table.insert(notes, msg) end },
      function(name, handler) registered[name] = handler end)
    registered.SageFsNudge({ args = "sideways", count = 0 })
    assert.is_truthy(notes[1]:find("up, down", 1, true))
  end)

  it("maps are namespaced under <leader>rk on the buffer, and none is mapped twice", function()
    local mapped = {}
    local prev = vim.keymap
    vim.keymap = { set = function(mode, lhs, rhs, opts) table.insert(mapped, { mode = mode, lhs = lhs, opts = opts }) end }
    ui.register_keymaps({}, { notify = function() end }, 7)
    vim.keymap = prev
    local seen = {}
    for _, m in ipairs(mapped) do
      assert.is_truthy(m.lhs:find("^<leader>rk"), m.lhs .. " is under <leader>rk")
      assert.are.equal(7, m.opts.buffer)
      assert.is_falsy(seen[m.lhs], m.lhs .. " is mapped once")
      seen[m.lhs] = true
    end
    for _, lhs in ipairs({ "<leader>rk+", "<leader>rk-", "<leader>rks", "<leader>rke", "<leader>rku", "<leader>rkr", "<leader>rkl" }) do
      assert.is_truthy(seen[lhs], lhs .. " is mapped")
    end
  end)

  it("no other part of the plugin maps <leader>rk, so the namespace is ours alone", function()
    local src = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
    for _, name in ipairs({ "commands.lua", "init.lua", "coverage_hover.lua", "debug_test_ui.lua", "bindings_view.lua", "wire_testing.lua" }) do
      local f = io.open(src .. "../lua/sagefs/" .. name, "rb")
      if f then
        local text = f:read("*a")
        f:close()
        assert.is_falsy(text:find('"<leader>rk', 1, true), name .. " must not map <leader>rk")
      end
    end
  end)
end)
