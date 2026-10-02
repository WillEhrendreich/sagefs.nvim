-- Tests: the covering-tests float (sagefs.coverage_hover): which tests cover the
-- line under the cursor, their last result, a way to jump to one, and the
-- per-symbol badge drawn from coverage_view. Formatting and decisions are pure;
-- the buffer and window code is exercised in headless Neovim.
require("spec.helper")

local ch = require("sagefs.coverage_hover")
local coverage = require("sagefs.coverage")
local testing = require("sagefs.testing")
local annotations = require("sagefs.annotations")
local util = require("sagefs.util")

local FILE = "/tmp/lem/tour-live-testing-passing-04/w/DemoEnv.Tests/DemoEnvTests.fs"

local function fixture(name)
  local src = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
  local f = assert(io.open(src .. "fixtures/wire/" .. name, "rb"))
  local text = f:read("*a")
  f:close()
  local ok, data = util.json_decode(text)
  assert(ok, "fixture " .. name .. " did not decode")
  return data
end

local function tests_state()
  local state = testing.new()
  local function add(id, name, status, file, line)
    testing.update_test(state, { testId = id, displayName = name, fullName = name, status = status,
      origin = { Case = "SourceMapped", Fields = { file, line } } })
  end
  add("47DE23FB95057848", "garbage yields None", "Passed", FILE, 8)
  add("7638D0E81B145CA1", "unset (None) yields None", "Failed", FILE, 8)
  return state
end

local function info_at(line)
  return coverage.covering_info(fixture("file_annotations_covering_synthetic.json"), line, tests_state())
end

describe("coverage_hover.format_float", function()
  it("heads the float with the line and how many tests cover it", function()
    local f = ch.format_float(info_at(11))
    assert.is_truthy(f.lines[1]:find("Line 11", 1, true))
    assert.is_truthy(f.lines[1]:find("2 tests cover this", 1, true))
  end)

  it("lists each test by name with its last result", function()
    local f = ch.format_float(info_at(11))
    local text = table.concat(f.lines, "\n")
    assert.is_truthy(text:find("garbage yields None", 1, true))
    assert.is_truthy(text:find("Passed", 1, true))
    assert.is_truthy(text:find("unset (None) yields None", 1, true))
    assert.is_truthy(text:find("Failed", 1, true))
  end)

  it("maps each test row to its test so <CR> can jump", function()
    local f = ch.format_float(info_at(11))
    local rows = {}
    for lnum, test in pairs(f.rows) do rows[test.test_id] = lnum end
    assert.is_truthy(rows["47DE23FB95057848"])
    assert.is_truthy(rows["7638D0E81B145CA1"])
    assert.is_nil(f.rows[1], "the header is not a test")
  end)

  it("says one test covers this when exactly one does", function()
    local f = ch.format_float(info_at(12))
    assert.is_truthy(f.lines[1]:find("1 test covers this", 1, true))
  end)

  it("a test with no result says no result, never a guess", function()
    local f = ch.format_float(info_at(36))
    assert.is_truthy(table.concat(f.lines, "\n"):find("no result", 1, true))
  end)

  it("a line no test covers says so and offers nothing to jump to", function()
    local f = ch.format_float(info_at(9))
    assert.is_truthy(f.lines[1]:find("no test covers", 1, true))
    assert.is_nil(next(f.rows))
  end)

  it("a covered line with no per-test reading says so instead of claiming no test covers it (the real payload)", function()
    local real = coverage.covering_info(fixture("file_annotations_demoenv_tests.json"), 11, tests_state())
    local f = ch.format_float(real)
    assert.is_truthy(f.lines[1]:find("covered, but the daemon has no per-test reading", 1, true))
    assert.is_nil(next(f.rows))
  end)

  it("a title names the span when the annotation covers several lines", function()
    local f = ch.format_float(info_at(37))
    assert.is_truthy(f.title:find("36", 1, true))
    assert.is_truthy(f.title:find("38", 1, true))
  end)
end)

