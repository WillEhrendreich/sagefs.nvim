-- =============================================================================
-- Cell Parsing Tests — sagefs/cells.lua
-- =============================================================================
-- Expert panel test plan:
--
-- **DeVries**: Cells are the atomic unit. Get this right and everything else
--   flows. Test every boundary condition — off-by-one errors here will haunt
--   every feature that depends on "which cell am I in?"
--
-- **Wlaschin**: Think in terms of the DOMAIN. A cell is a region of F# code
--   delimited by `;;`. The function `find_cell(lines, cursor_line)` returns
--   {start_line, end_line, text} or nil. Make illegal states unrepresentable.
--
-- **Muratori**: Don't overthink it. Buffer is an array of strings. `;;` at end
--   of a line = cell boundary. Scan forward and backward from cursor. That's it.
--   The edge cases ARE the tests.
--
-- **Seemann**: The cell finder is a pure function: (string[], int) -> Cell | nil.
--   No side effects, no vim APIs. This is exactly what property-based testing
--   is for, but start with examples.
--
-- **Primeagen**: Test the hot path. `find_cell` gets called on every Alt-Enter.
--   If it's slow on a 2000-line file, you'll feel it. Include a perf test.
-- =============================================================================

local cells = require("sagefs.cells")

-- ─── find_boundaries: locate all ;; positions in a buffer ────────────────────

describe("cells.find_boundaries", function()
  it("finds no boundaries in empty buffer", function()
    local result = cells.find_boundaries({})
    assert.are.same({}, result)
  end)

  it("finds no boundaries in buffer without ;;", function()
    local lines = { "let x = 1", "let y = 2" }
    local result = cells.find_boundaries(lines)
    assert.are.same({}, result)
  end)

  it("finds ;; at end of line", function()
    local lines = { "let x = 1;;", "let y = 2" }
    local result = cells.find_boundaries(lines)
    assert.are.same({ 1 }, result)
  end)

  it("finds ;; with trailing whitespace", function()
    local lines = { "let x = 1;;  ", "let y = 2" }
    local result = cells.find_boundaries(lines)
    assert.are.same({ 1 }, result)
  end)

  it("finds standalone ;; on its own line", function()
    local lines = { "let x = 1", ";;" }
    local result = cells.find_boundaries(lines)
    assert.are.same({ 2 }, result)
  end)

  it("finds multiple boundaries", function()
    local lines = {
      "let x = 1;;",
      "let y = 2;;",
      "let z = 3",
    }
    local result = cells.find_boundaries(lines)
    assert.are.same({ 1, 2 }, result)
  end)

  it("finds ;; in multiline cell", function()
    local lines = {
      "let add x y =",
      "  x + y;;",
      "let z = 3",
    }
    local result = cells.find_boundaries(lines)
    assert.are.same({ 2 }, result)
  end)

  it("ignores ;; inside string literals", function()
    -- ;; inside a quoted string should NOT be a cell boundary
    local lines = { 'let s = "hello;;"' }
    local result = cells.find_boundaries(lines)
    assert.are.same({}, result)
  end)

  it("ignores ;; inside F# triple-quoted strings", function()
    local lines = { 'let s = """hello;;"""' }
    local result = cells.find_boundaries(lines)
    assert.are.same({}, result)
  end)

  it("ignores ;; inside line comments", function()
    local lines = { "// let x = 1;;" }
    local result = cells.find_boundaries(lines)
    assert.are.same({}, result)
  end)

  it("finds ;; after code even with comment on previous line", function()
    local lines = { "// comment", "let x = 1;;" }
    local result = cells.find_boundaries(lines)
    assert.are.same({ 2 }, result)
  end)
end)

-- ─── find_cell: get the cell containing cursor position ──────────────────────

