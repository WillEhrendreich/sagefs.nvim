-- sagefs/placement.lua — Where a cell's result is drawn
-- Pure Lua, no vim API dependencies — fully testable with busted.
--
-- The old rule was "at the cell's last line". A cell taller than the window
-- has its last line off screen, so pressing <A-CR> showed nothing at all.
-- The rule now: the result is anchored on a line of the cell that is on
-- screen, and everything drawn below that line fits in the window. What does
-- not fit is counted and announced by a footer, never silently clipped.
local M = {}

--- Default cap on result rows drawn under a cell before the footer takes over.
M.DEFAULT_MAX_LINES = 12

--- The fewest rows worth anchoring a result on when more would not fit:
--- two lines of output plus the footer.
M.MIN_ROWS = 3

---@class sagefs.PlacementInput
---@field cell_start number  1-indexed first line of the cell
---@field cell_end number    1-indexed last line of the cell
---@field anchor number|nil  line the user evaluated from (cursor), if known
---@field top number         first visible buffer line (1-indexed)
---@field bot number         last visible buffer line (1-indexed)
---@field rows number        window height in screen rows
---@field height number      rows the whole result needs
---@field max_lines number|nil  cap on result rows drawn (default DEFAULT_MAX_LINES)
---@field rows_through (fun(line: number): number)|nil
---   screen rows used by buffer lines `top..line` inclusive, counting wraps and
---   virtual lines the caller knows about. Default: one row per line.

---@class sagefs.Placement
---@field line number     1-indexed line the result hangs off (inline text + virtual lines below)
---@field shown number    result rows to draw
---@field hidden number   result rows not drawn
---@field footer boolean  draw the "N more lines, <key> to expand" row
---@field visible boolean the cell has at least one line on screen

local function clamp(n, lo, hi)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

--- Decide where to draw a result.
---@param a sagefs.PlacementInput
---@return sagefs.Placement
function M.place(a)
  local height = math.max(a.height or 0, 0)
  local max_lines = math.max(a.max_lines or M.DEFAULT_MAX_LINES, 1)
  local lo = math.max(a.cell_start, a.top)
  local hi = math.min(a.cell_end, a.bot)

  if lo > hi then
    -- Nothing of the cell is on screen. There is nothing to protect; draw it
    -- the old way (at the cell's end) so it is right once the cell scrolls in.
    return {
      line = a.cell_end,
      shown = math.min(height, max_lines),
      hidden = math.max(height - max_lines, 0),
      footer = height > max_lines,
      visible = false,
    }
  end

  local rows_through = a.rows_through or function(line) return line - a.top + 1 end
  local function avail(line) return math.max(a.rows - rows_through(line), 0) end

  -- What we would like to draw, and the least we would settle for.
  local capped = math.min(height, max_lines)
  local full_rows = capped + ((height > max_lines) and 1 or 0)
  local min_rows = math.min(full_rows, M.MIN_ROWS)

  -- Preferred line: the cell's end when it is on screen (the old, right
  -- behaviour); otherwise where the user evaluated from; otherwise the last
  -- visible line of the cell.
  local preferred
  if a.cell_end >= lo and a.cell_end <= hi then
    preferred = a.cell_end
  elseif a.anchor then
    preferred = clamp(a.anchor, lo, hi)
  else
    preferred = hi
  end

  -- Walk up from the preferred line to the first one with room for everything;
  -- failing that, the first with room for the minimum; failing that, the top
  -- of the cell's visible part (the most room there is).
  local line, fallback
  for l = preferred, lo, -1 do
    local room = avail(l)
    if room >= full_rows then line = l; break end
    if not fallback and room >= min_rows then fallback = l end
  end
  line = line or fallback or lo

  local room = avail(line)
  local shown, footer
  if full_rows <= room then
    shown, footer = capped, height > max_lines
  elseif height <= room then
    shown, footer = height, false
  else
    -- Not enough room: use what is there, minus one row for the footer.
    footer = room >= 1
    shown = math.max(room - 1, 0)
  end

  return { line = line, shown = shown, hidden = height - shown, footer = footer, visible = true }
end

return M
