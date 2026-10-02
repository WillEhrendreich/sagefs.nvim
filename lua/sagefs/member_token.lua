-- sagefs/member_token.lua: the member capability token and how to keep it quiet
--
-- A conductor mints a token per agent run with the daemon's `mint_member` tool
-- (`sfm_` plus 43 URL-safe characters). A client presents it in the
-- `X-SageFs-Member-Token` header and the daemon treats that client as the
-- minted member: its role, its scope, its expiry. SageFs keeps only the
-- token's hash, so a token that lands in a log, a message or a screen cannot be
-- taken back, only revoked. Everything here is pure except `current`, which
-- reads the plugin's config and the environment.
--
-- The rule for the rest of the plugin: the token goes into the request header
-- and nowhere else. Anything that prints a header, an error or a config goes
-- through `redact`, `redact_headers` or `describe`.

local M = {}

--- The request header the daemon reads.
M.HEADER = "X-SageFs-Member-Token"

--- The environment variable `sagefs mcp` reads, read here too so one variable
--- configures the bridge and the plugin.
M.ENV = "SAGEFS_MEMBER_TOKEN"

local HIDDEN = "(hidden)"

--- The token to use: the setup option, else the environment. Unset, empty and
--- blank mean none, so no header goes out.
---@param option any the `member_token` setup option
---@param env any the SAGEFS_MEMBER_TOKEN value
---@return string|nil
function M.resolve(option, env)
  local function usable(candidate)
    if type(candidate) ~= "string" then return nil end
    local trimmed = candidate:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then return nil end
    return trimmed
  end
  return usable(option) or usable(env)
end

--- Replace a token in a text: the configured one wherever it appears, and
--- anything shaped like a minted token, so an echo of some other token is
--- hidden too.
---@param text string|nil
---@param token string|nil
---@return string
function M.redact(text, token)
  if type(text) ~= "string" then return "" end
  if type(token) == "string" and token ~= "" then
    local out, from = {}, 1
    while true do
      local i, j = text:find(token, from, true)
      if not i then break end
      out[#out + 1] = text:sub(from, i - 1)
      out[#out + 1] = "sfm_" .. HIDDEN
      from = j + 1
    end
    out[#out + 1] = text:sub(from)
    text = table.concat(out)
  end
  return (text:gsub("sfm_[A-Za-z0-9_%-]+", "sfm_" .. HIDDEN))
end

--- A copy of a header table that is safe to print.
---@param headers table<string,string>|nil
---@return table<string,string>
function M.redact_headers(headers)
  local safe = {}
  for name, value in pairs(headers or {}) do
    if tostring(name):lower() == M.HEADER:lower() then
      safe[name] = HIDDEN
    else
      safe[name] = value
    end
  end
  return safe
end

--- How a config display says whether a token is set.
---@param token string|nil
---@return string
function M.describe(token)
  if M.resolve(token, nil) then return "set " .. HIDDEN end
  return "not set"
end

--- The token in force now: the plugin's `member_token` option, else the
--- environment. Read on every request, so a setup() after a client was made
--- still counts. Does not load the plugin.
---@return string|nil
function M.current()
  local plugin = package.loaded["sagefs"]
  local option = type(plugin) == "table" and type(plugin.config) == "table" and plugin.config.member_token or nil
  return M.resolve(option, vim.env and vim.env[M.ENV] or nil)
end

return M
