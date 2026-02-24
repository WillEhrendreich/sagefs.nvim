-- sagefs/util.lua — Shared utilities
-- Zero vim dependencies — fully testable with busted

local M = {}

--- Decode a JSON string, trying available decoders
---@param s string|nil
---@return boolean ok, any data
function M.json_decode(s)
  if not s or s == "" then
    return false, "empty input"
  end
  if vim and vim.json and vim.json.decode then
    local ok, data = pcall(vim.json.decode, s)
    if ok and data == nil then return false, "decode returned nil" end
    return ok, data
  elseif vim and vim.fn and vim.fn.json_decode then
    local ok, data = pcall(vim.fn.json_decode, s)
    if ok and data == nil then return false, "decode returned nil" end
    return ok, data
  end
  return false, "no JSON decoder available"
end

return M
