-- spec/dashboard/layout_spec.lua — Dynamic height tests
-- Tests the pure height computation logic

describe("dashboard dynamic height", function()
  local compositor

  before_each(function()
    compositor = require("sagefs.dashboard.compositor")
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.compositor"] = nil
  end)

  -- ─── compute_height ─────────────────────────────────────────────────────

  describe("compute_height", function()
    it("returns content line count when under max", function()
      local composed = {
        lines = { "a", "b", "c", "d", "e" }, -- 5 lines
      }
      assert.equals(5, compositor.compute_height(composed, 40, 5))
    end)

    it("caps at max_height when content exceeds it", function()
      local lines = {}
      for i = 1, 100 do
        table.insert(lines, "line " .. i)
      end
      local composed = { lines = lines }
      assert.equals(40, compositor.compute_height(composed, 40, 5))
    end)

    it("respects min_height when content is tiny", function()
      local composed = { lines = { "a" } }
      assert.equals(5, compositor.compute_height(composed, 40, 5))
    end)

    it("returns min_height for empty content", function()
      local composed = { lines = {} }
      assert.equals(5, compositor.compute_height(composed, 40, 5))
    end)

    it("handles exact max_height boundary", function()
      local lines = {}
      for i = 1, 40 do
        table.insert(lines, "line " .. i)
      end
      local composed = { lines = lines }
      assert.equals(40, compositor.compute_height(composed, 40, 5))
    end)

    it("uses default min_height of 5 when not provided", function()
      local composed = { lines = { "a" } }
      assert.equals(5, compositor.compute_height(composed, 40))
    end)

    it("uses default max_height of 40 when not provided", function()
      local lines = {}
      for i = 1, 60 do
        table.insert(lines, "line " .. i)
      end
      local composed = { lines = lines }
      assert.equals(40, compositor.compute_height(composed))
    end)

    it("grows panel when content exceeds current height", function()
      -- Simulate: dashboard currently at 10, content is 25 lines
      local lines = {}
      for i = 1, 25 do
        table.insert(lines, "line " .. i)
      end
      local composed = { lines = lines }
      local new_height = compositor.compute_height(composed, 40, 5)
      assert.equals(25, new_height) -- should grow to 25
    end)

    it("shrinks when content decreases", function()
      -- First render: 30 lines
      local lines30 = {}
      for i = 1, 30 do
        table.insert(lines30, "line " .. i)
      end
      local h1 = compositor.compute_height({ lines = lines30 }, 40, 5)
      assert.equals(30, h1)

      -- Second render: 10 lines
      local lines10 = {}
      for i = 1, 10 do
        table.insert(lines10, "line " .. i)
      end
      local h2 = compositor.compute_height({ lines = lines10 }, 40, 5)
      assert.equals(10, h2)
      assert.is_true(h2 < h1, "height should shrink")
    end)
  end)
end)
