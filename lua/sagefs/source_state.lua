-- sagefs/source_state.lua — is the build this session runs behind the files on disk?
-- Pure Lua, zero vim dependencies
--
-- The daemon carries one closed state per session on /api/sessions (and in
-- get_session_status), next to replFreshness:
--   {state:"InSync",     message, builtAt, filesChecked}
--   {state:"Stale",      message, changedFiles:[{path, because, writtenAt, comparedTo, detail}]}
--   {state:"Rebuilding", message, since}
--   {state:"Unknown",    message, reason:{kind, detail}}
-- It is a different fact from replFreshness. replFreshness is the REPL behind the
-- running app; this is the disk ahead of the build. A test that passes over a stale
-- build passed on code the files no longer say, so it is not a green test.
-- SageFs.Core/Features/SourceState.fs writes it (SourceState.toWire); a daemon older
-- than that sends nothing, and nothing is what the plugin shows then: absence is
-- never read as "in sync" and never raised as a problem.

local closed_set = require("sagefs.closed_set")

local M = {}

M.STATE = closed_set.define("SourceState", { "InSync", "Stale", "Rebuilding", "Unknown" })

-- Unknown reasons that are not worth a statusline word: nobody looked, or there is
-- no build to be behind. The other reasons (a worker that did not say when it loaded,
-- a file that could not be read) mean a green test cannot be trusted, so they show.
local QUIET_UNKNOWN = { NotAssessed = true, NoProjectLoaded = true }

local MAX_FILES_NAMED = 5

local function text_or_nil(v)
  if type(v) == "string" and v ~= "" then return v end
  return nil
end

local function parse_changed(list)
  local out = {}
  if type(list) ~= "table" then return out end
  for _, entry in ipairs(list) do
    if type(entry) == "table" and type(entry.path) == "string" then
      table.insert(out, {
        path = entry.path,
        because = text_or_nil(entry.because),
        detail = text_or_nil(entry.detail),
      })
    end
  end
  return out
end

local function parse_reason(v)
  if type(v) ~= "table" then return nil end
  return { kind = text_or_nil(v.kind), detail = text_or_nil(v.detail) }
end

--- Read the sourceState object. nil when the daemon sent none, so an older daemon is
--- never read as "in sync".
---@param v any
---@return table|nil
function M.parse(v)
  if type(v) ~= "table" or type(v.state) ~= "string" then return nil end
  local f = { state = v.state, known = M.STATE.has(v.state), message = text_or_nil(v.message) }
  if v.state == M.STATE.InSync then
    f.files_checked = type(v.filesChecked) == "number" and v.filesChecked or nil
    f.built_at = text_or_nil(v.builtAt)
  elseif v.state == M.STATE.Stale then
    f.changed = parse_changed(v.changedFiles)
  elseif v.state == M.STATE.Rebuilding then
    f.since = text_or_nil(v.since)
  elseif v.state == M.STATE.Unknown then
    f.reason = parse_reason(v.reason)
  end
  return f
end

---@param f table|nil
---@return boolean
function M.is_stale(f)
  return f ~= nil and f.state == M.STATE.Stale
end

local function quiet_unknown(f)
  return f.state == M.STATE.Unknown and f.reason ~= nil and QUIET_UNKNOWN[f.reason.kind] == true
end

local function files_text(n)
  if n == 1 then return "1 file" end
  return string.format("%d files", n)
end

--- Statusline segment: "" unless something needs saying.
---@param f table|nil
---@return string
function M.segment(f)
  if not f then return "" end
  if not f.known then
    return string.format("source: %s?", tostring(f.state))
  end
  if f.state == M.STATE.Stale then
    if #f.changed > 0 then
      return string.format("⚠ STALE SOURCE (%s)", files_text(#f.changed))
    end
    return "⚠ STALE SOURCE"
  end
  if f.state == M.STATE.Rebuilding then return "⟳ rebuilding" end
  if f.state == M.STATE.Unknown and not quiet_unknown(f) then return "source ?" end
  return ""
end

local function unknown_detail(f)
  return (f.reason and f.reason.detail) or f.message or "the daemon did not say why"
end

--- One line for :SageFsStatus, or nil when there is nothing worth a line.
---@param f table|nil
---@return string|nil
function M.status_text(f)
  if not f then return nil end
  if not f.known then return string.format("unrecognized state '%s'", tostring(f.state)) end
  if f.state == M.STATE.InSync then return "in sync with the build" end
  if f.state == M.STATE.Stale then
    if #f.changed > 0 then
      return string.format("STALE: %s changed on disk after the build", files_text(#f.changed))
    end
    return "STALE: files changed on disk after the build"
  end
  if f.state == M.STATE.Rebuilding then return "rebuilding, the old build still serves" end
  if quiet_unknown(f) then return nil end
  return "could not be checked: " .. unknown_detail(f)
end

--- Lines for a panel, each { text, hl }. The highlight groups are the REPL freshness
--- ones (repl_freshness.HL), so no group is defined twice.
---@param f table|nil
---@return { text: string, hl: string }[]
function M.lines(f)
  if not f then return {} end
  if not f.known then
    return { { text = string.format("Source state: unrecognized state '%s'", tostring(f.state)), hl = "SageFsReloadWarn" } }
  end
  if f.state == M.STATE.InSync then
    local compared = f.files_checked and string.format(" (%d file(s) compared)", f.files_checked) or ""
    return { { text = "Source in sync with the build" .. compared, hl = "SageFsReplInSync" } }
  end
  if f.state == M.STATE.Rebuilding then
    return { { text = "⟳ " .. (f.message or "A rebuild is in progress. The session keeps serving the build from before it."),
      hl = "SageFsReplBehind" } }
  end
  if f.state == M.STATE.Stale then
    local what = #f.changed > 0 and files_text(#f.changed) or "files"
    local lines = { {
      text = string.format("⚠ STALE SOURCE: %s changed on disk after the build this session runs, so the REPL and the tests run code that is not what the files say.", what),
      hl = "SageFsReplBehind",
    } }
    for i, file in ipairs(f.changed) do
      if i > MAX_FILES_NAMED then
        table.insert(lines, { text = string.format("  and %d more", #f.changed - MAX_FILES_NAMED), hl = "SageFsReplInSync" })
        break
      end
      table.insert(lines, { text = "  " .. (file.detail or file.path), hl = "SageFsReplInSync" })
    end
    table.insert(lines, {
      text = "  :SageFsHardReset builds the files and loads them (it stops a running app; :SageFsRunApp starts it again).",
      hl = "SageFsReplInSync",
    })
    return lines
  end
  if quiet_unknown(f) then return {} end
  return { { text = "Source could not be checked: " .. unknown_detail(f), hl = "SageFsReloadWarn" } }
end

return M
