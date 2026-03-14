-- spec/dashboard/compositor_spec.lua — Compositor tests

describe("Compositor", function()
  local compositor

  before_each(function()
    compositor = require("sagefs.dashboard.compositor")
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.compositor"] = nil
  end)

  -- ─── Empty composition ──────────────────────────────────────────────────

  it("composes zero sections into empty output", function()
    local result = compositor.compose({})
    assert.same({}, result.lines)
    assert.same({}, result.highlights)
    assert.same({}, result.keymaps)
    assert.same({}, result.section_ranges)
  end)

  -- ─── Single section ─────────────────────────────────────────────────────

  it("composes a single section without modification", function()
    local output = {
      section_id = "health",
      lines = { "═══ Health ═══", "Version: 0.6.163" },
      highlights = { { line = 0, col_start = 0, col_end = 14, hl_group = "SageFsSectionHeader" } },
      keymaps = {},
    }
    local result = compositor.compose({ output })
    assert.equals(2, #result.lines)
    assert.equals("═══ Health ═══", result.lines[1])
    assert.equals("Version: 0.6.163", result.lines[2])
    assert.equals(1, #result.highlights)
    assert.equals(0, result.highlights[1].line)
    assert.equals(1, #result.section_ranges)
    assert.equals("health", result.section_ranges[1].section_id)
    assert.equals(0, result.section_ranges[1].start_line)
    assert.equals(1, result.section_ranges[1].end_line)
  end)

  -- ─── Multi-section with offset ──────────────────────────────────────────

  it("offsets highlights and keymaps for second section", function()
    local s1 = {
      section_id = "health",
      lines = { "═══ Health ═══", "OK" },
      highlights = { { line = 0, col_start = 0, col_end = 14, hl_group = "Header" } },
      keymaps = {},
    }
    local s2 = {
      section_id = "tests",
      lines = { "═══ Tests ═══", "✓ 42 passed" },
      highlights = { { line = 0, col_start = 0, col_end = 13, hl_group = "Header" } },
      keymaps = { { line = 1, key = "<CR>", action = { type = "jump" } } },
    }
    local result = compositor.compose({ s1, s2 })
    assert.equals(4, #result.lines)
    assert.equals("═══ Health ═══", result.lines[1])
    assert.equals("OK", result.lines[2])
    assert.equals("═══ Tests ═══", result.lines[3])
    assert.equals("✓ 42 passed", result.lines[4])
    -- s1's highlight stays at line 0
    assert.equals(0, result.highlights[1].line)
    -- s2's highlight at line 0 becomes line 2 (offset by s1's 2 lines)
    assert.equals(2, result.highlights[2].line)
    -- s2's keymap at line 1 becomes line 3
    assert.equals(3, result.keymaps[1].line)
  end)

  -- ─── Section ranges ─────────────────────────────────────────────────────

  it("tracks section ranges for navigation", function()
    local s1 = { section_id = "a", lines = { "1", "2", "3" }, highlights = {}, keymaps = {} }
    local s2 = { section_id = "b", lines = { "4", "5" }, highlights = {}, keymaps = {} }
    local result = compositor.compose({ s1, s2 })
    assert.equals(2, #result.section_ranges)
    assert.equals("a", result.section_ranges[1].section_id)
    assert.equals(0, result.section_ranges[1].start_line)
    assert.equals(2, result.section_ranges[1].end_line)
    assert.equals("b", result.section_ranges[2].section_id)
    assert.equals(3, result.section_ranges[2].start_line)
    assert.equals(4, result.section_ranges[2].end_line)
  end)

  -- ─── Separator ──────────────────────────────────────────────────────────

  it("inserts separator between sections", function()
    local s1 = { section_id = "a", lines = { "A" }, highlights = {}, keymaps = {} }
    local s2 = { section_id = "b", lines = { "B" }, highlights = {}, keymaps = {} }
    local result = compositor.compose({ s1, s2 }, { separator = "─" })
    assert.equals(3, #result.lines)
    assert.equals("A", result.lines[1])
    assert.equals("─", result.lines[2])
    assert.equals("B", result.lines[3])
  end)

  it("separator offsets highlights correctly", function()
    local s1 = { section_id = "a", lines = { "A" }, highlights = {}, keymaps = {} }
    local s2 = {
      section_id = "b",
      lines = { "B" },
      highlights = { { line = 0, col_start = 0, col_end = 1, hl_group = "X" } },
      keymaps = {},
    }
    local result = compositor.compose({ s1, s2 }, { separator = "─" })
    -- s2's highlight at line 0 should be offset by 1 (s1 lines) + 1 (separator) = 2
    assert.equals(2, result.highlights[1].line)
  end)

  it("no separator before first section", function()
    local s1 = { section_id = "a", lines = { "A" }, highlights = {}, keymaps = {} }
    local result = compositor.compose({ s1 }, { separator = "─" })
    assert.equals(1, #result.lines)
    assert.equals("A", result.lines[1])
  end)

  -- ─── Three sections ─────────────────────────────────────────────────────

  it("handles three sections with correct offsets", function()
    local s1 = { section_id = "a", lines = { "A1", "A2" }, highlights = {}, keymaps = {} }
    local s2 = { section_id = "b", lines = { "B1" }, highlights = {}, keymaps = {} }
    local s3 = {
      section_id = "c",
      lines = { "C1", "C2", "C3" },
      highlights = { { line = 2, col_start = 0, col_end = 2, hl_group = "Z" } },
      keymaps = { { line = 0, key = "x", action = { type = "test" } } },
    }
    local result = compositor.compose({ s1, s2, s3 })
    assert.equals(6, #result.lines)
    -- s3 highlight at line 2 → offset by 3 (2 + 1) = line 5
    assert.equals(5, result.highlights[1].line)
    -- s3 keymap at line 0 → offset by 3 = line 3
    assert.equals(3, result.keymaps[1].line)
    -- section ranges
    assert.equals(3, #result.section_ranges)
    assert.equals(0, result.section_ranges[1].start_line)
    assert.equals(1, result.section_ranges[1].end_line)
    assert.equals(2, result.section_ranges[2].start_line)
    assert.equals(2, result.section_ranges[2].end_line)
    assert.equals(3, result.section_ranges[3].start_line)
    assert.equals(5, result.section_ranges[3].end_line)
  end)

  -- ─── section_at_line ────────────────────────────────────────────────────

  describe("section_at_line", function()
    it("finds section for a given line", function()
      local ranges = {
        { section_id = "a", start_line = 0, end_line = 2 },
        { section_id = "b", start_line = 3, end_line = 4 },
      }
      assert.equals("a", compositor.section_at_line(ranges, 0))
      assert.equals("a", compositor.section_at_line(ranges, 2))
      assert.equals("b", compositor.section_at_line(ranges, 3))
      assert.equals("b", compositor.section_at_line(ranges, 4))
    end)

    it("returns nil for line outside any section", function()
      local ranges = {
        { section_id = "a", start_line = 0, end_line = 1 },
      }
      assert.is_nil(compositor.section_at_line(ranges, 5))
    end)

    it("returns nil for empty ranges", function()
      assert.is_nil(compositor.section_at_line({}, 0))
    end)
  end)
end)
