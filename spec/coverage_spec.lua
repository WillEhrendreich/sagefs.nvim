require("spec.helper")
local coverage = require("sagefs.coverage")

describe("coverage", function()
  -- ─── new ─────────────────────────────────────────────────────────────────
  describe("new", function()
    it("returns empty state", function()
      local s = coverage.new()
      assert.is_table(s)
      assert.is_table(s.files)
      assert.is_false(s.enabled)
    end)

    it("returns independent instances", function()
      local a = coverage.new()
      local b = coverage.new()
      a.enabled = true
      assert.is_false(b.enabled)
    end)
  end)

  -- ─── file_count ──────────────────────────────────────────────────────────
  describe("file_count", function()
    it("returns 0 for empty state", function()
      local s = coverage.new()
      assert.are.equal(0, coverage.file_count(s))
    end)

    it("counts files after updates", function()
      local s = coverage.new()
      coverage.update_file(s, "a.fs", { [1] = 1 })
      coverage.update_file(s, "b.fs", { [1] = 0 })
      assert.are.equal(2, coverage.file_count(s))
    end)
  end)

  -- ─── update_file / get_file_lines ────────────────────────────────────────
  describe("update_file", function()
    it("stores line data for a file", function()
      local s = coverage.new()
      coverage.update_file(s, "src/Main.fs", { [5] = 3, [10] = 0 })
      local lines = coverage.get_file_lines(s, "src/Main.fs")
      assert.are.equal(3, lines[5])
      assert.are.equal(0, lines[10])
    end)

    it("overwrites previous data", function()
      local s = coverage.new()
      coverage.update_file(s, "a.fs", { [1] = 1 })
      coverage.update_file(s, "a.fs", { [1] = 5, [2] = 0 })
      local lines = coverage.get_file_lines(s, "a.fs")
      assert.are.equal(5, lines[1])
      assert.are.equal(0, lines[2])
    end)

    it("returns state for chaining", function()
      local s = coverage.new()
      local r = coverage.update_file(s, "a.fs", {})
      assert.are.equal(s, r)
    end)
  end)

  describe("get_file_lines", function()
    it("returns empty table for unknown file", function()
      local s = coverage.new()
      local lines = coverage.get_file_lines(s, "nonexistent.fs")
      assert.is_table(lines)
      assert.are.equal(0, #lines)
    end)
  end)

  -- ─── compute_file_summary ────────────────────────────────────────────────
  describe("compute_file_summary", function()
    it("returns zeros for unknown file", function()
      local s = coverage.new()
      local sum = coverage.compute_file_summary(s, "nope.fs")
      assert.are.equal(0, sum.total)
      assert.are.equal(0, sum.covered)
      assert.are.equal(0, sum.uncovered)
      assert.are.equal(0, sum.percent)
    end)

    it("computes correct summary for mixed coverage", function()
      local s = coverage.new()
      coverage.update_file(s, "a.fs", { [1] = 5, [2] = 0, [3] = 1, [4] = 0 })
      local sum = coverage.compute_file_summary(s, "a.fs")
      assert.are.equal(4, sum.total)
      assert.are.equal(2, sum.covered)
      assert.are.equal(2, sum.uncovered)
      assert.are.equal(50, sum.percent)
    end)

    it("100% when all lines covered", function()
      local s = coverage.new()
      coverage.update_file(s, "a.fs", { [1] = 1, [2] = 3, [3] = 7 })
      local sum = coverage.compute_file_summary(s, "a.fs")
      assert.are.equal(100, sum.percent)
      assert.are.equal(3, sum.covered)
      assert.are.equal(0, sum.uncovered)
    end)

    it("0% when no lines covered", function()
      local s = coverage.new()
      coverage.update_file(s, "a.fs", { [1] = 0, [2] = 0 })
      local sum = coverage.compute_file_summary(s, "a.fs")
      assert.are.equal(0, sum.percent)
    end)

    it("rounds percentage correctly", function()
      local s = coverage.new()
      coverage.update_file(s, "a.fs", { [1] = 1, [2] = 0, [3] = 0 })
      local sum = coverage.compute_file_summary(s, "a.fs")
      assert.are.equal(33, sum.percent) -- 1/3 = 33.3 → rounds to 33
    end)
  end)

  -- ─── compute_total_summary ───────────────────────────────────────────────
  describe("compute_total_summary", function()
    it("returns zeros for empty state", function()
      local s = coverage.new()
      local sum = coverage.compute_total_summary(s)
      assert.are.equal(0, sum.total)
      assert.are.equal(0, sum.percent)
    end)

    it("aggregates across files", function()
      local s = coverage.new()
      coverage.update_file(s, "a.fs", { [1] = 1, [2] = 0 })
      coverage.update_file(s, "b.fs", { [1] = 1, [2] = 1 })
      local sum = coverage.compute_total_summary(s)
      assert.are.equal(4, sum.total)
      assert.are.equal(3, sum.covered)
      assert.are.equal(1, sum.uncovered)
      assert.are.equal(75, sum.percent)
    end)
  end)

  -- ─── gutter_sign ─────────────────────────────────────────────────────────
  describe("gutter_sign", function()
    it("returns space for nil", function()
      local sign = coverage.gutter_sign(nil)
      assert.are.equal(" ", sign.text)
      assert.are.equal("Normal", sign.hl)
    end)

    it("returns covered sign for positive hits", function()
      local sign = coverage.gutter_sign(5)
      assert.are.equal("│", sign.text)
      assert.are.equal("SageFsCovered", sign.hl)
    end)

    it("returns uncovered sign for zero hits", function()
      local sign = coverage.gutter_sign(0)
      assert.are.equal("█", sign.text)
      assert.are.equal("SageFsUncovered", sign.hl)
    end)
  end)

  -- ─── format_summary ──────────────────────────────────────────────────────
  describe("format_summary", function()
    it("formats zero coverage", function()
      assert.are.equal("0% covered (0/0)",
        coverage.format_summary({ total = 0, covered = 0, uncovered = 0, percent = 0 }))
    end)

    it("formats partial coverage", function()
      assert.are.equal("75% covered (3/4)",
        coverage.format_summary({ total = 4, covered = 3, uncovered = 1, percent = 75 }))
    end)
  end)

  -- ─── format_statusline ───────────────────────────────────────────────────
  describe("format_statusline", function()
    it("returns empty string for no coverage", function()
      local s = coverage.new()
      assert.are.equal("", coverage.format_statusline(s))
    end)

    it("returns umbrella + percent when coverage exists", function()
      local s = coverage.new()
      coverage.update_file(s, "a.fs", { [1] = 1, [2] = 1 })
      local sl = coverage.format_statusline(s)
      assert.truthy(sl:match("100%%"))
      assert.truthy(sl:match("☂"))
    end)
  end)

  -- ─── clear ───────────────────────────────────────────────────────────────
  describe("clear", function()
    it("removes all file data", function()
      local s = coverage.new()
      coverage.update_file(s, "a.fs", { [1] = 1 })
      coverage.clear(s)
      assert.are.equal(0, coverage.file_count(s))
    end)

    it("returns state for chaining", function()
      local s = coverage.new()
      assert.are.equal(s, coverage.clear(s))
    end)
  end)

  -- ─── parse_coverage_response ─────────────────────────────────────────────
  describe("parse_coverage_response", function()
    it("returns nil for empty input", function()
      local data, err = coverage.parse_coverage_response("")
      assert.is_nil(data)
      assert.truthy(err)
    end)

    it("returns nil for nil input", function()
      local data, err = coverage.parse_coverage_response(nil)
      assert.is_nil(data)
      assert.truthy(err)
    end)

    it("parses valid JSON", function()
      local json = '{"files":[{"path":"a.fs","lines":[{"line":1,"hits":3}]}]}'
      local data, err = coverage.parse_coverage_response(json)
      assert.is_nil(err)
      assert.is_table(data)
      assert.are.equal("a.fs", data.files[1].path)
    end)
  end)

  -- ─── apply_coverage_response ─────────────────────────────────────────────
  describe("apply_coverage_response", function()
    it("applies file entries to state", function()
      local s = coverage.new()
      local data = {
        files = {
          { path = "src/Lib.fs", lines = { { line = 5, hits = 2 }, { line = 10, hits = 0 } } },
          { path = "src/App.fs", lines = { { line = 1, hits = 1 } } },
        },
      }
      coverage.apply_coverage_response(s, data)
      assert.are.equal(2, coverage.file_count(s))
      local lines = coverage.get_file_lines(s, "src/Lib.fs")
      assert.are.equal(2, lines[5])
      assert.are.equal(0, lines[10])
    end)

    it("handles nil data gracefully", function()
      local s = coverage.new()
      local r = coverage.apply_coverage_response(s, nil)
      assert.are.equal(s, r)
    end)

    it("handles data without files key", function()
      local s = coverage.new()
      local r = coverage.apply_coverage_response(s, { something = "else" })
      assert.are.equal(s, r)
    end)
  end)
end)
