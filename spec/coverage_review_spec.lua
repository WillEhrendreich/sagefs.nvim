-- spec/coverage_review_spec.lua — Tests for the pure half of coverage_review.lua
-- (quickfix item construction). The vim.fn/vim.cmd glue — open/refresh/is_active —
-- is exercised in spec/nvim_harness.lua under real Neovim.
require("spec.helper")

local coverage = require("sagefs.coverage")
local coverage_review = require("sagefs.coverage_review")

describe("coverage_review", function()
  -- ─── empty_message ───────────────────────────────────────────────────────
  describe("empty_message", function()
    it("returns a non-empty, friendly string", function()
      local msg = coverage_review.empty_message()
      assert.is_string(msg)
      assert.truthy(msg:find("coverage"))
    end)
  end)

  -- ─── build_qflist_items ──────────────────────────────────────────────────
  describe("build_qflist_items", function()
    it("returns no items for a fresh coverage state", function()
      local items = coverage_review.build_qflist_items(coverage.new())
      assert.are.equal(0, #items)
    end)

    it("includes an overall summary header line", function()
      local s = coverage.new()
      coverage.update_file(s, "a.fs", { [1] = 1, [2] = 0 })
      local items = coverage_review.build_qflist_items(s)
      assert.truthy(items[1].text:find("Overall"))
      assert.truthy(items[1].text:find("50"))
    end)

    it("includes a per-file summary line with the file path", function()
      local s = coverage.new()
      coverage.update_file(s, "src/Math.fs", { [1] = 1, [2] = 0 })
      local items = coverage_review.build_qflist_items(s)
      local found = false
      for _, item in ipairs(items) do
        if item.text and item.text:find("src/Math.fs", 1, true) then found = true end
      end
      assert.is_true(found)
    end)

    it("emits a jumpable entry for each uncovered line", function()
      local s = coverage.new()
      coverage.update_file(s, "a.fs", { [1] = 0, [2] = 1, [3] = 0 })
      local items = coverage_review.build_qflist_items(s)
      local uncovered_entries = {}
      for _, item in ipairs(items) do
        if item.filename then table.insert(uncovered_entries, item) end
      end
      assert.are.equal(2, #uncovered_entries)
      assert.are.equal("a.fs", uncovered_entries[1].filename)
      assert.are.equal(1, uncovered_entries[1].lnum)
      assert.are.equal(3, uncovered_entries[2].lnum)
    end)

    it("does not emit jumpable entries for covered lines", function()
      local s = coverage.new()
      coverage.update_file(s, "a.fs", { [1] = 1, [2] = 5 })
      local items = coverage_review.build_qflist_items(s)
      for _, item in ipairs(items) do
        assert.is_nil(item.filename)
      end
    end)

    it("marks a fully-covered file explicitly rather than showing nothing", function()
      local s = coverage.new()
      coverage.update_file(s, "a.fs", { [1] = 1, [2] = 2 })
      local items = coverage_review.build_qflist_items(s)
      local found = false
      for _, item in ipairs(items) do
        if item.text and item.text:find("fully covered") then found = true end
      end
      assert.is_true(found)
    end)

    it("orders files deterministically by path", function()
      local s = coverage.new()
      coverage.update_file(s, "z.fs", { [1] = 0 })
      coverage.update_file(s, "a.fs", { [1] = 0 })
      local items = coverage_review.build_qflist_items(s)
      local a_idx, z_idx
      for i, item in ipairs(items) do
        if item.filename == "a.fs" then a_idx = a_idx or i end
        if item.filename == "z.fs" then z_idx = z_idx or i end
      end
      assert.truthy(a_idx and z_idx)
      assert.is_true(a_idx < z_idx)
    end)
  end)
end)
