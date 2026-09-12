-- sagefs/app_run.lua — Run/stop the session's application
-- Pure Lua, no vim API dependencies — fully testable with busted
--
-- Talks to the daemon's `/api/sessions/{sid}/run-app` and `/stop-app` routes.
-- On success (HTTP 200) the body is a flat, PascalCase `AppStateView`
-- projection of SageFs.Core's AppRunState DU: `State`, `Message`, `Urls`
-- (a list), `EntryPoint`, `RunId`. On error (non-200) the body is the
-- daemon's standard error shape: `{ case, fields, message, suggestedAction }`.
-- This module owns request construction and response interpretation;
-- commands.lua wires it to the transport and to vim.notify.

local M = {}

-- ─── Request building ────────────────────────────────────────────────────────

--- Build the POST body for run-app. An empty/nil project means "use the
--- session's default runnable target" — the daemon wants no body (or an
--- empty one) in that case, not an explicit null/empty field.
---@param project string|nil
---@return table|nil
function M.build_run_body(project)
  if project and project ~= "" then
    return { project = project }
  end
  return nil
end

--- Build a full request descriptor for running the session's application.
---@param sid string
---@param project string|nil
---@return { method: string, path: string, body: table|nil }
function M.build_run_request(sid, project)
  return {
    method = "POST",
    path = string.format("/api/sessions/%s/run-app", sid),
    body = M.build_run_body(project),
  }
end

--- Build a full request descriptor for stopping the session's application.
---@param sid string
---@return { method: string, path: string, body: nil }
function M.build_stop_request(sid)
  return {
    method = "POST",
    path = string.format("/api/sessions/%s/stop-app", sid),
    body = nil,
  }
end

-- ─── Response parsing ────────────────────────────────────────────────────────

--- Parse a decoded `AppStateView` JSON body into a normalized descriptor.
---
--- The real success-body shape (SageFs.Core/AppRun.fs's AppRunState,
--- projected to JSON) is PascalCase and flat:
---   State: string ("Running" | "Starting" | "NotRunning" | "Exited" |
---     "Crashed" | "CouldNotStart" | "RestartRequired" | "BuildFailed" |
---     "LostTrack"), Message: string, Urls: string[], EntryPoint: string,
---   RunId: string.
--- `State` is authoritative for the kind and `Urls[1]` for the primary URL;
--- the other spellings below are defensive fallbacks only (in case the
--- wire shape drifts), tried after the real fields.
---@param data table|nil
---@return { kind: string, url: string|nil, reason: string|nil, project: string|nil, entry_point: string|nil, run_id: string|nil }
function M.parse_state(data)
  if type(data) ~= "table" then
    return { kind = "Unknown" }
  end
  local urls = data.Urls or data.urls
  local url_from_list = (type(urls) == "table") and urls[1] or nil

  local kind = data.State
    or data.case or data.Case or data.kind or data.Kind
    or data.status or data.Status or "Unknown"
  local url = url_from_list
    or data.url or data.Url or data.applicationUrl or data.ApplicationUrl
  local reason = data.Message
    or data.reason or data.Reason or data.message
  local project = data.project or data.Project
  local entry_point = data.EntryPoint or data.entryPoint
  local run_id = data.RunId or data.runId
  return {
    kind = kind,
    url = url,
    reason = reason,
    project = project,
    entry_point = entry_point,
    run_id = run_id,
  }
end

--- Whether a parsed state represents a failure that should read as a warning.
---@param state { kind: string }
---@return boolean
function M.is_failure(state)
  return state ~= nil and (state.kind == "BuildFailed" or state.kind == "CouldNotStart")
end

-- ─── Notification formatting ─────────────────────────────────────────────────

local function reason_suffix(state)
  if state.reason and state.reason ~= "" then
    return " — " .. state.reason
  end
  return ""
end

--- Format a user-facing message for a successful run-app response.
---@param state { kind: string, url: string|nil, reason: string|nil }
---@return string
function M.format_run_notify(state)
  state = state or { kind = "Unknown" }
  if state.kind == "Running" then
    if state.url and state.url ~= "" then
      return "SageFs: app running at " .. state.url
    end
    return "SageFs: app running"
  elseif state.kind == "Starting" then
    return "SageFs: app starting..."
  elseif state.kind == "RestartRequired" then
    return "SageFs: app restart required" .. reason_suffix(state)
  elseif state.kind == "NotRunning" then
    return "SageFs: app not running"
  elseif state.kind == "BuildFailed" then
    return "SageFs: app build failed" .. reason_suffix(state)
  elseif state.kind == "CouldNotStart" then
    return "SageFs: app could not start" .. reason_suffix(state)
  else
    return "SageFs: app " .. tostring(state.kind)
  end
end

--- Format a user-facing message for a successful stop-app response.
---@param state { kind: string }
---@return string
function M.format_stop_notify(state)
  state = state or { kind = "Unknown" }
  if state.kind == "NotRunning" then
    return "SageFs: app stopped"
  end
  return M.format_run_notify(state)
end

-- ─── Error body formatting (non-2xx responses) ───────────────────────────────

--- Format an error response `{ case, message, suggestedAction }` into a
--- single notify string. Falls back to the raw response text when the body
--- isn't the structured shape (e.g. a connection error from the transport).
---@param parsed table|nil decoded JSON body, or nil if decoding failed
---@param raw string|nil the raw response text, used as a fallback
---@return string
function M.format_error(parsed, raw)
  if type(parsed) == "table" then
    local msg = parsed.message or parsed.Message or "Unknown error"
    local action = parsed.suggestedAction or parsed.SuggestedAction or ""
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

-- ─── Statusline ───────────────────────────────────────────────────────────────

local ICONS = {
  Running = "▶",
  Starting = "⏳",
  BuildFailed = "⚠",
  CouldNotStart = "⚠",
  LostTrack = "⚠",
  Crashed = "⚠",
  RestartRequired = "⟳",
}

--- Compact statusline indicator for the current app-run state.
--- Empty string when there's nothing worth showing: no state yet, or the
--- app isn't running (NotRunning/Exited/Unknown).
---@param state { kind: string }|nil
---@return string
function M.format_statusline(state)
  if not state or not state.kind then return "" end
  return ICONS[state.kind] or ""
end

return M
