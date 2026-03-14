-- sagefs/dashboard/compositor.lua — Section composition with line offsets
-- Pure Lua, zero vim dependencies, fully testable with busted
--
-- Sections form a monoid under vertical concatenation:
-- - identity: empty SectionOutput { lines = {}, highlights = {}, keymaps = {} }
-- - binary op: concatenate lines, offset highlights and keymaps by cumulative line count

local M = {}

--- Compose a list of SectionOutputs into a single output.
--- Each SectionOutput = { section_id, lines, highlights, keymaps }
--- Options:
---   separator: string — optional line to insert between sections
--- @param outputs table[] list of SectionOutput
--- @param opts table|nil { separator: string|nil }
--- @return table ComposedOutput with .lines, .highlights, .keymaps, .section_ranges
function M.compose(outputs, opts)
  opts = opts or {}
  local sep = opts.separator

  local result = {
    lines = {},
    highlights = {},
    keymaps = {},
    section_ranges = {},
  }

  local offset = 0

  for i, output in ipairs(outputs) do
    -- Insert separator between sections (not before first)
    if sep and i > 1 then
      table.insert(result.lines, sep)
      offset = offset + 1
    end

    -- Record section range
    local start_line = offset
    table.insert(result.section_ranges, {
      start_line = start_line,
      end_line = start_line + #output.lines - 1,
      section_id = output.section_id or "",
    })

    -- Append lines
    for _, line in ipairs(output.lines) do
      table.insert(result.lines, line)
    end

    -- Offset and append highlights
    for _, hl in ipairs(output.highlights or {}) do
      table.insert(result.highlights, {
        line = hl.line + offset,
        col_start = hl.col_start,
        col_end = hl.col_end,
        hl_group = hl.hl_group,
      })
    end

    -- Offset and append keymaps
    for _, km in ipairs(output.keymaps or {}) do
      table.insert(result.keymaps, {
        line = km.line + offset,
        key = km.key,
        action = km.action,
      })
    end

    offset = offset + #output.lines
  end

  return result
end

--- Find which section a given line belongs to.
--- @param section_ranges table[] from compose result
--- @param line number 0-based line number
--- @return string|nil section_id
function M.section_at_line(section_ranges, line)
  for _, range in ipairs(section_ranges) do
    if line >= range.start_line and line <= range.end_line then
      return range.section_id
    end
  end
  return nil
end

return M
