-- sagefs/util.lua — Shared utilities
-- Zero vim dependencies — fully testable with busted

local M = {}

--- Decode a JSON string, trying available decoders
---@param s string|nil
---@return boolean ok, any data
--- Two paths name the same file: equal after separator normalization, or one is
--- relative (a path relative to the project) and the other, absolute, ends with
--- it on a whole path component. Two absolute paths never match by suffix:
--- /b/a/Util.fs is not /a/Util.fs.
---@param a string|nil
---@param b string|nil
---@return boolean
function M.paths_match(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or a == "" or b == "" then return false end
  a, b = a:gsub("\\", "/"), b:gsub("\\", "/")
  if a == b then return true end
  local short, long = a, b
  if #short > #long then short, long = long, short end
  if #short == #long then return false end
  local relative = short:sub(1, 1) ~= "/" and not short:match("^%a:/")
  return relative and long:sub(-(#short + 1)) == "/" .. short
end

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

--- Extract a human-facing error message from a decoded JSON error body,
--- preferring the server's structured remedy (`suggestedAction`) wherever
--- the shape carries one, so callers stop discarding it. Handles the two
--- shapes the daemon actually sends:
---   flat:   { message, suggestedAction }                (case/fields optional)
---   nested: { success=false, error=<string>, errorDetails={message, suggestedAction} }
--- Falls back to the raw response text, then to a generic message, so a
--- connection-level failure (no body at all) still produces something
--- readable instead of erroring.
---@param parsed table|nil decoded JSON body, or nil if decoding failed
---@param raw string|nil the raw response text, used as a fallback
---@return string
function M.format_server_error(parsed, raw)
  if type(parsed) == "table" then
    local details = (type(parsed.errorDetails) == "table") and parsed.errorDetails or parsed
    local msg = details.message or details.Message
      or parsed.error or parsed.Error
      or details.reason or details.Reason
      or "Unknown error"
    local action = details.suggestedAction or details.SuggestedAction or ""
    if action ~= "" then
      return msg .. " → " .. action
    end
    return msg
  end
  if raw and raw ~= "" then
    return raw
  end
  return "Unknown error"
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
