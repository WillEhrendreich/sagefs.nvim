-- Tests: the editor-facing side of debugging a failing test: which test does
-- :SageFsDebugTest mean, the "debug" hint drawn on a failing-test line, and the
-- command and keymap registration. The lifecycle itself is in debug_test_spec.lua.
require("spec.helper")

local ui = require("sagefs.debug_test_ui")
local annotations = require("sagefs.annotations")
local testing = require("sagefs.testing")

local FILE = "/tmp/lem/tour-live-testing-passing-04/w/DemoEnv.Tests/DemoEnvTests.fs"

local function annotation_state()
  local src = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
  local f = assert(io.open(src .. "fixtures/wire/file_annotations_demoenv_tests.json", "rb"))
  local text = f:read("*a")
  f:close()
  local _, data = require("sagefs.util").json_decode(text)
  return annotations.handle_file_annotations(annotations.new(), data)
end

describe("debug_test_ui.resolve_target", function()
  local state = testing.new()
  testing.update_test(state, {
    testId = "KNOWNID", displayName = "adds", fullName = "Suite.adds", status = "Failed",
    origin = { Case = "SourceMapped", Fields = { "/x/Other.fs", 3 } },
  })

  it("a bare argument that is a known test id debugs that test by id", function()
    local r = ui.resolve_target({ args = "KNOWNID", testing_state = state, annotations_state = annotation_state(), file = FILE, line = 1 })
    assert.are.equal("start", r.kind)
    assert.are.same({ test_id = "KNOWNID" }, r.target)
  end)

  it("any other argument is a name pattern", function()
    local r = ui.resolve_target({ args = "negative integer", testing_state = state, annotations_state = annotation_state(), file = FILE, line = 1 })
    assert.are.equal("start", r.kind)
    assert.are.same({ pattern = "negative integer" }, r.target)
  end)

  it("with no argument, debugs the failing test on the cursor line", function()
    local r = ui.resolve_target({ args = "", testing_state = testing.new(), annotations_state = annotation_state(), file = FILE, line = 8 })
    assert.are.equal("start", r.kind)
    assert.are.same({ test_id = "D39C4D7B318839A9" }, r.target)
    assert.are.equal("a negative integer yields None", r.name)
  end)

  it("off the marker, the file's only failing test is offered by name, never started unasked", function()
    local r = ui.resolve_target({ args = "", testing_state = testing.new(), annotations_state = annotation_state(), file = FILE, line = 20 })
    assert.are.equal("confirm", r.kind)
    assert.are.same({ test_id = "D39C4D7B318839A9" }, r.target)
    assert.are.equal("a negative integer yields None", r.name)
    assert.are.equal(8, r.line)
    assert.is_truthy(r.message:find("No failing test on this line", 1, true))
    assert.is_truthy(r.message:find("a negative integer yields None", 1, true))
  end)

  it("an explicit argument never asks: it names the test itself", function()
    local r = ui.resolve_target({ args = "negative integer", testing_state = testing.new(), annotations_state = annotation_state(), file = FILE, line = 20 })
    assert.are.equal("start", r.kind)
  end)

  it("asks which one when several tests fail on the line", function()
    local s = testing.new()
    testing.update_test(s, {
      testId = "OTHER", displayName = "also bad", fullName = "y", status = "Failed",
      origin = { Case = "SourceMapped", Fields = { FILE, 8 } },
    })
    local r = ui.resolve_target({ args = "", testing_state = s, annotations_state = annotation_state(), file = FILE, line = 8 })
    assert.are.equal("choose", r.kind)
    assert.are.equal(2, #r.choices)
  end)

  it("says what to do when nothing fails here", function()
    local r = ui.resolve_target({ args = "", testing_state = testing.new(), annotations_state = annotations.new(), file = FILE, line = 8 })
    assert.are.equal("none", r.kind)
    assert.is_truthy(r.message:find("SageFsDebugTest <name>", 1, true))
  end)
end)

describe("debug_test_ui.run, off the failing line", function()
  local function plugin_for_file()
    return { testing_state = testing.new(), annotations_state = annotation_state() }
  end

  local function run_with(choice_index)
    local started, notes, prompts = {}, {}, {}
    ui.run(plugin_for_file(), { notify = function(msg) table.insert(notes, msg) end }, "", {
      buf = 1, file = FILE, line = 20,
      start = function(target) table.insert(started, target) end,
      select = function(items, opts, cb)
        table.insert(prompts, { items = items, prompt = opts.prompt })
        cb(choice_index and items[choice_index] or nil)
      end,
    })
    return started, notes, prompts
  end

  it("names the test and asks before starting it", function()
    local started, _, prompts = run_with(nil)
    assert.are.equal(1, #prompts)
    assert.is_truthy(prompts[1].prompt:find("a negative integer yields None", 1, true))
    assert.are.equal(0, #started, "nothing starts until you say yes")
  end)

  it("starts it when you confirm", function()
    local started = run_with(1)
    assert.are.same({ { test_id = "D39C4D7B318839A9" } }, started)
  end)

  it("does not start it when you decline", function()
    local started = run_with(2)
    assert.are.equal(0, #started)
  end)
end)

describe("debug_test_ui hint", function()
  it("draws a right-aligned debug hint, quiet, with the keymap", function()
    local spec = ui.hint_extmark(1, "<leader>")
    assert.are.equal("right_align", spec.virt_text_pos)
    local text = spec.virt_text[1][1]
    assert.is_truthy(text:find("debug", 1, true))
    assert.is_truthy(text:find("<leader>rtg", 1, true))
    assert.are.equal("SageFsDebugHint", spec.virt_text[1][2])
  end)

  it("counts when several fail on one line", function()
    local text = ui.hint_extmark(3, "<leader>").virt_text[1][1]
    assert.is_truthy(text:find("3", 1, true))
  end)

  it("draws no hint when the density turned code lens style marks off, and clears old ones", function()
    local calls = { clear = 0, set = 0 }
    local api = {
      nvim_buf_get_name = function() return FILE end,
      nvim_create_namespace = function() return 99 end,
      nvim_buf_line_count = function() return 60 end,
      nvim_buf_clear_namespace = function() calls.clear = calls.clear + 1 end,
      nvim_buf_set_extmark = function() calls.set = calls.set + 1 end,
    }
    ui.render_hints(5, testing.new(), annotation_state(), { api = api, leader = "<leader>", density = { codelens = false } })
    assert.are.equal(1, calls.clear)
    assert.are.equal(0, calls.set)
  end)

  it("renders one extmark per failing line and clears the old ones first", function()
    local calls = { clear = 0, set = {} }
    local api = {
      nvim_buf_get_name = function() return FILE end,
      nvim_create_namespace = function() return 99 end,
      nvim_buf_line_count = function() return 60 end,
      nvim_buf_clear_namespace = function() calls.clear = calls.clear + 1 end,
      nvim_buf_set_extmark = function(_, ns, line, col, opts)
        table.insert(calls.set, { ns = ns, line = line, opts = opts })
      end,
    }
    ui.render_hints(5, testing.new(), annotation_state(), { api = api, leader = "<leader>" })
    assert.are.equal(1, calls.clear)
    assert.are.equal(1, #calls.set)
    assert.are.equal(7, calls.set[1].line, "0-based line for source line 8")
  end)

  it("clears and draws nothing for an unnamed buffer", function()
    local calls = { clear = 0, set = 0 }
    local api = {
      nvim_buf_get_name = function() return "" end,
      nvim_create_namespace = function() return 99 end,
      nvim_buf_line_count = function() return 60 end,
      nvim_buf_clear_namespace = function() calls.clear = calls.clear + 1 end,
      nvim_buf_set_extmark = function() calls.set = calls.set + 1 end,
    }
    ui.render_hints(5, testing.new(), annotation_state(), { api = api })
    assert.are.equal(1, calls.clear)
    assert.are.equal(0, calls.set)
  end)
end)

describe("debug_test_ui registration", function()
  it("registers :SageFsDebugTest and :SageFsDebugRelease", function()
    local registered = {}
    ui.register_commands({}, { notify = function() end, base_url = function() return "" end },
      function(name, handler, opts) registered[name] = { handler = handler, opts = opts } end)
    assert.is_truthy(registered.SageFsDebugTest)
    assert.are.equal("?", registered.SageFsDebugTest.opts.nargs)
    assert.is_truthy(registered.SageFsDebugRelease)
  end)

  it("maps <leader>rtg on the buffer", function()
    local mapped = {}
    local prev = vim.keymap
    vim.keymap = { set = function(mode, lhs, rhs, opts) table.insert(mapped, { mode = mode, lhs = lhs, opts = opts }) end }
    ui.register_keymaps({}, { notify = function() end }, 12)
    vim.keymap = prev
    assert.are.equal(1, #mapped)
    assert.are.equal("<leader>rtg", mapped[1].lhs)
    assert.are.equal(12, mapped[1].opts.buffer)
  end)

  it("the key is one nobody else maps, and not one shifted letter from disabling live testing", function()
    local src = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
    local count = 0
    for _, name in ipairs({ "commands.lua", "coverage_hover.lua", "debug_test_ui.lua", "init.lua", "bindings_view.lua" }) do
      local f = io.open(src .. "../lua/sagefs/" .. name, "rb")
      if f then
        local text = f:read("*a")
        f:close()
        for _ in text:gmatch('"<leader>rtg"') do count = count + 1 end
      end
    end
    assert.are.equal(1, count, "<leader>rtg is defined exactly once across the plugin")
    assert.are_not.equal("<leader>rtD", ui.KEY, "rtD is one shifted letter from rtd, which disables live testing")
  end)

  it(":SageFsDebugRelease says so when nothing is open", function()
    local notes = {}
    local registered = {}
    ui.register_commands({}, { notify = function(msg) table.insert(notes, msg) end, base_url = function() return "" end },
      function(name, handler) registered[name] = handler end)
    require("sagefs.debug_test")._reset()
    registered.SageFsDebugRelease()
    assert.is_truthy(notes[1]:find("nothing", 1, true))
  end)
end)

describe("debug_test_ui.run_for_entry, the test panel row", function()
  it("starts the test the row names, by id, tied to no buffer", function()
    local started, notes = {}, {}
    ui.run_for_entry({}, { notify = function(msg) table.insert(notes, msg) end },
      { testId = "ROWID", displayName = "adds" },
      { start = function(target, bufnr) table.insert(started, { target = target, bufnr = bufnr }) end })
    assert.are.equal(1, #started)
    assert.are.same({ test_id = "ROWID" }, started[1].target)
    assert.is_nil(started[1].bufnr, "the panel's scratch buffer must not be what ends the hold when it closes")
    assert.are.equal(0, #notes)
  end)

  it("says what to do on a row that is not a test (a header or a blank line)", function()
    local started, notes = {}, {}
    ui.run_for_entry({}, { notify = function(msg) table.insert(notes, msg) end }, { text = "== Tests ==" },
      { start = function(target) table.insert(started, target) end })
    assert.are.equal(0, #started)
    assert.is_truthy(notes[1]:find("test row", 1, true))
    ui.run_for_entry({}, { notify = function(msg) table.insert(notes, msg) end }, nil,
      { start = function(target) table.insert(started, target) end })
    assert.are.equal(0, #started)
    assert.are.equal(2, #notes)
  end)

  it("the panel key is one the panel does not use already", function()
    assert.are.equal("g", ui.PANEL_KEY)
    for _, taken in ipairs({ "f", "m", "a", "b", "<Tab>", "<CR>", "<C-d>" }) do
      assert.are_not.equal(taken, ui.PANEL_KEY)
    end
  end)
end)
