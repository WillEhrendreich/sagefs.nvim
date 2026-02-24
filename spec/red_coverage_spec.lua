-- RED tests for coverage.lua — a pure coverage state model
-- This module DOES NOT EXIST YET. All tests will fail.

require("spec.helper")

-- This require will fail until coverage.lua is created
local ok, coverage = pcall(require, "sagefs.coverage")
if not ok then
  -- Create a stub so describe/it blocks can register without crashing,
  -- but every test will fail on the first assertion
  coverage = {}
end

-- ─── State constructor ───────────────────────────────────────────────────────

describe("coverage.new [RED]", function()
  it("creates an empty coverage state", function()
    assert.is_function(coverage.new)
    local state = coverage.new()
    assert.is_table(state)
    assert.is_table(state.files)
    assert.are.equal(0, coverage.file_count(state))
  end)
end)

-- ─── Line-level tracking ─────────────────────────────────────────────────────

describe("coverage.update_file [RED]", function()
  it("records line coverage for a file", function()
    local state = coverage.new()
    -- lines is a table: line_number → hit_count
    state = coverage.update_file(state, "src/Math.fs", {
      [10] = 3,
      [11] = 3,
      [12] = 0, -- uncovered
      [15] = 1,
    })
    assert.are.equal(1, coverage.file_count(state))
  end)

  it("replaces previous data for same file", function()
    local state = coverage.new()
    state = coverage.update_file(state, "src/Math.fs", { [10] = 1 })
    state = coverage.update_file(state, "src/Math.fs", { [10] = 5, [11] = 2 })
    local lines = coverage.get_file_lines(state, "src/Math.fs")
    assert.are.equal(5, lines[10])
    assert.are.equal(2, lines[11])
  end)
end)

-- ─── Queries ─────────────────────────────────────────────────────────────────

describe("coverage.get_file_lines [RED]", function()
  it("returns line coverage for a known file", function()
    local state = coverage.new()
    state = coverage.update_file(state, "src/Math.fs", {
      [10] = 3, [11] = 0, [12] = 1,
    })
    local lines = coverage.get_file_lines(state, "src/Math.fs")
    assert.are.equal(3, lines[10])
    assert.are.equal(0, lines[11])
    assert.are.equal(1, lines[12])
  end)

  it("returns empty table for unknown file", function()
    local state = coverage.new()
    local lines = coverage.get_file_lines(state, "nope.fs")
    assert.is_table(lines)
    assert.are.equal(0, #lines)
  end)
end)

describe("coverage.compute_file_summary [RED]", function()
  it("computes covered/uncovered/total for a file", function()
    local state = coverage.new()
    state = coverage.update_file(state, "src/Math.fs", {
      [10] = 3, [11] = 0, [12] = 1, [13] = 0, [14] = 5,
    })
    local summary = coverage.compute_file_summary(state, "src/Math.fs")
    assert.are.equal(5, summary.total)
    assert.are.equal(3, summary.covered)
    assert.are.equal(2, summary.uncovered)
    assert.is_true(summary.percent > 59 and summary.percent < 61)
  end)

  it("returns zero summary for unknown file", function()
    local state = coverage.new()
    local summary = coverage.compute_file_summary(state, "nope.fs")
    assert.are.equal(0, summary.total)
    assert.are.equal(0, summary.covered)
  end)
end)

describe("coverage.compute_total_summary [RED]", function()
  it("aggregates across all files", function()
    local state = coverage.new()
    state = coverage.update_file(state, "a.fs", { [1] = 1, [2] = 0 })
    state = coverage.update_file(state, "b.fs", { [1] = 1, [2] = 1 })
    local summary = coverage.compute_total_summary(state)
    assert.are.equal(4, summary.total)
    assert.are.equal(3, summary.covered)
    assert.are.equal(1, summary.uncovered)
    assert.are.equal(75, summary.percent)
  end)
end)

-- ─── Gutter signs ────────────────────────────────────────────────────────────

describe("coverage.gutter_sign [RED]", function()
  it("returns covered sign for hit_count > 0", function()
    local sign = coverage.gutter_sign(3)
    assert.are.equal("SageFsCovered", sign.hl)
  end)

  it("returns uncovered sign for hit_count == 0", function()
    local sign = coverage.gutter_sign(0)
    assert.are.equal("SageFsUncovered", sign.hl)
  end)

  it("returns no sign for nil (no coverage data)", function()
    local sign = coverage.gutter_sign(nil)
    assert.are.equal("Normal", sign.hl)
  end)
end)

-- ─── Formatting ──────────────────────────────────────────────────────────────

describe("coverage.format_summary [RED]", function()
  it("formats a readable coverage summary line", function()
    local summary = { total = 100, covered = 85, uncovered = 15, percent = 85 }
    local line = coverage.format_summary(summary)
    assert.is_string(line)
    assert.is_truthy(line:find("85"))
    assert.is_truthy(line:find("%%")) -- percent sign
  end)

  it("shows 0% for no lines", function()
    local summary = { total = 0, covered = 0, uncovered = 0, percent = 0 }
    local line = coverage.format_summary(summary)
    assert.is_string(line)
    assert.is_truthy(line:find("0"))
  end)
end)

describe("coverage.format_statusline [RED]", function()
  it("returns compact coverage for statusline", function()
    local state = coverage.new()
    state = coverage.update_file(state, "a.fs", { [1] = 1, [2] = 1, [3] = 0 })
    local line = coverage.format_statusline(state)
    assert.is_string(line)
    assert.is_truthy(line:find("66") or line:find("67")) -- ~66.7%
  end)

  it("returns empty string when no coverage data", function()
    local state = coverage.new()
    local line = coverage.format_statusline(state)
    assert.are.equal("", line)
  end)
end)

-- ─── Clear ───────────────────────────────────────────────────────────────────

describe("coverage.clear [RED]", function()
  it("removes all coverage data", function()
    local state = coverage.new()
    state = coverage.update_file(state, "a.fs", { [1] = 1 })
    state = coverage.update_file(state, "b.fs", { [1] = 1 })
    state = coverage.clear(state)
    assert.are.equal(0, coverage.file_count(state))
  end)
end)

-- ─── Parse server response ───────────────────────────────────────────────────

describe("coverage.parse_coverage_response [RED]", function()
  it("parses a JSON coverage response", function()
    -- Simulated server response shape
    local json_str = vim.fn.json_encode({
      files = {
        { path = "src/Math.fs", lines = { { line = 10, hits = 3 }, { line = 11, hits = 0 } } },
        { path = "src/Net.fs", lines = { { line = 1, hits = 1 } } },
      },
    })
    local data, err = coverage.parse_coverage_response(json_str)
    assert.is_nil(err)
    assert.is_table(data)
    assert.are.equal(2, #data.files)
  end)

  it("returns error for invalid JSON", function()
    local data, err = coverage.parse_coverage_response("not json")
    assert.is_not_nil(err)
  end)

  it("returns error for empty input", function()
    local data, err = coverage.parse_coverage_response("")
    assert.is_not_nil(err)
  end)
end)

describe("coverage.apply_coverage_response [RED]", function()
  it("populates state from parsed server response", function()
    local state = coverage.new()
    local data = {
      files = {
        { path = "src/Math.fs", lines = { { line = 10, hits = 3 }, { line = 11, hits = 0 } } },
      },
    }
    state = coverage.apply_coverage_response(state, data)
    assert.are.equal(1, coverage.file_count(state))
    local lines = coverage.get_file_lines(state, "src/Math.fs")
    assert.are.equal(3, lines[10])
    assert.are.equal(0, lines[11])
  end)
end)
