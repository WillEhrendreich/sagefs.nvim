require("spec.helper")
local placement = require("sagefs.placement")

-- Where a cell's result is drawn. The old rule was "at the cell's last line",
-- which put the result off screen whenever the cell was taller than the
-- window (a lemming pressed <A-CR> and saw nothing happen). The rule now is a
-- pure function of the cell range, the window and the result height, and the
-- property below is that the result is always inside the visible window.

--- Tiny seeded generator (busted has no FsCheck). LCG so runs are reproducible.
local function rng(seed)
  local state = seed
  return function(lo, hi)
    state = (state * 1103515245 + 12345) % 2147483648
    return lo + (state % (hi - lo + 1))
  end
end

local function case_from(next_int)
  local rows = next_int(2, 60)
  local top = next_int(1, 400)
  local bot = top + rows - 1
  local cell_start = next_int(1, 500)
  local cell_end = cell_start + next_int(0, 200)
  local anchor = next_int(cell_start, cell_end)
  return {
    rows = rows,
    top = top,
    bot = bot,
    cell_start = cell_start,
    cell_end = cell_end,
    anchor = anchor,
    height = next_int(1, 80),
    max_lines = next_int(3, 25),
  }
end

local function intersects(c)
  return math.max(c.cell_start, c.top) <= math.min(c.cell_end, c.bot)
end

