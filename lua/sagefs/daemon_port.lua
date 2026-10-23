-- sagefs/daemon_port — the one rule for which port the daemon binds, and which port a client asks for.
--
-- Mirrors `SageFs.Core/DaemonPort.fs`: `SAGEFS_MCP_PORT`, then the port the Settings panel persisted
-- (`daemon.mcpPort` in the data directory's settings.json), then 37749. A client that resolves this
-- differently from the daemon is talking to a daemon that is not there, which is exactly what happened
-- the day the Settings panel started being read: this plugin only knew about the environment.
local M = {}

local default_port = 37749

--- The rule, as a decision: environment, then the persisted panel value, then the default. Everything
--- the IO edge cannot reach is passed in, so the order is testable without a filesystem or a parser.
---@param env_port string|number|nil raw SAGEFS_MCP_PORT, or nil when unset
---@param persisted_port string|number|nil raw `daemon.mcpPort`, or nil when the settings file says nothing
---@param fallback integer|nil what to return when neither names a port (defaults to 37749)
---@return integer
function M.choose(env_port, persisted_port, fallback)
  local env = tonumber(env_port)
  if env then return env end
  local persisted = tonumber(persisted_port)
  if persisted then return persisted end
  return fallback or default_port
end

--- Read `daemon.mcpPort` out of the data directory's settings.json, or nil for: no file, no key, a
--- file that will not parse, or a value that is not a number. Every failure is nil rather than an
--- error: a client that cannot read the settings still has to find the daemon by the other two
--- sources.
---@return string|nil
local function persisted_port()
  local data_dir = vim.env and vim.env.SAGEFS_DATA_DIR
  if data_dir == nil or data_dir == "" then
    data_dir = (os.getenv("HOME") or "") .. "/.SageFs"
  end
  if data_dir == "" then return nil end
  local handle = io.open(data_dir .. "/settings.json", "r")
  if not handle then return nil end
  local text = handle:read("*a")
  handle:close()
  if not text or text == "" then return nil end
  local ok, parsed = pcall(function() return vim.json.decode(text) end)
  if not ok or type(parsed) ~= "table" then return nil end
  return parsed["daemon.mcpPort"]
end

--- The port a plain `sagefs` binds. The IO edge around `choose`, guarded end to end: nothing here
--- raises, because a settings file that cannot be read must not stop the plugin finding the daemon.
---@return integer
function M.configured()
  local ok, persisted = pcall(persisted_port)
  if not ok then persisted = nil end
  return M.choose(vim.env and vim.env.SAGEFS_MCP_PORT, persisted, default_port)
end

return M
