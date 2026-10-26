local util = require("sagefs.util")

local M = {}

--- The two words the daemon writes in `totalKind` (CompletionTotal.label in
--- SageFs.Core/Features/AutoCompletion.fs). Any other word is not read.
local TOTAL_KINDS = { exact = true, atLeast = true }

--- What one /api/completions reply says: the candidates, how large the set they
--- were cut from is, and whether the daemon could not look at all.
---
--- Every field after `completions` is optional on the wire. A daemon that
--- predates `total`/`totalKind`/`unavailable` sends none of them, and the
--- listing then states no size and no unavailability, which renders as it
--- always did.
---@param data table|nil a decoded reply
---@return { completions: table[], total: number|nil, total_kind: string|nil, unavailable: { word: string, reason: string|nil }|nil }
function M.listing_of(data)
  local listing = { completions = {} }
  if type(data) ~= "table" then return listing end
  if type(data.completions) == "table" then listing.completions = data.completions end
  if type(data.total) == "number" and TOTAL_KINDS[data.totalKind] then
    listing.total = data.total
    listing.total_kind = data.totalKind
  end
  if type(data.unavailable) == "string" and data.unavailable ~= "" then
    listing.unavailable = {
      word = data.unavailable,
      reason = type(data.reason) == "string" and data.reason ~= "" and data.reason or nil,
    }
  end
  return listing
end

--- "Showing 50 of 212" when the reply was cut from a larger set, "Showing 200 of
--- at least 2000" when the daemon only knows a floor, nil when it states no size
--- or the set was shown whole. A floor always means more may exist; an exact
--- total means more exists only when it exceeds the rows shown.
---@param listing table from listing_of
---@return string|nil
function M.size_line(listing)
  if not listing or not listing.total then return nil end
  local shown = #listing.completions
  if listing.total_kind == "atLeast" then
    return string.format("Showing %d of at least %d", shown, listing.total)
  end
  if listing.total > shown then
    return string.format("Showing %d of %d", shown, listing.total)
  end
  return nil
end

--- The line for a reply that could not list: an empty list there means "nobody
--- could look", which is not "nothing is there". nil for a reply that could list.
---@param listing table from listing_of
---@return string|nil
function M.unavailable_line(listing)
  local u = listing and listing.unavailable
  if not u then return nil end
  return "Could not list members: " .. (u.reason or u.word)
end

function M.parse_response(raw)
  if not raw then return {} end
  local ok, data = util.json_decode(raw)
  if not ok or not data or not data.completions then return {} end

  local items = {}
  for _, c in ipairs(data.completions) do
    items[#items + 1] = {
      word = c.insertText or c.label,
      abbr = c.label,
      kind = c.kind or "",
      menu = "[SageFs]",
    }
  end
  return items
end

--- The popup's request. It sends no `limit`: the popup wants the daemon's short
--- default list, and the type explorer (type_explorer.build_request_body) is the
--- caller that asks for more.
function M.build_request_body(code, cursor_position, working_directory)
  return {
    code = code,
    cursor_position = cursor_position,
    working_directory = working_directory or "",
  }
end

return M
