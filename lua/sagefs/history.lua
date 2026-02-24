-- sagefs/history.lua — Pure FSI event history formatting
-- Formats get_recent_fsi_events responses for picker and preview
-- Zero vim dependencies

local M = {}

local json_decode = (vim and vim.json and vim.json.decode)
  or (vim and vim.fn and vim.fn.json_decode)
  or (function()
    local ok, dkjson = pcall(require, "dkjson")
    if ok then return dkjson.decode end
    return function() return nil, "no json decoder" end
  end)()

-- ─── Format Events for Picker ─────────────────────────────────────────────────

function M.format_events(events)
  local items = {}
  for _, ev in ipairs(events) do
    local code_preview = ev.code or ""
    if #code_preview > 100 then
      code_preview = code_preview:sub(1, 97) .. "..."
    end
    local source_icon = ev.source == "hotreload" and "⟳" or "▶"
    local label = string.format("%s %s  %s", source_icon, code_preview, ev.timestamp or "")
    if #label > 140 then label = label:sub(1, 137) .. "..." end
    table.insert(items, {
      label = label,
      code = ev.code or "",
      result = ev.result or "",
      timestamp = ev.timestamp or "",
      source = ev.source or "",
    })
  end
  return items
end

-- ─── Format Preview ───────────────────────────────────────────────────────────

function M.format_preview(event)
  local lines = {}
  table.insert(lines, string.format("── %s (%s) ──", event.source or "unknown", event.timestamp or ""))
  table.insert(lines, "")
  table.insert(lines, "Code:")
  for line in (event.code or ""):gmatch("[^\n]+") do
    table.insert(lines, "  " .. line)
  end
  table.insert(lines, "")
  table.insert(lines, "Result:")
  for line in (event.result or ""):gmatch("[^\n]+") do
    table.insert(lines, "  " .. line)
  end
  return lines
end

-- ─── Parse Server Response ────────────────────────────────────────────────────

function M.parse_events_response(json_str)
  if not json_str or json_str == "" then
    return nil, "empty input"
  end
  local ok, data = pcall(json_decode, json_str)
  if not ok or not data then
    return nil, "invalid JSON"
  end
  return data, nil
end

return M
