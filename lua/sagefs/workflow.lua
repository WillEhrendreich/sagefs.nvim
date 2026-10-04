-- sagefs/workflow.lua: switch the active session's workflow (:SageFsWorkflow)
-- Pure Lua, no vim API dependencies, fully testable with busted.
--
-- The daemon has three workflows (SageFs.Core/WorkflowTypes.fs): REPL, Live
-- Testing and Hot Reload. `POST /api/sessions/{sid}/workflow` restarts the SAME
-- session in place in the one asked for, so the session id the plugin holds
-- stays valid. The answer comes back at once ("Hard reset accepted"); the
-- session goes Restarting and then Ready, which the plugin already follows from
-- the session list and the `workflow_switched` event.
--
-- The daemon owns the names it accepts, aliases included (`repl`, `live`,
-- `web`, `test`, ...), so a name is sent as typed, trimmed and lower-cased, and
-- an unknown one comes back in the daemon's own words, with the valid values.
-- CHOICES is only what the plugin offers.

local util = require("sagefs.util")

local M = {}

--- What the plugin offers. `token` is the name the daemon's own error lists as
--- valid, `label` is what it answers with once switched.
M.CHOICES = {
  { token = "interactive", label = "REPL",
    blurb = "type code, redefine types freely; the default" },
  { token = "livetesting", label = "Live Testing",
    blurb = "like REPL, with live testing armed as you type" },
  { token = "hotreload", label = "Hot Reload",
    blurb = "run your app and patch it on save; no type redefinition in the REPL" },
}

---@param sid string
---@param name string what the user typed
---@return { method: string, path: string, body: table }
function M.build_request(sid, name)
  local workflow = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
  return {
    method = "POST",
    path = string.format("/api/sessions/%s/workflow", sid),
    body = { workflow = workflow },
  }
end

--- Read the daemon's answer.
---@param ok boolean transport success
---@param raw string|nil body
---@return table { ok, message, label, session_id, error }
function M.parse_response(ok, raw)
  local decoded, data = util.json_decode(raw)
  if ok and decoded and type(data) == "table" and data.success ~= false then
    return {
      ok = true,
      message = type(data.message) == "string" and data.message or "",
      label = type(data.workflow) == "string" and data.workflow or "",
      session_id = type(data.sessionId) == "string" and data.sessionId or "",
    }
  end
  if decoded and type(data) == "table" then
    return { ok = false, error = util.format_server_error(data, raw) }
  end
  local text = (type(raw) == "string" and raw ~= "") and raw or "no answer from the daemon"
  return { ok = false, error = text }
end

--- Names for command-line completion.
---@param lead string|nil
---@return string[]
function M.complete(lead)
  lead = tostring(lead or ""):lower()
  local out = {}
  for _, c in ipairs(M.CHOICES) do
    if c.token:sub(1, #lead) == lead then table.insert(out, c.token) end
  end
  return out
end

--- What to say once the daemon has accepted the switch. Not before: an unknown
--- name is refused, and a restart announced first would be a false claim.
---@param sid string
---@param parsed table from parse_response { label, message }
---@return string
function M.accepted_notice(sid, parsed)
  local text = string.format("Session %s is now %s. It restarts in place, so its REPL bindings are not kept.",
    sid, (parsed.label ~= nil and parsed.label ~= "") and parsed.label or "in the workflow you asked for")
  if parsed.message ~= nil and parsed.message ~= "" then
    text = text .. " The daemon says: " .. parsed.message
  end
  return text
end

--- The choices for a picker, with the session's current workflow marked.
---@param current_label string|nil
---@return table[] items { token, label, text }
function M.picker_items(current_label)
  local items = {}
  for _, c in ipairs(M.CHOICES) do
    local mark = (current_label ~= nil and current_label == c.label) and " (current)" or ""
    table.insert(items, {
      token = c.token,
      label = c.label,
      text = string.format("%s%s: %s", c.label, mark, c.blurb),
    })
  end
  return items
end

return M
