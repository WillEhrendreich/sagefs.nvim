-- spec/treesitter_cells_spec.lua — Tree-sitter cell detection integration tests
-- Requires: nvim --headless (tree-sitter API needs Neovim runtime)
-- Run via: nvim --headless -l spec/treesitter_cells_harness.lua
--
-- These tests load F# fixture files into scratch buffers and verify that
-- treesitter_cells.find_all_cells and find_enclosing_cell produce correct
-- cell boundaries. Uses the Neovim-installed tree-sitter-fsharp grammar.

-- ─── Minimal harness (no busted, runs inside nvim --headless) ───────────────

-- Guard: skip entirely when loaded by busted (no Neovim runtime)
if not vim or not vim.opt then return end

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
local plugin_root = script_dir .. ".."
vim.opt.rtp:prepend(plugin_root)
package.path = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;" .. package.path

local passed = 0
local failed = 0
local errors = {}
local current_suite = ""

local function describe(name, fn)
  local prev = current_suite
  current_suite = current_suite ~= "" and (current_suite .. " > " .. name) or name
  fn()
  current_suite = prev
end

local function it(name, fn)
  local label = current_suite ~= "" and (current_suite .. " > " .. name) or name
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write("  ✓ " .. label .. "\n")
  else
    failed = failed + 1
    table.insert(errors, { label = label, err = tostring(err) })
    io.write("  ✖ " .. label .. "\n")
    io.write("    " .. tostring(err) .. "\n")
  end
end

local function assert_eq(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s",
      msg or "assertion failed", tostring(expected), tostring(actual)), 2)
  end
end

local function assert_truthy(val, msg)
  if not val then
    error(msg or "expected truthy value, got " .. tostring(val), 2)
  end
end

-- ─── Helper: load fixture into buffer ────────────────────────────────────────

local fixture_dir = script_dir .. "../fixtures/"

local function load_fixture(name)
  local path = fixture_dir .. name
  local lines = vim.fn.readfile(path)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("filetype", "fsharp", { buf = buf })
  return buf, lines
end

-- ─── Load module under test ──────────────────────────────────────────────────

local ts_cells = require("sagefs.treesitter_cells")

-- ─── Tests: basic_bindings.fs ─────────────────────────────────────────────────

