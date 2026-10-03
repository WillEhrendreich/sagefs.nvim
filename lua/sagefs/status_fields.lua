-- sagefs/status_fields.lua — the registry of per-session report fields
-- Pure Lua, zero vim dependencies
--
-- Every session report the daemon sends (GET /api/sessions, the sessions://list
-- JSON, get_session_status) carries closed fields that say something true about
-- the session: `lastReload` (what the last save did), `replFreshness` (whether the
-- REPL runs the app's build), `sourceState` (whether the build is behind the files on
-- disk), `lastRestart` (what the last rebuild did). The plugin reads them here and
-- nowhere else. A new field the daemon adds next is ONE entry in FIELDS: the JSON key, the key it is stored under, its parser,
-- and its statusline segment. sessions.lua, the statusline and the panels pick it up
-- from this list.
--
--   status_fields.register({
--     json = "nextField", key = "next_field",
--     parse = next_field.parse, segment = next_field.segment,
--   })

local reload_state = require("sagefs.reload_state")
local repl_freshness = require("sagefs.repl_freshness")
local source_state = require("sagefs.source_state")
local rebuild = require("sagefs.rebuild")

local M = {}

-- Each entry: json (wire key), key (normalized key), parse(value) -> value|nil,
-- segment(value, ctx) -> string. ctx = { session = <normalized session>,
-- reload_model = <reload_state model>, now_ms = <number|nil> }.
local FIELDS = {
  {
    json = "lastReload",
    key = "last_reload",
    parse = reload_state.parse,
    -- An event-fed report beats the polled one: the model is newer than any list.
    -- `displayable` is what keeps a no-op off the statusline: the daemon records an
    -- eval's no-effect as the session's lastReload, and both it (from the model)
    -- and a polled no-op (from the list) would otherwise read as a broken reload.
    segment = function(polled, ctx)
      local sid = ctx.session and ctx.session.id
      local model = ctx.reload_model
      if not sid then return reload_state.statusline(polled, ctx.now_ms) end
      return reload_state.statusline(reload_state.displayable(model, sid, polled), ctx.now_ms)
    end,
  },
  {
    json = "replFreshness",
    key = "repl_freshness",
    parse = repl_freshness.parse,
    segment = function(value) return repl_freshness.segment(value) end,
  },
  {
    -- The disk ahead of the build: a different fact from the REPL behind the app.
    json = "sourceState",
    key = "source_state",
    parse = source_state.parse,
    segment = function(value) return source_state.segment(value) end,
  },
  {
    -- What the last rebuild did: running, or failed (and whether the old build serves).
    -- Not said twice when sourceState already says Rebuilding.
    json = "lastRestart",
    key = "last_restart",
    parse = rebuild.parse,
    segment = function(value, ctx)
      return rebuild.segment(value, ctx.session and ctx.session.source_state or nil)
    end,
  },
}

--- Add a field. Refuses a second entry under the same normalized key or JSON key.
---@param field { json: string, key: string, parse: function, segment: function }
function M.register(field)
  for _, existing in ipairs(FIELDS) do
    if existing.key == field.key or existing.json == field.json then
      error(string.format("status_fields: %s is already registered", field.key))
    end
  end
  table.insert(FIELDS, field)
end

--- Copy of the registry, for a test to put back.
function M.snapshot()
  local copy = {}
  for i, f in ipairs(FIELDS) do copy[i] = f end
  return copy
end

function M.restore(snapshot)
  for i = #FIELDS, 1, -1 do FIELDS[i] = nil end
  for i, f in ipairs(snapshot) do FIELDS[i] = f end
end

--- Read every registered field out of a raw session report. A field the daemon
--- did not send, or sent as null, is absent from the result: absence is never
--- turned into a value that reads as "fine".
---@param raw table
---@return table parsed  normalized key -> parsed value
function M.parse(raw)
  local out = {}
  if type(raw) ~= "table" then return out end
  for _, field in ipairs(FIELDS) do
    local value = field.parse(raw[field.json])
    if value ~= nil then out[field.key] = value end
  end
  return out
end

--- Statusline segments for a session, in registry order, empty ones left out.
---@param session table|nil normalized session
---@param ctx table { reload_model: table, now_ms: number|nil }
---@return string[]
function M.segments(session, ctx)
  local out = {}
  if not session then return out end
  ctx = ctx or {}
  local segment_ctx = { session = session, reload_model = ctx.reload_model, now_ms = ctx.now_ms }
  for _, field in ipairs(FIELDS) do
    local seg = field.segment(session[field.key], segment_ctx)
    if seg and seg ~= "" then table.insert(out, seg) end
  end
  return out
end

return M
