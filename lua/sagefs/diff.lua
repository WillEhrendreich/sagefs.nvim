-- sagefs/diff.lua — Output diff between consecutive cell evaluations
-- Pure Lua, no vim dependencies.

local M = {}

local function split_lines(s)
  if not s or s == "" then return {} end
  local lines = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

--- Compute a line-level diff between two outputs.
---@param old_output string|nil
---@param new_output string|nil
---@return table[] {kind, old, new}
function M.diff_lines(old_output, new_output)
  local old_lines = split_lines(old_output)
  local new_lines = split_lines(new_output)
  local result = {}
  local max_len = math.max(#old_lines, #new_lines)
  for i = 1, max_len do
    local ol = old_lines[i]
    local nl = new_lines[i]
    if ol and nl then
      if ol == nl then
        result[#result + 1] = { kind = "unchanged", old = ol, new = nl }
      else
        result[#result + 1] = { kind = "changed", old = ol, new = nl }
      end
    elseif nl then
      result[#result + 1] = { kind = "added", new = nl }
    else
      result[#result + 1] = { kind = "removed", old = ol }
    end
  end
  return result
end

--- Format diff for virtual text display.
---@param diff_result table[] from diff_lines
---@return table[] {text, hl}
function M.format_diff(diff_result)
  local formatted = {}
  for _, d in ipairs(diff_result) do
    if d.kind == "changed" then
      formatted[#formatted + 1] = { text = "- " .. d.old, hl = "DiffDelete" }
      formatted[#formatted + 1] = { text = "+ " .. d.new, hl = "DiffAdd" }
    elseif d.kind == "added" then
      formatted[#formatted + 1] = { text = "+ " .. d.new, hl = "DiffAdd" }
    elseif d.kind == "removed" then
      formatted[#formatted + 1] = { text = "- " .. d.old, hl = "DiffDelete" }
    else
      formatted[#formatted + 1] = { text = "  " .. d.new, hl = "Comment" }
    end
  end
  return formatted
end

--- Compute a summary string.
---@param diff_result table[]
---@return string
function M.diff_summary(diff_result)
  local changed, added, removed = 0, 0, 0
  for _, d in ipairs(diff_result) do
    if d.kind == "changed" then changed = changed + 1
    elseif d.kind == "added" then added = added + 1
    elseif d.kind == "removed" then removed = removed + 1
    end
  end
  if changed == 0 and added == 0 and removed == 0 then return "no changes" end
  local parts = {}
  if changed > 0 then parts[#parts + 1] = changed .. " changed" end
  if added > 0 then parts[#parts + 1] = added .. " added" end
  if removed > 0 then parts[#parts + 1] = removed .. " removed" end
  return table.concat(parts, ", ")
end

return M