describe("sagefs.placement.place", function()
  describe("preserved behaviour", function()
    it("puts a short result on the cell's last line when it is visible and fits", function()
      local p = placement.place({
        cell_start = 10, cell_end = 14, anchor = 11,
        top = 1, bot = 40, rows = 40, height = 3, max_lines = 12,
      })
      assert.are.equal(14, p.line)
      assert.are.equal(3, p.shown)
      assert.are.equal(0, p.hidden)
      assert.is_false(p.footer)
      assert.is_true(p.visible)
    end)

    it("single-line result needs no virtual lines beyond its one row", function()
      local p = placement.place({
        cell_start = 3, cell_end = 3, anchor = 3,
        top = 1, bot = 20, rows = 20, height = 1, max_lines = 12,
      })
      assert.are.equal(3, p.line)
      assert.are.equal(1, p.shown)
      assert.is_false(p.footer)
    end)
  end)

  describe("a cell taller than the window", function()
    it("anchors on the line the user evaluated from, not the off-screen end", function()
      -- cell 1..300, window shows 100..139, cursor was on 120
      local p = placement.place({
        cell_start = 1, cell_end = 300, anchor = 120,
        top = 100, bot = 139, rows = 40, height = 5, max_lines = 12,
      })
      assert.are.equal(120, p.line)
      assert.is_true(p.line >= 100 and p.line <= 139)
      assert.are.equal(5, p.shown)
    end)

    it("falls back to the last visible line of the cell when the anchor scrolled away", function()
      local p = placement.place({
        cell_start = 1, cell_end = 300, anchor = 5,
        top = 100, bot = 139, rows = 40, height = 2, max_lines = 12,
      })
      assert.is_true(p.line >= 100 and p.line <= 139)
      assert.is_true(p.visible)
    end)

    it("starts the cell above the window: the visible part is what counts", function()
      local p = placement.place({
        cell_start = 50, cell_end = 90, anchor = 60,
        top = 80, bot = 99, rows = 20, height = 4, max_lines = 12,
      })
      assert.are.equal(90, p.line) -- the cell's end is visible, so keep it
      assert.is_true(p.line >= p.line and p.line <= 99)
    end)
  end)

  describe("a tall result", function()
    it("truncates with a footer and reports how many lines are hidden", function()
      local p = placement.place({
        cell_start = 1, cell_end = 5, anchor = 5,
        top = 1, bot = 40, rows = 40, height = 50, max_lines = 12,
      })
      assert.are.equal(12, p.shown)
      assert.are.equal(38, p.hidden)
      assert.is_true(p.footer)
    end)

    it("never reports hidden lines without the footer that says so", function()
      local p = placement.place({
        cell_start = 1, cell_end = 5, anchor = 5,
        top = 1, bot = 10, rows = 10, height = 30, max_lines = 12,
      })
      assert.is_true(p.hidden > 0)
      assert.is_true(p.footer)
    end)

    it("moves up inside the cell when the cell end is at the very bottom of the window", function()
      -- the cell end is the last visible row: nothing would fit beneath it
      local p = placement.place({
        cell_start = 1, cell_end = 40, anchor = 40,
        top = 1, bot = 40, rows = 40, height = 6, max_lines = 12,
      })
      assert.is_true(p.line < 40)
      -- everything we draw fits in the window
      assert.is_true(p.line - 1 + 1 + p.shown + (p.footer and 1 or 0) <= 40)
    end)
  end)

  describe("a cell that is not on screen", function()
    it("says so instead of inventing a position inside the window", function()
      local p = placement.place({
        cell_start = 1, cell_end = 10, anchor = 5,
        top = 100, bot = 139, rows = 40, height = 3, max_lines = 12,
      })
      assert.is_false(p.visible)
    end)
  end)

  describe("rows_through", function()
    it("counts wrapped lines and virtual lines when the caller knows them", function()
      -- every buffer line costs two rows (e.g. all wrap): fewer rows are left
      local p = placement.place({
        cell_start = 1, cell_end = 8, anchor = 8,
        top = 1, bot = 10, rows = 20, height = 10, max_lines = 12,
        rows_through = function(line) return (line) * 2 end,
      })
      -- at line 8 only 20 - 16 = 4 rows remain; the result must not exceed them
      local used = (p.line * 2) + p.shown + (p.footer and 1 or 0)
      assert.is_true(used <= 20, "used " .. used .. " rows of 20")
    end)
  end)

  describe("property: the result is always inside the visible window", function()
    it("holds for 5000 generated windows, cells and result heights", function()
      local next_int = rng(20261002)
      local checked = 0
      for _ = 1, 5000 do
        local c = case_from(next_int)
        local p = placement.place(c)
        if intersects(c) then
          checked = checked + 1
          local lo = math.max(c.cell_start, c.top)
          local hi = math.min(c.cell_end, c.bot)
          local ctx = string.format("case rows=%d top=%d cell=%d..%d anchor=%d height=%d max=%d -> line=%s shown=%s hidden=%s footer=%s",
            c.rows, c.top, c.cell_start, c.cell_end, c.anchor, c.height, c.max_lines,
            tostring(p.line), tostring(p.shown), tostring(p.hidden), tostring(p.footer))
          assert.is_true(p.visible, ctx)
          -- anchored on a line of the cell that is on screen
          assert.is_true(p.line >= lo and p.line <= hi, "line out of range: " .. ctx)
          -- every row we draw lies inside the window
          local drawn = p.shown + (p.footer and 1 or 0)
          assert.is_true((p.line - c.top + 1) + drawn <= c.rows, "overflows window: " .. ctx)
          -- accounting: nothing is lost silently
          assert.are.equal(math.min(c.height, c.height), p.shown + p.hidden, "lost lines: " .. ctx)
          -- the one case with no room beneath the line at all (the cell's visible part is the
          -- window's last row): the inline text on the line itself is what the user sees
          local room = c.rows - (p.line - c.top + 1)
          if p.hidden > 0 and room >= 1 then assert.is_true(p.footer, "hidden without footer: " .. ctx) end
          -- something is always on screen for the user to see
          assert.is_true(drawn >= 1 or room < 1, "nothing drawn: " .. ctx)
        else
          assert.is_false(p.visible)
        end
      end
      assert.is_true(checked > 500, "generator produced too few intersecting cases: " .. checked)
    end)

    it("holds when rows are not one per line (random wrap and virtual line costs)", function()
      local next_int = rng(7)
      for _ = 1, 3000 do
        local c = case_from(next_int)
        -- cumulative row cost per line, 1..4 rows each, from `top`
        local cost = {}
        local acc = 0
        for l = c.top, c.top + c.rows + 5 do
          acc = acc + next_int(1, 4)
          cost[l] = acc
        end
        c.rows_through = function(line) return cost[line] or (acc + (line - (c.top + c.rows + 5))) end
        local p = placement.place(c)
        if intersects(c) and p.visible then
          local lo = math.max(c.cell_start, c.top)
          local hi = math.min(c.cell_end, c.bot)
          assert.is_true(p.line >= lo and p.line <= hi)
          local drawn = p.shown + (p.footer and 1 or 0)
          local avail = c.rows - c.rows_through(p.line)
          -- either what we draw fits, or there was no room at all on the topmost line
          assert.is_true(drawn <= math.max(avail, 0), string.format("drawn %d > avail %d", drawn, avail))
        end
      end
    end)
  end)
end)
