require("spec.helper")
local cells = require("sagefs.cells")

-- tree-sitter-fsharp folds the blank line and the /// doc comment that belong
-- to the NEXT declaration into the END of the previous node. A result drawn at
-- the cell's end then lands on another declaration's doc comment (real run:
-- parseWindow's result appeared on the line above `let parseSeed`).

local demo = {
  "type WindowSpec =",           -- 1
  "  { X: int",                  -- 2
  "    Y: int }",                -- 3
  "",                            -- 4
  "/// Parses x,y,w,h.",         -- 5
  "/// Returns None on error.",  -- 6
  "let parseWindow raw =",       -- 7
  "  match raw with",            -- 8
  "  | None -> None",            -- 9
  "  | Some t -> Some t",        -- 10
  "",                            -- 11
  "/// Parses a seed.",          -- 12
  "let parseSeed raw =",         -- 13
  "  Some 1",                    -- 14
}

local function ts_ranges()
  -- what the grammar reports: each node swallows the trailing blank + doc comments
  return {
    { id = 1, start_line = 1, end_line = 6, node_type = "type_definition" },
    { id = 2, start_line = 7, end_line = 12, node_type = "declaration_expression" },
    { id = 3, start_line = 13, end_line = 14, node_type = "declaration_expression" },
  }
end

describe("sagefs.cells.refine_inferred", function()
  it("ends each cell on its last code line", function()
    local r = cells.refine_inferred(demo, ts_ranges())
    assert.are.equal(3, r[1].end_line)
    assert.are.equal(10, r[2].end_line)
    assert.are.equal(14, r[3].end_line)
  end)

  it("hands the doc comment directly above a declaration to that declaration", function()
    local r = cells.refine_inferred(demo, ts_ranges())
    assert.are.equal(1, r[1].start_line)
    assert.are.equal(5, r[2].start_line)   -- /// lines 5-6 belong to parseWindow
    assert.are.equal(12, r[3].start_line)  -- /// line 12 belongs to parseSeed
  end)

  it("leaves the blank line between declarations in no cell", function()
    local r = cells.refine_inferred(demo, ts_ranges())
    assert.is_true(r[1].end_line < 4)
    assert.is_true(r[2].end_line < 11)
  end)

  it("keeps ids and node types", function()
    local r = cells.refine_inferred(demo, ts_ranges())
    assert.are.equal(2, r[2].id)
    assert.are.equal("declaration_expression", r[2].node_type)
  end)

  it("does not touch a range that already ends on code", function()
    local lines = { "let a = 1", "let b = 2" }
    local r = cells.refine_inferred(lines, {
      { id = 1, start_line = 1, end_line = 1 }, { id = 2, start_line = 2, end_line = 2 },
    })
    assert.are.equal(1, r[1].end_line)
    assert.are.equal(2, r[2].start_line)
  end)

  it("never shrinks a cell below its first line", function()
    local lines = { "// only a comment", "", "let a = 1" }
    local r = cells.refine_inferred(lines, {
      { id = 1, start_line = 1, end_line = 2 }, { id = 2, start_line = 3, end_line = 3 },
    })
    assert.is_true(r[1].end_line >= r[1].start_line)
  end)

  it("keeps a trailing comment on a code line (the line is code)", function()
    local lines = { "let a = 1 // one", "let b = 2" }
    local r = cells.refine_inferred(lines, {
      { id = 1, start_line = 1, end_line = 1 }, { id = 2, start_line = 2, end_line = 2 },
    })
    assert.are.equal(1, r[1].end_line)
  end)

  it("is the identity on an empty list", function()
    assert.are.same({}, cells.refine_inferred({}, {}))
  end)
end)