describe("cells.find_cell", function()
  it("returns nil for empty buffer", function()
    local result = cells.find_cell({}, 1)
    assert.is_nil(result)
  end)

  it("returns entire buffer as one cell when no ;; present", function()
    local lines = { "let x = 1", "let y = 2" }
    local result = cells.find_cell(lines, 1)
    assert.is_not_nil(result)
    assert.are.equal(1, result.start_line)
    assert.are.equal(2, result.end_line)
    assert.are.equal("let x = 1\nlet y = 2", result.text)
  end)

  it("returns first cell when cursor is before first ;;", function()
    local lines = { "let x = 1", "let y = 2;;", "let z = 3" }
    local result = cells.find_cell(lines, 1)
    assert.is_not_nil(result)
    assert.are.equal(1, result.start_line)
    assert.are.equal(2, result.end_line)
    assert.are.equal("let x = 1\nlet y = 2;;", result.text)
  end)

  it("returns first cell when cursor is ON the ;; line", function()
    local lines = { "let x = 1", "let y = 2;;", "let z = 3" }
    local result = cells.find_cell(lines, 2)
    assert.is_not_nil(result)
    assert.are.equal(1, result.start_line)
    assert.are.equal(2, result.end_line)
  end)

  it("returns second cell when cursor is after first ;;", function()
    local lines = { "let x = 1;;", "let y = 2;;", "let z = 3" }
    local result = cells.find_cell(lines, 2)
    assert.is_not_nil(result)
    assert.are.equal(2, result.start_line)
    assert.are.equal(2, result.end_line)
    assert.are.equal("let y = 2;;", result.text)
  end)

  it("returns last cell (unterminated) when cursor is after last ;;", function()
    local lines = { "let x = 1;;", "let y = 2", "let z = 3" }
    local result = cells.find_cell(lines, 3)
    assert.is_not_nil(result)
    assert.are.equal(2, result.start_line)
    assert.are.equal(3, result.end_line)
    assert.are.equal("let y = 2\nlet z = 3", result.text)
  end)

  it("handles single-line cell", function()
    local lines = { "1 + 1;;" }
    local result = cells.find_cell(lines, 1)
    assert.is_not_nil(result)
    assert.are.equal(1, result.start_line)
    assert.are.equal(1, result.end_line)
    assert.are.equal("1 + 1;;", result.text)
  end)

  it("handles multiline cell with type definition", function()
    local lines = {
      "type Person = {",
      "  Name: string",
      "  Age: int",
      "};;",
      "let p = { Name = \"Alice\"; Age = 30 };;",
    }
    local result = cells.find_cell(lines, 2)
    assert.is_not_nil(result)
    assert.are.equal(1, result.start_line)
    assert.are.equal(4, result.end_line)
    assert.are.equal(
      "type Person = {\n  Name: string\n  Age: int\n};;",
      result.text
    )
  end)

  it("skips empty lines between cells", function()
    local lines = { "let x = 1;;", "", "let y = 2;;" }
    local result = cells.find_cell(lines, 3)
    assert.is_not_nil(result)
    assert.are.equal(2, result.start_line)
    assert.are.equal(3, result.end_line)
  end)

  it("returns nil for cursor line out of range", function()
    local lines = { "let x = 1;;" }
    assert.is_nil(cells.find_cell(lines, 0))
    assert.is_nil(cells.find_cell(lines, 5))
  end)

  it("handles cursor on empty line within a cell", function()
    local lines = { "let x = 1", "", "let y = 2;;" }
    local result = cells.find_cell(lines, 2)
    assert.is_not_nil(result)
    assert.are.equal(1, result.start_line)
    assert.are.equal(3, result.end_line)
  end)
end)

-- ─── find_all_cells: enumerate every cell in the buffer ──────────────────────

