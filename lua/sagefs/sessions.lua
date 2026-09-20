-- sagefs/sessions.lua — Pure session management logic
-- No vim API dependencies — fully testable with busted
local M = {}

-- ─── JSON decode helper ──────────────────────────────────────────────────────

local json_decode = require("sagefs.util").json_decode

-- ─── Path normalization ──────────────────────────────────────────────────────

function M.normalize_path(p)
  if not p or p == "" then return "" end
  local s = p:lower()
  -- canonical separator: always use forward slashes
  s = s:gsub("\\", "/")
  -- strip trailing slash
  s = s:gsub("/$", "")
  return s
end

-- ─── Parse GET /api/sessions response ────────────────────────────────────────

local function normalize_session(raw)
  -- `health` is passed through as-is (never invented): `nil` means the
  -- server didn't send a verdict, which callers must treat the same as
  -- "don't know" — never as "healthy". `faultReason` and `loadedProjects`
  -- are the two other `/api/sessions` fields (SageFs.Core/SessionHealth.fs,
  -- SageFs/McpServer.fs:2360-2377) that a `Degraded` session depends on to
  -- be distinguishable from a healthy one; both were previously dropped
  -- (§5.5), so no Neovim surface could ever render the distinction.
  local health = nil
  if type(raw.health) == "table" then
    health = { status = raw.health.status, reason = raw.health.reason }
  end
  return {
    id = raw.id or "",
    status = raw.status or "",
    projects = raw.projects or {},
    working_directory = raw.workingDirectory or "",
    eval_count = raw.evalCount or 0,
    avg_duration_ms = raw.avgDurationMs or 0,
    fault_reason = (raw.faultReason ~= vim.NIL) and raw.faultReason or nil,
    health = health,
    loaded_projects = raw.loadedProjects or {},
  }
end

function M.parse_sessions_response(json_str)
  if not json_str or json_str == "" then
    return { ok = false, error = "empty response" }
  end

  local ok, data = json_decode(json_str)
  if not ok or type(data) ~= "table" then
    return { ok = false, error = "invalid JSON" }
  end

  local sessions = {}
  for _, raw in ipairs(data.sessions or {}) do
    table.insert(sessions, normalize_session(raw))
  end

  return { ok = true, sessions = sessions }
end

-- ─── Parse action responses (create/switch/stop) ────────────────────────────

function M.parse_action_response(json_str)
  if not json_str or json_str == "" then
    return { ok = false, error = "empty response" }
  end

  local ok, data = json_decode(json_str)
  if not ok or type(data) ~= "table" then
    return { ok = false, error = "invalid JSON" }
  end

  if data.success then
    return {
      ok = true,
      message = data.message or "",
      session_id = data.sessionId,
    }
  else
    return { ok = false, error = data.error or "unknown error" }
  end
end

-- ─── Formatting ──────────────────────────────────────────────────────────────

-- ─── Health verdict formatting ────────────────────────────────────────────
-- `s.health` is `SessionHealth.toJson` passed through unchanged: `nil` means
-- no verdict was computed (never rendered as a problem — a session can be
-- Healthy and just not have been classified yet), "Healthy"/"Starting" are
-- quiet (must stay quiet — the common case), "Degraded"/"Failed" carry a
-- `reason` that a user needs to actually act on (§5.5).

local function health_suffix(health)
  if not health then return "" end
  if health.status == "Degraded" or health.status == "Failed" then
    local reason = health.reason and (" — " .. health.reason) or ""
    return string.format("  [%s%s]", health.status, reason)
  end
  return ""
end

local function health_marker(health)
  if not health then return "" end
  if health.status == "Degraded" then return " ⚠" end
  if health.status == "Failed" then return " ❌" end
  return ""
end

function M.format_session_line(s)
  local proj = #s.projects > 0
    and table.concat(s.projects, ", ")
    or "(no project)"
  local evals = s.eval_count > 0
    and string.format(" [%d evals]", s.eval_count)
    or ""
  return string.format("%s  %s%s%s", proj, s.status, evals, health_suffix(s.health))