describe("treesitter_cells: basic_bindings.fs", function()
  local buf, lines = load_fixture("basic_bindings.fs")

  describe("find_all_cells", function()
    local cells = ts_cells.find_all_cells(buf)

    it("detects 7 cells", function()
      assert_eq(7, #cells, "cell count")
    end)

    it("cell 1: add (line 3)", function()
      assert_eq(3, cells[1].start_line, "start")
      assert_eq(3, cells[1].end_line, "end")
      assert_eq("declaration_expression", cells[1].node_type, "type")
    end)

    it("cell 2: multiply (line 5)", function()
      assert_eq(5, cells[2].start_line, "start")
      assert_eq(5, cells[2].end_line, "end")
    end)

    it("cell 3: greeting (lines 7-8)", function()
      assert_eq(7, cells[3].start_line, "start")
      assert_eq(8, cells[3].end_line, "end")
    end)

    it("cell 4: factorial (lines 10-12)", function()
      assert_eq(10, cells[4].start_line, "start")
      assert_eq(12, cells[4].end_line, "end")
    end)

    it("cell 5: Point type (line 14)", function()
      assert_eq(14, cells[5].start_line, "start")
      assert_eq(14, cells[5].end_line, "end")
      assert_eq("type_definition", cells[5].node_type, "type")
    end)

    it("cell 6: Shape DU (lines 16-18)", function()
      assert_eq(16, cells[6].start_line, "start")
      assert_eq(18, cells[6].end_line, "end")
      assert_eq("type_definition", cells[6].node_type, "type")
    end)

    it("cell 7: area function (lines 20-23)", function()
      assert_eq(20, cells[7].start_line, "start")
      assert_eq(23, cells[7].end_line, "end")
    end)

    it("no cells overlap", function()
      for i = 2, #cells do
        assert_truthy(cells[i].start_line > cells[i-1].end_line,
          string.format("cell %d starts at %d but cell %d ends at %d",
            i, cells[i].start_line, i-1, cells[i-1].end_line))
      end
    end)
  end)

  describe("find_enclosing_cell", function()
    it("cursor on 'add' (line 3) returns the add cell", function()
      local cell = ts_cells.find_enclosing_cell(buf, 3)
      assert_truthy(cell, "should find cell")
      assert_eq(3, cell.start_line, "start")
      assert_eq(3, cell.end_line, "end")
    end)

    it("cursor inside factorial body (line 11) returns the whole factorial", function()
      local cell = ts_cells.find_enclosing_cell(buf, 11)
      assert_truthy(cell, "should find cell")
      assert_eq(10, cell.start_line, "start")
      assert_eq(12, cell.end_line, "end")
    end)

    it("cursor inside match (line 22) returns the area function", function()
      local cell = ts_cells.find_enclosing_cell(buf, 22)
      assert_truthy(cell, "should find cell")
      assert_eq(20, cell.start_line, "start")
      assert_eq(23, cell.end_line, "end")
    end)
  end)

  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ─── Tests: complex_expressions.fs ──────────────────────────────────────────

describe("treesitter_cells: complex_expressions.fs", function()
  local buf, lines = load_fixture("complex_expressions.fs")

  describe("find_all_cells", function()
    local cells = ts_cells.find_all_cells(buf)

    it("detects 4 cells", function()
      assert_eq(4, #cells, "cell count")
    end)

    it("cell 1: classify with match (lines 5-11)", function()
      assert_eq(5, cells[1].start_line, "start")
      assert_eq(11, cells[1].end_line, "end")
    end)

    it("cell 2: processAsync with async CE (lines 13-18)", function()
      assert_eq(13, cells[2].start_line, "start")
      assert_eq(18, cells[2].end_line, "end")
    end)

    it("cell 3: generateSequence with seq CE (lines 20-27)", function()
      assert_eq(20, cells[3].start_line, "start")
      assert_eq(27, cells[3].end_line, "end")
    end)

    it("cell 4: nestedMatch (lines 29-38)", function()
      assert_eq(29, cells[4].start_line, "start")
      assert_eq(38, cells[4].end_line, "end")
    end)

    it("no cells overlap", function()
      for i = 2, #cells do
        assert_truthy(cells[i].start_line > cells[i-1].end_line,
          string.format("cell %d starts at %d but cell %d ends at %d",
            i, cells[i].start_line, i-1, cells[i-1].end_line))
      end
    end)
  end)

  describe("find_enclosing_cell", function()
    it("cursor deep inside match arm (line 9) returns classify", function()
      local cell = ts_cells.find_enclosing_cell(buf, 9)
      assert_truthy(cell, "should find cell")
      assert_eq(5, cell.start_line, "start")
      assert_eq(11, cell.end_line, "end")
    end)

    it("cursor inside async CE (line 15) returns processAsync", function()
      local cell = ts_cells.find_enclosing_cell(buf, 15)
      assert_truthy(cell, "should find cell")
      assert_eq(13, cell.start_line, "start")
      assert_eq(18, cell.end_line, "end")
    end)

    it("cursor inside nested match (line 33) returns nestedMatch", function()
      local cell = ts_cells.find_enclosing_cell(buf, 33)
      assert_truthy(cell, "should find cell")
      assert_eq(29, cell.start_line, "start")
      assert_eq(38, cell.end_line, "end")
    end)
  end)

  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ─── Tests: nested_modules.fs ───────────────────────────────────────────────

describe("treesitter_cells: nested_modules.fs", function()
  local buf, lines = load_fixture("nested_modules.fs")

  describe("find_all_cells", function()
    local cells = ts_cells.find_all_cells(buf)

    it("detects 7 cells across nested modules", function()
      assert_eq(7, #cells, "cell count")
    end)

    it("cell 1: outerValue (line 4)", function()
      assert_eq(4, cells[1].start_line, "start")
      assert_eq(4, cells[1].end_line, "end")
    end)

    it("cell 2: innerValue (line 7, inside Inner module)", function()
      assert_eq(7, cells[2].start_line, "start")
      assert_eq(7, cells[2].end_line, "end")
    end)

    it("cell 3: innerFunction (line 9)", function()
      assert_eq(9, cells[3].start_line, "start")
      assert_eq(9, cells[3].end_line, "end")
    end)

    it("cell 4: useInner (line 11)", function()
      assert_eq(11, cells[4].start_line, "start")
      assert_eq(11, cells[4].end_line, "end")
    end)

    it("cell 5: Status DU in Standalone (lines 16-18)", function()
      assert_eq(16, cells[5].start_line, "start")
      assert_eq(18, cells[5].end_line, "end")
    end)

    it("cell 6: isActive in Standalone (lines 20-23)", function()
      assert_eq(20, cells[6].start_line, "start")
      assert_eq(23, cells[6].end_line, "end")
    end)

    it("cell 7: toggle in Standalone (lines 25-28)", function()
      assert_eq(25, cells[7].start_line, "start")
      assert_eq(28, cells[7].end_line, "end")
    end)

    it("no cells overlap", function()
      for i = 2, #cells do
        assert_truthy(cells[i].start_line > cells[i-1].end_line,
          string.format("cell %d starts at %d but cell %d ends at %d",
            i, cells[i].start_line, i-1, cells[i-1].end_line))
      end
    end)
  end)

  describe("find_enclosing_cell", function()
    it("cursor on innerFunction (line 9) returns inner cell not outer module", function()
      local cell = ts_cells.find_enclosing_cell(buf, 9)
      assert_truthy(cell, "should find cell")
      assert_eq(9, cell.start_line, "start")
      assert_eq(9, cell.end_line, "end")
    end)

    it("cursor inside Standalone match (line 22) returns isActive", function()
      local cell = ts_cells.find_enclosing_cell(buf, 22)
      assert_truthy(cell, "should find cell")
      assert_eq(20, cell.start_line, "start")
      assert_eq(23, cell.end_line, "end")
    end)
  end)

  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ─── Tests: attributed_and_typed.fs ─────────────────────────────────────────

describe("treesitter_cells: attributed_and_typed.fs", function()
  local buf, lines = load_fixture("attributed_and_typed.fs")

  describe("find_all_cells", function()
    local cells = ts_cells.find_all_cells(buf)

    it("detects 7 cells", function()
      assert_eq(7, #cells, "cell count")
    end)

    it("cell 1: [<Literal>] let MaxRetries (lines 5-6)", function()
      assert_eq(5, cells[1].start_line, "start")
      assert_eq(6, cells[1].end_line, "end")
      assert_eq("declaration_expression", cells[1].node_type, "type")
    end)

    it("cell 2: [<Obsolete>] let oldFunction (lines 8-9)", function()
      assert_eq(8, cells[2].start_line, "start")
      assert_eq(9, cells[2].end_line, "end")
    end)

    it("cell 3: Config record (lines 11-15)", function()
      assert_eq(11, cells[3].start_line, "start")
      assert_eq(15, cells[3].end_line, "end")
      assert_eq("type_definition", cells[3].node_type, "type")
    end)

    it("cell 4: Status DU (lines 17-20)", function()
      assert_eq(17, cells[4].start_line, "start")
      assert_eq(20, cells[4].end_line, "end")
    end)

    it("cell 5: let rec isEven and isOdd (lines 22-23)", function()
      assert_eq(22, cells[5].start_line, "start")
      assert_eq(23, cells[5].end_line, "end")
    end)

    it("cell 6: IValidator interface (lines 25-26)", function()
      assert_eq(25, cells[6].start_line, "start")
      assert_eq(26, cells[6].end_line, "end")
    end)

    it("cell 7: defaultConfig (lines 28-32)", function()
      assert_eq(28, cells[7].start_line, "start")
      assert_eq(32, cells[7].end_line, "end")
    end)

    it("no cells overlap", function()
      for i = 2, #cells do
        assert_truthy(cells[i].start_line > cells[i-1].end_line,
          string.format("cell %d starts at %d but cell %d ends at %d",
            i, cells[i].start_line, i-1, cells[i-1].end_line))
      end
    end)
  end)

  describe("find_enclosing_cell", function()
    it("cursor on attribute line (5) returns attributed binding", function()
      local cell = ts_cells.find_enclosing_cell(buf, 5)
      assert_truthy(cell, "should find cell")
      assert_eq(5, cell.start_line, "start includes attribute")
      assert_eq(6, cell.end_line, "end")
    end)

    it("cursor inside record field (13) returns Config type", function()
      local cell = ts_cells.find_enclosing_cell(buf, 13)
      assert_truthy(cell, "should find cell")
      assert_eq(11, cell.start_line, "start")
      assert_eq(15, cell.end_line, "end")
    end)

    it("cursor on isOdd (23) returns the whole let rec...and", function()
      local cell = ts_cells.find_enclosing_cell(buf, 23)
      assert_truthy(cell, "should find cell")
      assert_eq(22, cell.start_line, "start")
      assert_eq(23, cell.end_line, "end")
    end)
  end)

  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ─── Results ────────────────────────────────────────────────────────────────

io.write("\n")
io.write(string.format("treesitter_cells: %d passed, %d failed\n", passed, failed))
if #errors > 0 then
  io.write("\nFailures:\n")
  for _, e in ipairs(errors) do
    io.write("  " .. e.label .. "\n")
    io.write("    " .. e.err .. "\n")
  end
end

vim.cmd("qa" .. (failed > 0 and "!" or ""))
