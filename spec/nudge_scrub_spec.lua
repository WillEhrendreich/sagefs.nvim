-- spec/nudge_scrub_spec.lua — the scrub key: press (or hold) it and the value
-- under the cursor keeps moving, the way a knob turns.
--
-- The roadmap (SageFs docs/roadmap.md): "a scrub key in Neovim ... both writing
-- through the nudge door so the same rules and the same undo apply." So the key
-- is not a second way to change a file. It runs :SageFsNudge's own flow
-- (nudge_ui.execute via M.run): inspect the file, find the value under the
-- cursor by the range the daemon reports (nudge.locate), bump it client-side
-- (nudge.bump), and set it with the hash inspect gave through the daemon's
-- nudge_value tool. Holding the key just presses it again (the terminal or GUI
-- repeats it); the gate in front of M.run queues the flows in order.
--
-- Covers: one press nudges up, the other down, a count multiplies; the key and
-- the command call the same M.run with the same command; a press reaches the
-- daemon as inspect + set-with-hash and no module in the path writes the file
-- itself; a stale address refused by the daemon is shown, not swallowed; the
-- keys are buffer-local, described for :SageFsHelp, and remappable through
-- config like the plugin's other named key.
require("spec.helper")

local ui = require("sagefs.nudge_ui")
local nudge = require("sagefs.nudge")
local config = require("sagefs.config")

-- ─── The buffer and the file as inspect lists them ───────────────────────────

local LINES = {
  "module Game.Tuning",            -- 1
  "",                              -- 2
  "let tuning =",                  -- 3
  "  { JumpVelocity = 12.5",       -- 4
  "    Gravity = 9.8",             -- 5
  "    Cap = 12 }",                -- 6
  "let mode = Hard",               -- 7
}

local function item(address, text, kind, value_kind, place, value)
  local it = { address = address, text = text, hash = "hash-" .. address, kind = kind or "Knob",
    valueKind = value_kind, value = value }
  if place then it.line, it.column, it.endLine, it.endColumn = place[1], place[2], place[3] or place[1], place[4] end
  return it
end

local ITEMS = {
  item("Game.Tuning.tuning/{JumpVelocity}", "12.5", "Knob", "Real", { 4, 19, 4, 23 }, 12.5),
  item("Game.Tuning.tuning/{Gravity}", "9.8", "Knob", "Real", { 5, 14, 5, 17 }, 9.8),
  item("Game.Tuning.tuning/{Cap}", "12", "Knob", "Integer", { 6, 10, 6, 12 }, 12),
  item("Game.Tuning.mode", "Hard", "Knob", "UnionCase", { 7, 11, 7, 15 }, "Hard"),
}

local function inspected(items, extra)
  local reply = { outcome = "Inspected", file = "/w/Game.fs", fileHash = "fh", items = items or ITEMS,
    undoSteps = 0, redoSteps = 0, listing = "Complete", notes = {} }
  for k, v in pairs(extra or {}) do reply[k] = v end
  return vim.json.encode(reply)
end

local function written(address, before, after, notes)
  return { body = vim.json.encode({ outcome = "Written", file = "/w/Game.fs", address = address, before = before,
    after = after, hashAfter = "h2", fileHashBefore = "a", fileHashAfter = "b", eventId = 3, notes = notes or {} }) }
end

