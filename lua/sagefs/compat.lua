-- sagefs/compat.lua — Does this plugin speak the daemon's wire contract?
-- Pure Lua, no vim dependency.
--
-- Two different questions, deliberately kept apart:
--
--   1. Can they talk?  Decided ONLY by the daemon's integer `apiVersion`
--      (on /health and /version) against the closed range declared below.
--      This is the one thing that may produce a warning.
--   2. Do they carry the same release number?  The plugin is released in
--      lockstep with SageFs (lua/sagefs/version.lua is the SageFs release it
--      was tested against), so a different number is worth a quiet info line
--      in :checkhealth and nothing more.

local M = {}

--- The apiVersion range this plugin release understands. The daemon's
--- EndpointContracts.apiVersion is bumped whenever a route is added, removed
--- or changes shape, so a number outside the range means a route the plugin
--- calls may be missing or have a different shape. Edit this table, and only
--- this table, when a release changes what the plugin calls.
M.api_range = {
  min = 3,
  min_reason = "api 3 added POST /api/sessions/{sid}/run-app and /stop-app, which :SageFsRunApp and :SageFsStopApp call",
  max = 3,
  max_reason = "api 3 is the newest contract this plugin release was tested against",
}

local UPDATE_DAEMON = "dotnet tool update --global sagefs"

---@class sagefs.CompatResult
---@field status "compatible"|"daemon_too_old"|"plugin_too_old"|"unknown"
---@field message string
---@field advice string|nil
---@field warn boolean true only for a real incompatibility

--- Judge a daemon's apiVersion against the declared range.
---@param api_version any the `apiVersion` the daemon reported
---@return sagefs.CompatResult
function M.check(api_version)
  local r = M.api_range
  if type(api_version) ~= "number" then
    return {
      status = "unknown",
      message = string.format(
        "plugin understands api %d to %d, daemon api version not known yet (connect to a daemon to check)",
        r.min, r.max),
      warn = false,
    }
  end

  local range = r.min == r.max and tostring(r.min) or string.format("%d to %d", r.min, r.max)

  if api_version < r.min then
    return {
      status = "daemon_too_old",
      message = string.format("daemon speaks api %d, this plugin needs api %s (%s)",
        api_version, range, r.min_reason),
      advice = "update the daemon: " .. UPDATE_DAEMON,
      warn = true,
    }
  end

  if api_version > r.max then
    return {
      status = "plugin_too_old",
      message = string.format("daemon speaks api %d, this plugin understands api %s (%s)",
        api_version, range, r.max_reason),
      advice = "update the plugin: pull the latest sagefs.nvim (its version tracks the SageFs release)",
      warn = true,
    }
  end

  return {
    status = "compatible",
    message = string.format("plugin understands api %s, daemon speaks api %d: compatible", range, api_version),
    warn = false,
  }
end

--- The one-line startup warning for a real incompatibility, or nil.
---@param api_version any
---@return string|nil
function M.startup_warning(api_version)
  local r = M.check(api_version)
  if not r.warn then return nil end
  return string.format("[SageFs] %s. Some features may not work: %s. Run :checkhealth sagefs for details.",
    r.message, r.advice)
end

--- Compare release numbers (major.minor.patch; a fourth part or a +build
--- suffix is ignored). Information only, never a reason to warn.
---@param plugin_version any
---@param daemon_version any
---@return "same"|"plugin_older"|"plugin_newer"|"unknown"
function M.version_relation(plugin_version, daemon_version)
  local function parse(v)
    if type(v) ~= "string" then return nil end
    local a, b, c = v:match("(%d+)%.(%d+)%.(%d+)")
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) }
  end
  local p, d = parse(plugin_version), parse(daemon_version)
  if not p or not d then return "unknown" end
  for i = 1, 3 do
    if p[i] < d[i] then return "plugin_older" end
    if p[i] > d[i] then return "plugin_newer" end
  end
  return "same"
end

return M
