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

-- ─── JSON decode helper ──────────────────────────────────────────────────────

local json_decode = require("sagefs.util").json_decode

--- Parse a DiagnosticsUpdated SSE data payload
---@param json_str string|nil
---@return table[]|nil diagnostics, string|nil error
function M.parse_sse_payload(json_str)
  if not json_str or json_str == "" then
    return nil, "empty payload"
  end
  local ok, data = json_decode(json_str)
  if not ok or type(data) ~= "table" then
    return nil, "invalid JSON"
  end
  return data.diagnostics or {}, nil
end

--- Convert a list of raw diagnostics to vim.diagnostic format
---@param raw_list table[]
---@return table[]
function M.to_vim_diagnostics(raw_list)
  local result = {}
  for _, raw in ipairs(raw_list) do
    table.insert(result, M.to_vim_diagnostic(raw))
  end
  return result
end

--- Full cycle: parse SSE data → group by file → convert to vim diagnostics
---@param json_str string
---@return table<string, table[]>|nil groups, string|nil error
function M.process_sse_event(json_str)
  local diags, err = M.parse_sse_payload(json_str)
  if err then return nil, err end
  local grouped = M.group_by_file(diags)
  local result = {}
  for file, file_diags in pairs(grouped) do
    result[file] = M.to_vim_diagnostics(file_diags)
  end
  return result, nil
end

--- Parse a check_fsharp_code response (same shape as SSE diagnostics)
---@param raw string|nil
---@return table<string, table[]>|nil groups, string|nil error
function M.parse_check_response(raw)
  return M.process_sse_event(raw)
end

return M
