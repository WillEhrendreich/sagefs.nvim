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

--- Run tasks in parallel and collect results in order.
--- Each task is a function(done) where done(result) signals completion.
--- on_done(results) is called exactly once when all tasks complete.
---@param tasks function[] array of function(done)
---@param on_done function called with results array when all complete
function M.async_all(tasks, on_done)
  local count = #tasks
  if count == 0 then
    on_done({})
    return
  end
  local results = {}
  local remaining = count
  local finished = false
  for i, task in ipairs(tasks) do
    task(function(result)
      if finished then return end
      results[i] = result
      remaining = remaining - 1
      if remaining == 0 then
        finished = true
        on_done(results)
      end
    end)
  end
end

return M
