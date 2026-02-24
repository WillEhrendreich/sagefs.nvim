-- sagefs/export.lua — Pure FSI session export formatting
-- Formats FSI events as .fsx script content
-- Zero vim dependencies

local M = {}

-- ─── Format as .fsx ───────────────────────────────────────────────────────────

function M.format_fsx(events)
  local parts = {}
  for _, ev in ipairs(events) do
    if ev.source ~= "hotreload" then
      local code = ev.code or ""
      table.insert(parts, code)
      if ev.result and ev.result ~= "" then
        table.insert(parts, "// " .. ev.result)
      end
      table.insert(parts, "")
    end
  end
  if #parts == 0 then return "" end
  return table.concat(parts, "\n")
end

return M
