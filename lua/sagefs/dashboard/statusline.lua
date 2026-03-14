-- sagefs/dashboard/statusline.lua — Pure statusline component
-- Pure Lua, zero vim dependencies, fully testable with busted
--
-- Returns a compact string for statusline/winbar/lualine integration.
-- Usage: require("sagefs.dashboard.statusline").get(state)

local M = {}

--- Render a compact statusline string from dashboard state.
--- @param state table|nil
--- @return string
function M.get(state)
  if not state then return "" end

  local parts = {}

  -- Connection indicator
  local daemon = state.daemon or {}
  if daemon.connected then
    table.insert(parts, "⚡")
  else
    table.insert(parts, "⏻")
    return table.concat(parts, " ")
  end

  -- Testing summary (only when enabled)
  local testing = state.testing or {}
  if testing.enabled then
    local s = testing.summary or {}
    local passed = s.passed or 0
    local failed = s.failed or 0
    if failed > 0 then
      table.insert(parts, string.format("✓%d ✗%d", passed, failed))
    elseif passed > 0 then
      table.insert(parts, string.format("✓%d", passed))
    end
  end

  -- Hot reload indicator
  local hr = state.hot_reload or {}
  if hr.enabled then
    table.insert(parts, string.format("🔄%d", hr.total_files or 0))
  end

  -- Last eval duration
  local eval = state.eval or {}
  if eval.duration_ms then
    table.insert(parts, string.format("%dms", eval.duration_ms))
  end

  return table.concat(parts, " ")
end

return M