end

function M.format_statusline(s, conn_status)
  if not s then return "" end
  -- The connection-aware icon: previously this was hardcoded to ⚡
  -- unconditionally, so once a session was active the statusline kept
  -- reading "⚡ MyProject (Ready)" even after the daemon died (§5.1). Every
  -- caller must now pass the transport's own connection status through.
  local icon = conn_status == "reconnecting" and "🔌"
    or conn_status == "disconnected" and "💤"
    or "⚡"
  local name = s.projects and s.projects[1] or ""
  name = name:gsub("%.fsproj$", "")
  if name == "" then name = s.id or "?" end
  return string.format("%s %s (%s)%s", icon, name, s.status or "?", health_marker(s.health))
end

-- ─── Find session for working directory ──────────────────────────────────────

function M.find_session_for_dir(sessions_list, dir)
  if not sessions_list or not dir then return nil end
  local norm_dir = M.normalize_path(dir)
  for _, s in ipairs(sessions_list) do
    if M.normalize_path(s.working_directory) == norm_dir then
      return s
    end
  end
  return nil
end

-- ─── Buffer-changed request routing ─────────────────────────────────────────
-- Mirrors the VS Code extension's BufferBridge.resolveSessionOwnership
-- (sagefs-vscode/src/BufferBridge.fs): route an edited buffer to whichever
-- known session's working directory contains it, falling back to the active
-- session only when no session_list entry matches (e.g. session_list hasn't
-- been refreshed since the session was created). An ambiguous match — more
-- than one session's working directory contains the file — is dropped rather
-- than guessed at, same as the VS Code client.

local function has_supported_extension(file_path)
  local lower = file_path:lower()
  return lower:match("%.fs$") ~= nil
    or lower:match("%.fsx$") ~= nil
    or lower:match("%.fsi$") ~= nil
end

local function is_within_directory(dir, file_path)
  if not dir or dir == "" then return false end
  local norm_dir = M.normalize_path(dir)
  local norm_file = M.normalize_path(file_path)
  if norm_dir == "" then return false end
  return norm_file == norm_dir or norm_file:sub(1, #norm_dir + 1) == (norm_dir .. "/")
end

--- Build the { path, body } request for POST /api/sessions/{sid}/buffer-changed,
--- or nil if the edit should not be sent (unsupported file, no owning session,
--- or an ambiguous match across multiple sessions).
function M.build_buffer_change_request(sessions_list, active_session, file_path, content)
  if not file_path or file_path == "" or not has_supported_extension(file_path) then
    return nil
  end

  local matches = {}
  local seen = {}
  for _, s in ipairs(sessions_list or {}) do
    if s.id and s.id ~= "" and is_within_directory(s.working_directory, file_path) and not seen[s.id] then
      seen[s.id] = true
      table.insert(matches, s.id)
    end
  end

  local session_id = nil
  if #matches == 1 then
    session_id = matches[1]
  elseif #matches == 0 and active_session and active_session.id
    and is_within_directory(active_session.working_directory, file_path) then
    session_id = active_session.id
  end

  if not session_id or session_id == "" then
    return nil
  end

  return {
    path = string.format("/api/sessions/%s/buffer-changed", session_id),
    body = { filePath = file_path, content = content },
  }
end

-- ─── Available actions per session ───────────────────────────────────────────

function M.session_actions(s, is_active)
  local actions = {}
  local status = s and s.status or ""

  if not is_active then
    table.insert(actions, { name = "switch", label = "Switch to this session" })
  end

  if status ~= "Stopped" then
    table.insert(actions, { name = "stop", label = "Stop this session" })
    table.insert(actions, { name = "reset", label = "Reset session (soft)" })
    table.insert(actions, { name = "hard_reset", label = "Hard reset (rebuild)" })
  end

  table.insert(actions, { name = "create", label = "Create new session" })
  return actions
end

return M
