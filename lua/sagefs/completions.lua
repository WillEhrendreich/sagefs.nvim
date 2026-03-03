local util = require("sagefs.util")

local M = {}

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

function M.build_request_body(code, cursor_position, session_id)
  return {
    code = code,
    cursorPos = cursor_position,
    sessionId = session_id or "",
  }
end

return M
