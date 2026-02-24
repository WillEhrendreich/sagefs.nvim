-- sagefs/diagnostics.lua — Pure diagnostics parsing and transformation
-- No vim API dependencies — fully testable with busted
local M = {}

--- Group diagnostics by file path
---@param diags table[] Raw diagnostics from SageFs
---@return table<string, table[]> Diagnostics grouped by file
function M.group_by_file(diags)
  local groups = {}
  for _, d in ipairs(diags) do
    local file = d.file or ""
    if not groups[file] then
      groups[file] = {}
    end
    table.insert(groups[file], d)
  end
  return groups
end

local SEVERITY_MAP = {
  error = 1,
  warning = 2,
  info = 3,
  hint = 4,
}

--- Convert severity string to numeric level (vim.diagnostic compatible)
---@param severity string "error"|"warning"|"info"|"hint"
---@return number 1=error, 2=warning, 3=info, 4=hint
function M.severity_to_level(severity)
  return SEVERITY_MAP[severity] or 4
end

--- Convert raw SageFs diagnostic to vim.diagnostic-shaped table
---@param raw table Raw diagnostic from SageFs
---@return table vim.diagnostic-compatible table (0-indexed lines/cols)
function M.to_vim_diagnostic(raw)
  return {
    lnum = (raw.startLine or 1) - 1,
    col = (raw.startColumn or 1) - 1,
    end_lnum = (raw.endLine or raw.startLine or 1) - 1,
    end_col = (raw.endColumn or raw.startColumn or 1) - 1,
    message = raw.message or "",
    severity = M.severity_to_level(raw.severity or "hint"),
    source = "sagefs",
  }
end

return M
