-- sagefs/repl_freshness.lua — is the REPL behind the app?
-- Pure Lua, zero vim dependencies
--
-- After a metadata delta lands in an app SageFs started with run_app, the app runs
-- the new code and the FSI host that the REPL and live tests run in keeps the build
-- from before it. A REPL call to what changed then runs the OLD body. The daemon
-- carries that as a closed state on every session report:
--   {state:"InSync"}
--   {state:"BehindApp", savesSince:int, declarations:string[], message:string}
-- and appends a "WARNING: The REPL is BEHIND the app" line after tool text results.
-- The remedy is a rebuild of the REPL, which replaces the worker and so STOPS the app.

local closed_set = require("sagefs.closed_set")

local M = {}

M.STATE = closed_set.define("ReplFreshness", { "InSync", "BehindApp" })

local BANNER_PREFIX = "WARNING: The REPL is BEHIND the app"

--- Highlight group -> link target, for the UI layer.
M.HL = { SageFsReplBehind = "WarningMsg", SageFsReplInSync = "Comment" }

local function list_of_strings(v)
  local out = {}
  if type(v) ~= "table" then return out end
  for _, item in ipairs(v) do
    if type(item) == "string" then table.insert(out, item) end
  end
  return out
end

--- Read the replFreshness object. nil when the daemon sent none, so an older
--- daemon is never read as "in sync".
---@param v any
---@return table|nil
function M.parse(v)
  if type(v) ~= "table" or type(v.state) ~= "string" then return nil end
  local known = M.STATE.has(v.state)
  local f = { state = v.state, known = known }
  if v.state == M.STATE.BehindApp then
    f.saves_since = type(v.savesSince) == "number" and v.savesSince or nil
    f.declarations = list_of_strings(v.declarations)
    f.message = type(v.message) == "string" and v.message or nil
  end
  return f
end

---@param f table|nil
---@return boolean
function M.is_behind(f)
  return f ~= nil and f.state == M.STATE.BehindApp
end

local function saves_text(n)
  if n == 1 then return "1 save" end
  return string.format("%d saves", n)
end

--- Statusline segment: "" unless something needs saying.
---@param f table|nil
---@return string
function M.segment(f)
  if not f then return "" end
  if not f.known then
    return string.format("REPL freshness: %s?", tostring(f.state))
  end
  if f.state ~= M.STATE.BehindApp then return "" end
  if f.saves_since then
    return string.format("⚠ REPL BEHIND app (%s)", saves_text(f.saves_since))
  end
  return "⚠ REPL BEHIND app"
end

local MAX_NAMED = 3

local function declarations_text(declarations)
  if not declarations or #declarations == 0 then return nil end
  if #declarations <= MAX_NAMED then return table.concat(declarations, ", ") end
  local named = {}
  for i = 1, MAX_NAMED do named[i] = declarations[i] end
  return string.format("%s, and %d more", table.concat(named, ", "), #declarations - MAX_NAMED)
end

--- The one-line message shown when you eval: what is wrong, and the remedy,
--- including that the remedy stops the app.
---@param f table|nil
---@return string|nil
function M.eval_message(f)
  if not M.is_behind(f) then return nil end
  local what = ""
  local names = declarations_text(f.declarations)
  if f.saves_since and names then
    what = string.format(" (%s: %s)", saves_text(f.saves_since), names)
  elseif f.saves_since then
    what = string.format(" (%s)", saves_text(f.saves_since))
  elseif names then
    what = string.format(" (%s)", names)
  end
  return "The REPL is BEHIND the app" .. what
    .. ": calls to what changed run the OLD code."
    .. " :SageFsHardReset rebuilds the REPL and stops the running app (:SageFsRunApp starts it again)."
end

--- Lines for a panel.
---@param f table|nil
---@return { text: string, hl: string }[]
function M.lines(f)
  if not f then return {} end
  if not f.known then
    return { { text = string.format("REPL freshness: unrecognized state '%s'", tostring(f.state)), hl = "SageFsReloadWarn" } }
  end
  if f.state == M.STATE.InSync then
    return { { text = "REPL in sync with the app", hl = "SageFsReplInSync" } }
  end
  local lines = { { text = "⚠ " .. M.eval_message(f), hl = "SageFsReplBehind" } }
  if f.message and f.message ~= "" then
    table.insert(lines, { text = "  daemon: " .. f.message, hl = "SageFsReplInSync" })
  end
  return lines
end

--- Separate the WARNING banner the daemon puts after a tool's text result.
--- The result stays first and whole; the banner is returned on its own.
---@param text any
---@return string|nil clean, string|nil banner
function M.split_banner(text)
  if type(text) ~= "string" then return nil, nil end
  local start = text:find(BANNER_PREFIX, 1, true)
  if not start then return text, nil end
  local banner = text:sub(start):gsub("%s+$", "")
  local clean = text:sub(1, start - 1):gsub("%s+$", "")
  return clean, banner
end

--- A BehindApp state read from a banner line. Only the fact is read: the count and
--- the names stay in the daemon's words, never parsed back out of them.
---@param banner string|nil
---@return table|nil
function M.from_banner(banner)
  if type(banner) ~= "string" or banner == "" then return nil end
  local message = banner:gsub("^WARNING: ", "")
  return { state = M.STATE.BehindApp, known = true, declarations = {}, message = message, from_banner = true }
end

--- The replFreshness field of a structured send_fsharp_code / run_tests result.
---@param result any
---@return table|nil
function M.from_structured(result)
  if type(result) ~= "table" then return nil end
  return M.parse(result.replFreshness)
end

-- ─── Announcement gate ───────────────────────────────────────────────────────

local REPEAT_AFTER_MS = 60000

local function key_of(f)
  return table.concat({ tostring(f.saves_since or "?"), table.concat(f.declarations or {}, ",") }, "|")
end

function M.gate_new()
  return { key = nil, at = nil }
end

--- Whether to say the eval message now. The first time, whenever the state
--- changes, and again after a minute of the same state; never when level.
---@param gate table
---@param f table|nil
---@param now_ms number
---@return boolean say, table gate
function M.gate_should_announce(gate, f, now_ms)
  if not M.is_behind(f) then return false, M.gate_new() end
  local key = key_of(f)
  if gate.key ~= key or gate.at == nil or (now_ms - gate.at) >= REPEAT_AFTER_MS then
    return true, { key = key, at = now_ms }
  end
  return false, gate
end

return M
