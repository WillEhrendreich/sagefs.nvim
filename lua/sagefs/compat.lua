-- sagefs/compat.lua: Does this plugin speak the daemon's wire contract?
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

--- What this plugin release reads off the wire, declared as the question "if a
--- daemon does not send this, does anything break?" rather than as a version
--- range. Every entry is a field the plugin ADDS to what the daemon has always
--- sent, so each one is optional and its absence must degrade to "shows nothing".
---
--- The list exists because a wire field that arrives quietly is the one way this
--- plugin can be wrong without a test noticing: a new daemon adds a field, the
--- plugin reads it, and against every older daemon the reading is `nil`. Anything
--- listed here must have a degradation spec that feeds a payload WITHOUT the field
--- and asserts nothing is claimed. `spec/compat_spec.lua` walks this list, so a
--- field cannot be added without its degradation being declared.
---
--- `daemon` records where the field was verified, so a reader can tell a field
--- the daemon sends today from one that is only aspirational.
M.fields = {
  { name = "lastReload.reasons", daemon = "SessionReload.toWire drops it", used = false,
    note = "the daemon has ReloadFacts.Reasons but SessionReload.toWire (SageFs.Core/SessionReload.fs:183) does not write it, so the plugin never receives it and shows the cause parsed out of `message` instead" },
  { name = "lastReload.kept", daemon = "SessionReload.toWire drops it", used = false,
    note = "KeptStateReport is read off the worker payload (DevReload.fs:324) but SessionReload.toWire does not write it, so the plugin shows the plain KeptLiveState verdict" },
  { name = "lastReload.declarations", daemon = "SessionReload.toWire drops it", used = false,
    note = "parsed off the worker payload (SessionReload.fs:158) and not written back out, so the plugin never sees it" },
  { name = "exec.replFreshness", daemon = "McpServer.fs:2193 /exec writes only {success, result}",
    used = "banner",
    note = "the daemon puts the WARNING sentence in `result` and no structured field, so the plugin reads the one it is actually sent" },
  { name = "test_run_completed.source", daemon = "no such SSE event exists", used = false,
    note = "the daemon's SSE registry (SseWriter.allSseEventTypes) has no test_run_* event; the per-run source exists only in the run_tests receipt (TestRunReceipt.fs:316), which is a different transport" },
}

--- The fields this plugin release actually reads, so a caller can name them.
---@return string[]
function M.fields_in_use()
  local out = {}
  for _, f in ipairs(M.fields) do
    if f.used then out[#out + 1] = f.name end
  end
  return out
end

local UPDATE_DAEMON = "dotnet tool update --global sagefs"

---@class sagefs.CompatResult
---@field status "compatible"|"daemon_too_old"|"plugin_too_old"|"unknown"
---@field message string
---@field advice string|nil
---@field warn boolean true only for a real incompatibility

--- Largest apiVersion magnitude the plugin will take at face value. Real api
--- versions are small integers; anything beyond int32 is a malformed answer.
local MAX_API_VERSION = 2147483647

local function unknown(message)
  return { status = "unknown", message = message, warn = false }
end

--- Turn whatever the daemon sent into a whole number, or say why it cannot.
--- Numeric strings ("3") are accepted as that number.
---@return number|nil api_version
---@return string|nil problem a ready-made message when there is no usable number
local function usable_api_version(raw)
  local n = raw
  if type(raw) == "string" then
    local trimmed = raw:match("^%s*(.-)%s*$")
    n = trimmed:match("^[%+%-]?[%d%.]+$") and tonumber(trimmed) or nil
    if n == nil then
      return nil, string.format('daemon api version is not a number: "%s"', raw)
    end
  elseif type(raw) ~= "number" then
    return nil, string.format("daemon api version is not a number: %s",
      type(raw) == "boolean" and tostring(raw) or ("a " .. type(raw)))
  end
  if n ~= n or n == math.huge or n == -math.huge
    or n ~= math.floor(n) or math.abs(n) > MAX_API_VERSION then
    return nil, string.format("daemon api version is not a whole number the plugin can compare: %s", tostring(raw))
  end
  return math.floor(n)
end

--- Judge a daemon's apiVersion against the declared range.
---@param api_version any the `apiVersion` the daemon reported
---@return sagefs.CompatResult
function M.check(api_version)
  local r = M.api_range
  if api_version == nil then
    return unknown(string.format(
      "plugin understands api %d to %d, daemon api version not known yet (connect to a daemon to check)",
      r.min, r.max))
  end

  local n, problem = usable_api_version(api_version)
  if not n then
    return unknown(string.format("plugin understands api %d to %d, but the %s", r.min, r.max, problem))
  end
  api_version = n

  local range = r.min == r.max and tostring(r.min) or string.format("%d to %d", r.min, r.max)

  if api_version < r.min then
    return {
      status = "daemon_too_old",
      message = string.format("daemon speaks api %d, this plugin needs api %s (%s)",
        api_version, range, r.min_reason),
      advice = "update the daemon (" .. UPDATE_DAEMON .. ")",
      warn = true,
    }
  end

  if api_version > r.max then
    return {
      status = "plugin_too_old",
      message = string.format("daemon speaks api %d, this plugin understands api %s (%s)",
        api_version, range, r.max_reason),
      advice = "update the plugin (pull the latest sagefs.nvim; its version tracks the SageFs release)",
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
  return string.format("%s. Some features may not work, so %s. Run :checkhealth sagefs for details.",
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
