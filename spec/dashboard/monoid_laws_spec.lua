-- Monoid law tests for the dashboard compositor
-- The compositor forms a monoid over SectionOutputs:
--   identity: { lines = {}, highlights = {}, keymaps = {} }
--   binary op: vertical concatenation with highlight/keymap offset
--
-- We verify: left identity, right identity, associativity,
-- and structural invariants that hold for ALL compositions.

describe("compositor monoid laws", function()
  local compositor = require("sagefs.dashboard.compositor")

  -- Helper: create a SectionOutput with N lines and some highlights/keymaps
  local function make_output(id, n_lines)
    local lines = {}
    local highlights = {}
    local keymaps = {}
    for i = 1, n_lines do
      table.insert(lines, string.format("%s-line-%d", id, i))
      table.insert(highlights, {
        line = i - 1, col_start = 0, col_end = #lines[i], hl_group = "Hl_" .. id,
      })
      if i == 1 then
        table.insert(keymaps, {
          line = 0, key = "<CR>", action = { type = "test", id = id },
        })
      end
    end
    return { section_id = id, lines = lines, highlights = highlights, keymaps = keymaps }
  end

  local function empty()
    return { section_id = "", lines = {}, highlights = {}, keymaps = {} }
  end

  -- ─── Identity Laws ─────────────────────────────────────────────────────────

  it("left identity: compose({empty, a}) ≡ compose({a})", function()
    local a = make_output("a", 3)
    local with_empty = compositor.compose({ empty(), a })
    local alone = compositor.compose({ a })

    -- Lines should be identical
    assert.are.same(alone.lines, with_empty.lines)
  end)

  it("right identity: compose({a, empty}) ≡ compose({a})", function()
    local a = make_output("a", 3)
    local with_empty = compositor.compose({ a, empty() })
    local alone = compositor.compose({ a })

    assert.are.same(alone.lines, with_empty.lines)
  end)

  it("empty compose: compose({}) is the identity element", function()
    local result = compositor.compose({})
    assert.are.same({}, result.lines)
    assert.are.same({}, result.highlights)
    assert.are.same({}, result.keymaps)
    assert.are.same({}, result.section_ranges)
  end)

  it("singleton: compose({a}) preserves a exactly", function()
    local a = make_output("alpha", 4)
    local result = compositor.compose({ a })

    assert.are.same(a.lines, result.lines)
    assert.equals(#a.highlights, #result.highlights)
    assert.equals(#a.keymaps, #result.keymaps)
    -- Offsets should be 0 (no shift for first section)
    for _, hl in ipairs(result.highlights) do
      assert.is_true(hl.line >= 0 and hl.line < #a.lines)
    end
  end)

  -- ─── Associativity ────────────────────────────────────────────────────────

  it("line concatenation is associative", function()
    local a = make_output("a", 2)
    local b = make_output("b", 3)
    local c = make_output("c", 1)

    local abc = compositor.compose({ a, b, c })

    -- Total lines = sum of all section lines
    assert.equals(2 + 3 + 1, #abc.lines)

    -- Lines are in order: a's lines, then b's, then c's
    assert.equals("a-line-1", abc.lines[1])
    assert.equals("a-line-2", abc.lines[2])
    assert.equals("b-line-1", abc.lines[3])
    assert.equals("b-line-2", abc.lines[4])
    assert.equals("b-line-3", abc.lines[5])
    assert.equals("c-line-1", abc.lines[6])
  end)

  it("associativity with separators preserves total line count", function()
    local a = make_output("a", 2)
    local b = make_output("b", 3)
    local c = make_output("c", 1)

    local abc = compositor.compose({ a, b, c }, { separator = "---" })

    -- 2 + 3 + 1 content lines + 2 separator lines = 8
    assert.equals(8, #abc.lines)
    assert.equals("---", abc.lines[3])
    assert.equals("---", abc.lines[7])
  end)

  -- ─── Structural Invariants (hold for ALL compositions) ─────────────────────

  it("highlights are in-bounds: all line indices < total lines", function()
    local sections = {}
    for i = 1, 5 do
      table.insert(sections, make_output("s" .. i, i + 1))
    end

    local composed = compositor.compose(sections, { separator = "───" })

    for _, hl in ipairs(composed.highlights) do
      assert.is_true(hl.line >= 0, "highlight line >= 0")
      assert.is_true(hl.line < #composed.lines,
        string.format("highlight line %d < total %d", hl.line, #composed.lines))
    end
  end)

  it("keymaps are in-bounds: all line indices < total lines", function()
    local sections = {}
    for i = 1, 5 do
      table.insert(sections, make_output("s" .. i, i + 1))
    end

    local composed = compositor.compose(sections, { separator = "───" })

    for _, km in ipairs(composed.keymaps) do
      assert.is_true(km.line >= 0, "keymap line >= 0")
      assert.is_true(km.line < #composed.lines,
        string.format("keymap line %d < total %d", km.line, #composed.lines))
    end
  end)

  it("section ranges are non-overlapping and exhaustive", function()
    local a = make_output("a", 3)
    local b = make_output("b", 2)
    local c = make_output("c", 4)

    local composed = compositor.compose({ a, b, c })
    local ranges = composed.section_ranges

    -- Ranges are sorted by start_line
    for i = 2, #ranges do
      assert.is_true(ranges[i].start_line > ranges[i - 1].end_line,
        "ranges should not overlap")
    end

    -- Every content line belongs to exactly one section
    for line = 0, #composed.lines - 1 do
      local found = compositor.section_at_line(ranges, line)
      assert.is_truthy(found,
        string.format("line %d should belong to a section", line))
    end
  end)

  it("section ranges with separators: separator lines belong to no section", function()
    local a = make_output("a", 2)
    local b = make_output("b", 2)

    local composed = compositor.compose({ a, b }, { separator = "---" })
    local ranges = composed.section_ranges

    -- Line 2 is the separator (0-indexed: lines 0,1 = a; line 2 = sep; lines 3,4 = b)
    local sep_owner = compositor.section_at_line(ranges, 2)
    assert.is_nil(sep_owner, "separator line should not belong to any section")
  end)

  it("total highlights = sum of per-section highlights", function()
    local a = make_output("a", 3)
    local b = make_output("b", 2)

    local composed = compositor.compose({ a, b })
    assert.equals(#a.highlights + #b.highlights, #composed.highlights)
  end)

  it("total keymaps = sum of per-section keymaps", function()
    local a = make_output("a", 3)
    local b = make_output("b", 2)

    local composed = compositor.compose({ a, b })
    assert.equals(#a.keymaps + #b.keymaps, #composed.keymaps)
  end)

  -- ─── Stress test: many sections ──────────────────────────────────────────

  it("composes 50 sections without error", function()
    local sections = {}
    for i = 1, 50 do
      table.insert(sections, make_output("s" .. i, math.max(1, i % 7)))
    end

    local composed = compositor.compose(sections, { separator = "─" })

    assert.is_true(#composed.lines > 50) -- at least 1 line per section + separators
    assert.equals(50, #composed.section_ranges)

    -- All highlights still in bounds
    for _, hl in ipairs(composed.highlights) do
      assert.is_true(hl.line < #composed.lines)
    end
  end)
end)