describe("coverage_hover.resolve_jump", function()
  it("is the test's mapped file and line", function()
    local target = ch.resolve_jump({ test_id = "47DE23FB95057848", name = "garbage yields None" }, tests_state())
    assert.are.equal(FILE, target.file)
    assert.are.equal(8, target.line)
  end)

  it("says why when the test has no known location yet", function()
    local target = ch.resolve_jump({ test_id = "NOPE", name = "nothing" }, testing.new())
    assert.is_nil(target.file)
    assert.is_truthy(target.message:find("no source location", 1, true))
  end)
end)

describe("coverage_hover.cover_info_at", function()
  it("finds the file's annotations in the plugin state and answers for the line", function()
    local ann_state = annotations.handle_file_annotations(annotations.new(), fixture("file_annotations_covering_synthetic.json"))
    local info, why = ch.cover_info_at({ annotations_state = ann_state, testing_state = tests_state() }, FILE, 11)
    assert.is_truthy(info)
    assert.is_nil(why)
  end)

  it("explains an empty answer: no annotations for the file", function()
    local info, why = ch.cover_info_at({ annotations_state = annotations.new(), testing_state = tests_state() }, FILE, 11)
    assert.is_nil(info)
    assert.is_truthy(why:find("live testing", 1, true))
  end)

  it("explains an empty answer: the line is not part of any annotation", function()
    local ann_state = annotations.handle_file_annotations(annotations.new(), fixture("file_annotations_covering_synthetic.json"))
    local info, why = ch.cover_info_at({ annotations_state = ann_state, testing_state = tests_state() }, FILE, 400)
    assert.is_nil(info)
    assert.is_truthy(why:find("400", 1, true))
  end)
end)