--- Fake deps that record what happened, in the style of spec/nudge_ui_spec.lua.
local function harness(opts)
  opts = opts or {}
  local h = { calls = {}, notes = {}, reloads = 0 }
  local replies = opts.replies or {}
  h.deps = {
    buffer = function()
      return {
        name = "/w/Game.fs",
        modified = false,
        lines = LINES,
        row = opts.row or 4,
        col = opts.col or 20,
        tick = 1,
      }
    end,
    working_directory = function() return "/w" end,
    session_id = function() return nil end,
    call = function(args, cb)
      table.insert(h.calls, args)
      local reply = table.remove(replies, 1)
      assert(reply, "no scripted reply for call " .. #h.calls .. " (" .. tostring(args.action) .. ")")
      cb(nudge.parse_reply(true, reply.body))
    end,
    notify = function(msg, level) table.insert(h.notes, { msg = msg, level = level }) end,
    select = function(_, _, cb) cb(nil) end,
    input = function(_, cb) cb(nil) end,
    reload = function() h.reloads = h.reloads + 1 end,
  }
  return h
end

-- ─── Pressing the key ────────────────────────────────────────────────────────

--- Register the buffer-local maps the way the plugin does, capturing them
--- instead of handing them to the editor.
local function capture_keymaps()
  local mapped = {}
  local prev = vim.keymap
  vim.keymap = {
    set = function(mode, lhs, rhs, opts)
      table.insert(mapped, { mode = mode, lhs = lhs, rhs = rhs, opts = opts })
    end,
  }
  ui.register_keymaps({}, { notify = function() end }, 7)
  vim.keymap = prev
  return mapped
end

--- Press the mapping for `lhs` the way the editor would: run its rhs with
--- vim.v.count1 set. `run` replaces M.run while the key is down (the specs
--- record what it was handed; the flow itself is exercised through
--- ui.execute with fake deps, and in a real buffer by spec/nvim_harness.lua).
local function press(mapped, lhs, run, count1)
  for _, m in ipairs(mapped) do
    if m.lhs == lhs then
      local prev_run, prev_v = ui.run, vim.v
      ui.run = run
      vim.v = { count1 = count1 or 1 }
      local ok, err = pcall(m.rhs)
      ui.run, vim.v = prev_run, prev_v
      if not ok then error(err, 0) end
      return m
    end
  end
  error("no mapping for " .. lhs, 2)
end

--- Press a scrub key and take the command M.run was called with.
local function press_for_cmd(mapped, lhs, count1)
  local got = {}
  press(mapped, lhs, function(_, _, cmd, count)
    got.cmd, got.count = cmd, count
  end, count1)
  return got
end

describe("the scrub key: what one press runs", function()
  it("nudges up: M.run with the command :SageFsNudge up runs", function()
    local maps = capture_keymaps()
    local got = press_for_cmd(maps, config.SCRUB_UP_KEY)
    assert.are.same({ action = "up" }, got.cmd)
    assert.are.equal(1, got.count)
  end)

  it("nudges down: M.run with the command :SageFsNudge down runs", function()
    local maps = capture_keymaps()
    local got = press_for_cmd(maps, config.SCRUB_DOWN_KEY)
    assert.are.same({ action = "down" }, got.cmd)
    assert.are.equal(1, got.count)
  end)

  it("a count multiplies the steps, like :5SageFsNudge up", function()
    local maps = capture_keymaps()
    local got = press_for_cmd(maps, config.SCRUB_UP_KEY, 5)
    assert.are.equal(5, got.count)
  end)

  it("the key and :SageFsNudge go through the same M.run with the same command", function()
    local ran = {}
    local prev_run = ui.run
    ui.run = function(_, _, cmd, count) table.insert(ran, { cmd = cmd, count = count }) end

    local registered = {}
    ui.register({}, { notify = function() end }, function(name, handler) registered[name] = handler end)
    registered.SageFsNudge({ args = "up", count = 0 })

    local maps = capture_keymaps()
    press(maps, config.SCRUB_UP_KEY, function(_, _, cmd, count) table.insert(ran, { cmd = cmd, count = count }) end)
    ui.run = prev_run

    assert.are.equal(2, #ran, "the command and the key each ran the flow once")
    assert.are.same({ action = "up" }, ran[1].cmd, "what :SageFsNudge up runs")
    assert.are.same(ran[1].cmd, ran[2].cmd, "the key runs exactly that")
  end)
end)

describe("the scrub key: through the nudge door", function()
  it("a press up is inspect, then set with the hash inspect gave — the daemon writes, the plugin does not", function()
    local maps = capture_keymaps()
    local h = harness({ replies = { { body = inspected() },
      written("Game.Tuning.tuning/{JumpVelocity}", "12.5", "12.6") } })
    local got = press_for_cmd(maps, config.SCRUB_UP_KEY)
    ui.execute(h.deps, got.cmd, got.count)

    assert.are.equal(2, #h.calls)
    assert.are.same({ action = "inspect", file = "/w/Game.fs", working_directory = "/w" }, h.calls[1])
    assert.are.same({
      action = "set", file = "/w/Game.fs", address = "Game.Tuning.tuning/{JumpVelocity}",
      seen = "hash-Game.Tuning.tuning/{JumpVelocity}", literal = "12.6", working_directory = "/w",
    }, h.calls[2], "the write goes through nudge_value with the hash inspect gave")
    assert.are.equal(1, h.reloads, "the buffer is re-read only after the daemon wrote")
    assert.is_truthy(h.notes[#h.notes].msg:find("12.5 -> 12.6", 1, true), "the change is reported")
  end)

  it("a press down moves the value the other way, one default step", function()
    local maps = capture_keymaps()
    local h = harness({ row = 5, col = 14, replies = { { body = inspected() },
      written("Game.Tuning.tuning/{Gravity}", "9.8", "9.7") } })
    local got = press_for_cmd(maps, config.SCRUB_DOWN_KEY)
    ui.execute(h.deps, got.cmd, got.count)

    assert.are.equal(2, #h.calls)
    assert.are.equal("set", h.calls[2].action)
    assert.are.equal("9.7", h.calls[2].literal, "9.8 down one default step (the last decimal place)")
  end)

  it("the value under the cursor is the one the daemon's range puts there — the same resolution :SageFsNudge uses", function()
    local maps = capture_keymaps()
    -- Cursor on Cap (an integer on line 6), not on the value of line 4 the
    -- default harness position would find: locate decides, by the ranges in
    -- the inspect reply, which the scrub press nudges.
    local h = harness({ row = 6, col = 10, replies = { { body = inspected() },
      written("Game.Tuning.tuning/{Cap}", "12", "13") } })
    local got = press_for_cmd(maps, config.SCRUB_UP_KEY)
    ui.execute(h.deps, got.cmd, got.count)

    assert.are.equal("Game.Tuning.tuning/{Cap}", h.calls[2].address)
    assert.are.equal("13", h.calls[2].literal, "an integer steps by one")
  end)

  it("a stale address the daemon refuses is shown, not swallowed, and nothing is written", function()
    local maps = capture_keymaps()
    local h = harness({ replies = { { body = inspected() }, { body = vim.json.encode({
      outcome = "Refused", refusal = "SourceMoved",
      rule = "The expression changed since you inspected it.",
      nextAction = "Run action=inspect again.",
    }) } } })
    local got = press_for_cmd(maps, config.SCRUB_UP_KEY)
    ui.execute(h.deps, got.cmd, got.count)

    assert.is_true(#h.notes > 0, "the refusal reaches the user instead of silence")
    local note = h.notes[#h.notes]
    assert.is_truthy(note.msg:find("SourceMoved", 1, true), note.msg)
    assert.is_truthy(note.msg:find("Run action=inspect again.", 1, true), note.msg)
    assert.are.equal(vim.log.levels.WARN, note.level)
    assert.are.equal(0, h.reloads, "the file was not touched")
  end)

  it("a refusal before anything is sent (an unsaved buffer) is shown too", function()
    local maps = capture_keymaps()
    local h = harness({})
    h.deps.buffer = function()
      return { name = "/w/Game.fs", modified = true, lines = LINES, row = 4, col = 20, tick = 1 }
    end
    local got = press_for_cmd(maps, config.SCRUB_UP_KEY)
    ui.execute(h.deps, got.cmd, got.count)

    assert.are.equal(0, #h.calls, "nothing went to the daemon")
    assert.is_truthy(h.notes[1].msg:find("unsaved", 1, true))
    assert.are.equal(vim.log.levels.WARN, h.notes[1].level)
  end)

  it("no module on the path writes the file: the door is the daemon's nudge_value tool", function()
    local src = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
    local writes = { "io.open", "os.rename", "os.remove", "write_file", "nvim_buf_set_lines",
      "nvim_buf_set_text", "vim.cmd(\"w", "vim.cmd(\"write" }
    for _, name in ipairs({ "nudge.lua", "nudge_ui.lua" }) do
      local f = assert(io.open(src .. "../lua/sagefs/" .. name, "rb"))
      local text = f:read("*a")
      f:close()
      for _, token in ipairs(writes) do
        assert.is_falsy(text:find(token, 1, true), name .. " must not contain " .. token)
      end
    end
    assert.are.equal("nudge_value", nudge.TOOL, "the tool the daemon implements")
    local f = assert(io.open(src .. "../lua/sagefs/nudge_ui.lua", "rb"))
    local text = f:read("*a")
    f:close()
    assert.is_truthy(text:find("call_tool(nudge.TOOL", 1, true),
      "the flow calls the client with that tool's name — the nudge door, journal, refusals, undo and all")
  end)
end)

describe("the scrub key: registration and remapping", function()
  local function by_lhs(mapped)
    local seen = {}
    for _, m in ipairs(mapped) do
      assert.is_falsy(seen[m.lhs], m.lhs .. " is mapped once")
      seen[m.lhs] = m
    end
    return seen
  end

  it("both keys are buffer-local normal-mode maps with a description :SageFsHelp can show", function()
    local seen = by_lhs(capture_keymaps())
    local up = seen[config.SCRUB_UP_KEY]
    local down = seen[config.SCRUB_DOWN_KEY]
    assert.is_truthy(up, config.SCRUB_UP_KEY .. " is mapped")
    assert.is_truthy(down, config.SCRUB_DOWN_KEY .. " is mapped")
    assert.are.equal("n", up.mode)
    assert.are.equal("n", down.mode)
    assert.are.equal(7, up.opts.buffer, "buffer-local, like every other SageFs map")
    assert.are.equal(7, down.opts.buffer)
    assert.is_truthy(up.opts.desc and up.opts.desc ~= "", "the map says what it does")
    assert.is_truthy(up.opts.desc:find("scrub", 1, true), up.opts.desc)
    assert.is_truthy(seen["<leader>rk+"], "the original bump maps are still there")
  end)

  it("the defaults are Alt-k up and Alt-j down: unmapped in a vanilla Neovim, j/k for the direction", function()
    assert.are.equal("<A-k>", config.SCRUB_UP_KEY)
    assert.are.equal("<A-j>", config.SCRUB_DOWN_KEY)
    assert.are_not.equal(config.SCRUB_UP_KEY, config.SCRUB_DOWN_KEY)
    -- Neither is (or may become) under the <leader>rk namespace, which is a
    -- key sequence: holding its last key would not repeat the map, so the
    -- scrub keys must be single keys of their own.
    assert.is_falsy(config.SCRUB_UP_KEY:find("^<leader>"))
    assert.is_falsy(config.SCRUB_DOWN_KEY:find("^<leader>"))
  end)

  it("remapping: changing config before an F# buffer attaches changes what is mapped", function()
    local prev_up, prev_down = config.SCRUB_UP_KEY, config.SCRUB_DOWN_KEY
    config.SCRUB_UP_KEY, config.SCRUB_DOWN_KEY = "<A-P>", "<A-N>"
    local seen = by_lhs(capture_keymaps())
    config.SCRUB_UP_KEY, config.SCRUB_DOWN_KEY = prev_up, prev_down

    assert.is_truthy(seen["<A-P>"], "the key it was changed to is mapped")
    assert.is_truthy(seen["<A-N>"])
    assert.is_falsy(seen[prev_up], "the old default is gone while the config says so")
    assert.is_falsy(seen[prev_down])
  end)

  it("no other part of the plugin maps the scrub keys", function()
    local src = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
    for _, name in ipairs({ "commands.lua", "init.lua", "coverage_hover.lua", "debug_test_ui.lua",
      "bindings_view.lua", "wire_testing.lua" }) do
      local f = io.open(src .. "../lua/sagefs/" .. name, "rb")
      if f then
        local text = f:read("*a")
        f:close()
        assert.is_falsy(text:find('"<A-k>', 1, true), name .. " must not map <A-k>")
        assert.is_falsy(text:find('"<A-j>', 1, true), name .. " must not map <A-j>")
      end
    end
  end)
end)