describe("cells.find_all_cells", function()
  it("returns empty list for empty buffer", function()
    assert.are.same({}, cells.find_all_cells({}))
  end)

  it("returns single cell for buffer with no ;;", function()
    local lines = { "let x = 1" }
    local result = cells.find_all_cells(lines)
    assert.are.equal(1, #result)
    assert.are.equal(1, result[1].start_line)
    assert.are.equal(1, result[1].end_line)
  end)

  it("returns two cells split by ;;", function()
    local lines = { "let x = 1;;", "let y = 2;;" }
    local result = cells.find_all_cells(lines)
    assert.are.equal(2, #result)
    assert.are.equal(1, result[1].start_line)
    assert.are.equal(1, result[1].end_line)
    assert.are.equal(2, result[2].start_line)
    assert.are.equal(2, result[2].end_line)
  end)

  it("includes trailing unterminated cell", function()
    local lines = { "let x = 1;;", "let y = 2" }
    local result = cells.find_all_cells(lines)
    assert.are.equal(2, #result)
    assert.are.equal(2, result[2].start_line)
    assert.are.equal(2, result[2].end_line)
  end)

  it("handles complex multi-cell buffer", function()
    local lines = {
      "// Cell 1",
      "let x = 1;;",
      "",
      "// Cell 2",
      "let add a b =",
      "  a + b;;",
      "",
      "// Cell 3 (unterminated)",
      "let z = add 1 2",
    }
    local result = cells.find_all_cells(lines)
    assert.are.equal(3, #result)
    assert.are.equal(1, result[1].start_line)
    assert.are.equal(2, result[1].end_line)
    assert.are.equal(3, result[2].start_line)
    assert.are.equal(6, result[2].end_line)
    assert.are.equal(7, result[3].start_line)
    assert.are.equal(9, result[3].end_line)
  end)

  it("assigns sequential cell IDs starting from 1", function()
    local lines = { "let x = 1;;", "let y = 2;;", "let z = 3;;" }
    local result = cells.find_all_cells(lines)
    assert.are.equal(1, result[1].id)
    assert.are.equal(2, result[2].id)
    assert.are.equal(3, result[3].id)
  end)
end)

-- ─── prepare_code: normalize code for submission ─────────────────────────────

describe("cells.prepare_code", function()
  it("appends ;; if missing", function()
    assert.are.equal("let x = 1;;", cells.prepare_code("let x = 1"))
  end)

  it("does not double-append ;;", function()
    assert.are.equal("let x = 1;;", cells.prepare_code("let x = 1;;"))
  end)

  it("handles trailing whitespace before ;;", function()
    assert.are.equal("let x = 1;;", cells.prepare_code("let x = 1;;  "))
  end)

  it("trims trailing whitespace", function()
    assert.are.equal("let x = 1;;", cells.prepare_code("let x = 1  "))
  end)

  it("trims leading blank lines", function()
    assert.are.equal("let x = 1;;", cells.prepare_code("\n\nlet x = 1"))
  end)

  it("trims trailing blank lines", function()
    assert.are.equal("let x = 1;;", cells.prepare_code("let x = 1\n\n"))
  end)

  it("preserves internal blank lines", function()
    local input = "let x = 1\n\nlet y = 2"
    local result = cells.prepare_code(input)
    assert.are.equal("let x = 1\n\nlet y = 2;;", result)
  end)

  it("returns nil for empty input", function()
    assert.is_nil(cells.prepare_code(""))
  end)

  it("returns nil for whitespace-only input", function()
    assert.is_nil(cells.prepare_code("   \n  \n  "))
  end)
end)

-- ─── is_boundary_line: check if a line ends a cell ───────────────────────────

describe("cells.is_boundary_line", function()
  it("recognizes ;; at end of line", function()
    assert.is_true(cells.is_boundary_line("let x = 1;;"))
  end)

  it("recognizes ;; with trailing spaces", function()
    assert.is_true(cells.is_boundary_line("let x = 1;;   "))
  end)

  it("recognizes standalone ;;", function()
    assert.is_true(cells.is_boundary_line(";;"))
  end)

  it("recognizes ;; with leading spaces", function()
    assert.is_true(cells.is_boundary_line("  ;;"))
  end)

  it("rejects ;; in middle of expression", function()
    assert.is_false(cells.is_boundary_line("let x = 1;; let y = 2"))
  end)

  it("rejects lines without ;;", function()
    assert.is_false(cells.is_boundary_line("let x = 1"))
  end)

  it("rejects ;; inside string", function()
    assert.is_false(cells.is_boundary_line('let s = "hello;;"'))
  end)

  it("rejects ;; inside comment", function()
    assert.is_false(cells.is_boundary_line("// hello;;"))
  end)

  it("rejects empty line", function()
    assert.is_false(cells.is_boundary_line(""))
  end)

  it("rejects ;; inside F# block comment (* ... *)", function()
    -- ;; not at end of line — already handled by trimmed:match(";;$")
    assert.is_false(cells.is_boundary_line("(* comment ;;*)"))
  end)

  -- RED TEST: multi-line block comment context
  -- A line that is just ";;" but is inside a (* ... *) block comment
  -- should not be a boundary. is_boundary_line is line-local and
  -- cannot know about multi-line block comment context.
  -- This documents the known limitation.
  pending("ignores ;; on its own line inside multi-line (* *) block comment", function()
    -- This would require block-comment-aware parsing across lines,
    -- which is_boundary_line does not support. Marking as pending
    -- to document the gap without failing the suite.
  end)
end)

-- ─── Property tests: fuzz is_boundary_line ───────────────────────────────────

describe("cells.is_boundary_line [property]", function()
  -- Seed for reproducibility
  math.randomseed(42)

  local function random_char()
    -- printable ASCII excluding problematic chars for cleaner tests
    local pool = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 +-*/=<>()[]{}.,:|&!@#$%^_~`?"
    local i = math.random(1, #pool)
    return pool:sub(i, i)
  end

  local function random_string(len)
    local chars = {}
    for i = 1, len do chars[i] = random_char() end
    return table.concat(chars)
  end

  it("any string without ;; is not a boundary (100 trials)", function()
    for _ = 1, 100 do
      local s = random_string(math.random(0, 200))
      -- Ensure no ;; exists
      s = s:gsub(";;", "xx")
      assert.is_false(cells.is_boundary_line(s),
        "should not be boundary: " .. s)
    end
  end)

  it("code .. ';;' is a boundary when code has balanced quotes and no // prefix (100 trials)", function()
    for _ = 1, 100 do
      -- Generate code without quotes, //, or ;; to avoid false positives
      local code = random_string(math.random(1, 80))
      code = code:gsub('"', 'x')
      code = code:gsub("//", "xx")
      code = code:gsub(";;", "xx")
      code = code:gsub("^%s+", "a") -- ensure non-whitespace start
      local line = code .. ";;"
      assert.is_true(cells.is_boundary_line(line),
        "should be boundary: " .. line)
    end
  end)

  it(";; inside double quotes is never a boundary (100 trials)", function()
    for _ = 1, 100 do
      local inner = random_string(math.random(0, 50))
      inner = inner:gsub('"', 'x') -- no nested quotes
      local line = 'let s = "' .. inner .. ';;' .. '"'
      assert.is_false(cells.is_boundary_line(line),
        "should not be boundary: " .. line)
    end
  end)
end)

-- ─── Property tests: find_cell invariants ────────────────────────────────────

describe("cells.find_cell [property]", function()
  it("every cursor line in a non-empty buffer returns a cell", function()
    -- Construct a realistic multi-cell buffer
    local lines = {
      "let a = 1;;",
      "let b = 2",
      "let c = 3;;",
      "",
      "let d = 4",
      "let e = 5;;",
      "let f = 6",
    }
    for cursor = 1, #lines do
      local cell = cells.find_cell(lines, cursor)
      assert.is_not_nil(cell,
        "find_cell returned nil for cursor line " .. cursor)
      assert.is_true(cell.start_line <= cursor,
        "cell start_line > cursor at line " .. cursor)
      assert.is_true(cell.end_line >= cursor,
        "cell end_line < cursor at line " .. cursor)
    end
  end)

  it("find_cell and find_all_cells agree on cell boundaries", function()
    local lines = {
      "let a = 1;;",
      "let b = 2;;",
      "let c = 3;;",
      "let d = 4",
    }
    local all = cells.find_all_cells(lines)
    for _, c in ipairs(all) do
      -- Cursor on start_line should return this cell
      local found = cells.find_cell(lines, c.start_line)
      assert.is_not_nil(found)
      assert.are.equal(c.start_line, found.start_line,
        "start_line mismatch for cell starting at " .. c.start_line)
      assert.are.equal(c.end_line, found.end_line,
        "end_line mismatch for cell ending at " .. c.end_line)
    end
  end)

  it("all cells partition the buffer (no gaps, no overlaps)", function()
    local lines = {
      "let a = 1;;",
      "let b = 2",
      "let c = 3;;",
      "let d = 4",
    }
    local all = cells.find_all_cells(lines)
    assert.is_true(#all > 0)
    -- First cell starts at 1
    assert.are.equal(1, all[1].start_line)
    -- Last cell ends at #lines
    assert.are.equal(#lines, all[#all].end_line)
    -- Each cell starts right after the previous one ends
    for i = 2, #all do
      assert.are.equal(all[i - 1].end_line + 1, all[i].start_line,
        "gap or overlap between cell " .. (i - 1) .. " and " .. i)
    end
  end)
end)

-- ─── Performance: find_boundaries on large buffer ────────────────────────────

describe("cells.find_boundaries [perf]", function()
  it("handles 5000-line buffer in under 50ms", function()
    -- Build a realistic large F# buffer
    local lines = {}
    for i = 1, 5000 do
      if i % 25 == 0 then
        lines[i] = "let x" .. i .. " = " .. i .. ";;"
      else
        lines[i] = "let x" .. i .. " = " .. i
      end
    end

    local start = os.clock()
    for _ = 1, 100 do
      cells.find_boundaries(lines)
    end
    local elapsed = (os.clock() - start) * 1000 -- ms for 100 iterations

    -- 100 iterations should complete well under 5 seconds (50ms each)
    assert.is_true(elapsed < 5000,
      string.format("100 iterations took %.1fms (%.1fms each), too slow", elapsed, elapsed / 100))
  end)
end)

-- ─── find_next_cell_start: cursor navigation after eval ──────────────────────

describe("cells.find_next_cell_start", function()
  it("returns the line after the current cell boundary", function()
    local lines = {
      "let x = 1;;",      -- line 1 (boundary)
      "let y = 2;;",      -- line 2 (boundary)
    }
    -- Cursor in cell 1 (line 1) → next cell starts at line 2
    local next_start = cells.find_next_cell_start(lines, 1)
    assert.are.equal(2, next_start)
  end)

  it("returns nil when cursor is in last cell", function()
    local lines = {
      "let x = 1;;",
      "let y = 2;;",
    }
    -- Cursor in cell 2 (line 2) → no next cell
    local next_start = cells.find_next_cell_start(lines, 2)
    assert.is_nil(next_start)
  end)

  it("handles multi-line cells", function()
    local lines = {
      "let x =",          -- line 1
      "  1;;",            -- line 2 (boundary)
      "let y =",          -- line 3
      "  2;;",            -- line 4 (boundary)
    }
    -- Cursor on line 1 → next cell starts at line 3
    local next_start = cells.find_next_cell_start(lines, 1)
    assert.are.equal(3, next_start)
  end)

  it("returns nil for single-cell buffer", function()
    local lines = {
      "let x = 1;;",
    }
    local next_start = cells.find_next_cell_start(lines, 1)
    assert.is_nil(next_start)
  end)

  it("returns nil for empty buffer", function()
    local next_start = cells.find_next_cell_start({}, 1)
    assert.is_nil(next_start)
  end)

  it("works from middle of multi-line cell", function()
    local lines = {
      "let x =",          -- line 1
      "  1 +",            -- line 2
      "  2;;",            -- line 3 (boundary)
      "let y = 3;;",      -- line 4
    }
    -- Cursor on line 2 (middle of first cell) → next cell starts at line 4
    local next_start = cells.find_next_cell_start(lines, 2)
    assert.are.equal(4, next_start)
  end)

  it("handles trailing unterminated cell as last cell", function()
    local lines = {
      "let x = 1;;",      -- line 1 (boundary)
      "let y = 2",        -- line 2 (no boundary)
      "// still editing",  -- line 3
    }
    -- Cursor on line 1 → next cell starts at line 2
    local next_start = cells.find_next_cell_start(lines, 1)
    assert.are.equal(2, next_start)
  end)

  it("returns nil when cursor is in trailing unterminated cell", function()
    local lines = {
      "let x = 1;;",      -- line 1 (boundary)
      "let y = 2",        -- line 2
    }
    -- Cursor on line 2 (unterminated last cell) → nil
    local next_start = cells.find_next_cell_start(lines, 2)
    assert.is_nil(next_start)
  end)
end)