describe("coverage_hover badge", function()
  local function view(overrides)
    local v = { SessionId = "s1", Generation = 4, Symbol = "Mod.add", FilePath = FILE, DefinitionLine = 10,
      TotalCount = 3, Overflow = { Case = "Within" }, InlineBadgeText = "✓ 3", Health = { Case = "Passing" } }
    for k, val in pairs(overrides or {}) do v[k] = val end
    return v
  end

  it("draws the daemon's one-line text at the end of the definition line, colored by health", function()
    local state = coverage.apply_coverage_view(coverage.new(), view())
    local spec = ch.badge_extmark(coverage.views_for_file(state, FILE)[1])
    assert.are.equal("eol", spec.virt_text_pos)
    assert.is_truthy(spec.virt_text[1][1]:find("✓ 3", 1, true))
    assert.are.equal("SageFsCoverageViewPassing", spec.virt_text[1][2])
    local failing = coverage.apply_coverage_view(coverage.new(), view({ Health = { Case = "Failing" }, InlineBadgeText = "✓ 2 ✗ 1" }))
    assert.are.equal("SageFsCoverageViewFailing", ch.badge_extmark(coverage.views_for_file(failing, FILE)[1]).virt_text[1][2])
  end)

  it("draws nothing for a view with no covering tests", function()
    local state = coverage.apply_coverage_view(coverage.new(), view({ TotalCount = 0, InlineBadgeText = "", Health = { Case = "Absent" } }))
    assert.is_nil(ch.badge_extmark(coverage.views_for_file(state, FILE)[1]))
  end)

  it("renders one extmark per visible view and clears the old ones first", function()
    local calls = { clear = 0, set = {} }
    local api = {
      nvim_buf_get_name = function() return FILE end,
      nvim_create_namespace = function() return 7 end,
      nvim_buf_line_count = function() return 60 end,
      nvim_buf_clear_namespace = function() calls.clear = calls.clear + 1 end,
      nvim_buf_set_extmark = function(_, _, line, _, opts) table.insert(calls.set, { line = line, opts = opts }) end,
    }
    local state = coverage.new()
    state = coverage.apply_coverage_view(state, view({ Symbol = "a", DefinitionLine = 10 }))
    state = coverage.apply_coverage_view(state, view({ Symbol = "b", DefinitionLine = 20, TotalCount = 0, InlineBadgeText = "", Health = { Case = "Absent" } }))
    state = coverage.apply_coverage_view(state, view({ Symbol = "c", DefinitionLine = 500 }))
    ch.render_badges(3, state, { api = api })
    assert.are.equal(1, calls.clear)
    assert.are.equal(1, #calls.set, "the absent one and the one past the end of the buffer draw nothing")
    assert.are.equal(9, calls.set[1].line)
  end)

  it("draws only the active session's badges", function()
    local set = 0
    local api = {
      nvim_buf_get_name = function() return FILE end,
      nvim_create_namespace = function() return 7 end,
      nvim_buf_line_count = function() return 60 end,
      nvim_buf_clear_namespace = function() end,
      nvim_buf_set_extmark = function() set = set + 1 end,
    }
    local state = coverage.apply_coverage_view(coverage.new(), view({ SessionId = "A", Generation = 40 }))
    ch.render_badges(3, state, { api = api, session_id = "B" })
    assert.are.equal(0, set, "session A's badges stay off the screen after switching to B")
    ch.render_badges(3, state, { api = api, session_id = "A" })
    assert.are.equal(1, set)
  end)

  it("draws nothing when the density turned code lens style marks off", function()
    local calls = { set = 0 }
    local api = {
      nvim_buf_get_name = function() return FILE end,
      nvim_create_namespace = function() return 7 end,
      nvim_buf_line_count = function() return 60 end,
      nvim_buf_clear_namespace = function() end,
      nvim_buf_set_extmark = function() calls.set = calls.set + 1 end,
    }
    local state = coverage.apply_coverage_view(coverage.new(), view())
    ch.render_badges(3, state, { api = api, density = { codelens = false } })
    assert.are.equal(0, calls.set)
  end)
end)

describe("coverage_hover registration", function()
  it("registers :SageFsCoveringTests", function()
    local registered = {}
    ch.register_commands({}, { notify = function() end }, function(name, handler, opts) registered[name] = { handler = handler, opts = opts } end)
    assert.is_truthy(registered.SageFsCoveringTests)
  end)

  it("maps <leader>rtc on the buffer", function()
    local mapped = {}
    local prev = vim.keymap
    vim.keymap = { set = function(mode, lhs, rhs, opts) table.insert(mapped, { lhs = lhs, opts = opts }) end }
    ch.register_keymaps({}, { notify = function() end }, 9)
    vim.keymap = prev
    assert.are.equal("<leader>rtc", mapped[1].lhs)
    assert.are.equal(9, mapped[1].opts.buffer)
  end)

  it("show() tells you what is missing instead of opening an empty float", function()
    local notes = {}
    ch.show({ annotations_state = annotations.new(), testing_state = testing.new() },
      { notify = function(msg) table.insert(notes, msg) end },
      { file = FILE, line = 11, open_float = function() error("must not open") end })
    assert.are.equal(1, #notes)
    assert.is_truthy(notes[1]:find("live testing", 1, true))
  end)

  it("show() opens the float with the formatted lines when there is something to say", function()
    local opened
    local ann_state = annotations.handle_file_annotations(annotations.new(), fixture("file_annotations_covering_synthetic.json"))
    ch.show({ annotations_state = ann_state, testing_state = tests_state() }, { notify = function() end },
      { file = FILE, line = 11, open_float = function(f, jump) opened = { f = f, jump = jump } end })
    assert.is_truthy(opened)
    assert.is_truthy(opened.f.lines[1]:find("2 tests cover this", 1, true))
  end)

  it("the jump callback opens the test's file at its line", function()
    local went
    local ann_state = annotations.handle_file_annotations(annotations.new(), fixture("file_annotations_covering_synthetic.json"))
    local opened
    ch.show({ annotations_state = ann_state, testing_state = tests_state() }, { notify = function() end },
      { file = FILE, line = 11, open_float = function(f, jump) opened = { f = f, jump = jump } end,
        goto_location = function(file, line) went = { file = file, line = line } end })
    local lnum
    for l, test in pairs(opened.f.rows) do if test.test_id == "47DE23FB95057848" then lnum = l end end
    opened.jump(opened.f.rows[lnum])
    assert.are.same({ file = FILE, line = 8 }, went)
  end)
end)
