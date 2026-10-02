-- sagefs/sessions.lua — Pure session management logic
-- No vim API dependencies — fully testable with busted
local M = {}

-- ─── JSON decode helper ──────────────────────────────────────────────────────

local util = require("sagefs.util")
local json_decode = util.json_decode

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

--- Derive a human-friendly session name. The daemon's `/api/sessions`
--- response (SageFs/McpServer.fs:2478-2528) never sends a `name` field —
--- `normalize_session` used to produce none, but `sess.name` was still read
--- at two call sites (`:SageFsStatus`, and `:SageFsNotebook`'s exported
--- project header) that could therefore never render anything but a bare
--- 8-hex id or an empty string (roast §5.14). Mirrors
--- `format_statusline`'s own project-name derivation, so both surfaces
--- agree on what a session is "called".
---@param raw table raw session entry from /api/sessions
---@return string|nil
local function derive_name(raw)
  local proj = raw.projects and raw.projects[1]
  if proj and proj ~= "" then
    local base = proj:gsub("%.fsproj$", "")
    if base ~= "" then return base end
  end
  return nil
end

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
    name = derive_name(raw) or raw.id or "",
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
    -- §5.6: surfaced directly as "Failed to list sessions: empty response"
    -- by :SageFsSessions — say what's actually wrong instead.
    return { ok = false, error = "No response from the daemon. Run :SageFsStart or check it's running." }
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
    -- §5.6: this used to be the bare internal string "empty response" —
    -- the user's final message after e.g. choosing "Create session now"
    -- against a dead daemon. Empty is what a failed/refused connection
    -- looks like from here; say so and name the fix.
    return { ok = false, error = "No response from the daemon. Run :SageFsStart or check it's running." }
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
    -- §5.8: /api/sessions/create|switch|stop errors are the daemon's
    -- structuredErrorBody: `{success=false, error=<describe>,
    -- errorDetails={message, suggestedAction}}`. The remedy lives in
    -- `errorDetails.suggestedAction` — surface it instead of discarding it.
    return { ok = false, error = util.format_server_error(data, json_str) }
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
  local health_str = health_marker(s.health)
  -- Include health reason for Degraded/Failed so the remedy is visible
  if s.health and (s.health.status == "Degraded" or s.health.status == "Failed") and s.health.reason then
    health_str = health_str .. " " .. s.health.reason
  end
  return string.format("%s %s (%s)%s", icon, name, s.status or "?", health_str)
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

-- ─── Routing an eval by working directory ───────────────────────────────────
-- A session belongs to a working directory, and a git worktree is its own
-- boundary (SageFs AGENTS.md, "Multi-agent / worktree sessions"): the main
-- checkout's session is not the session of a worktree nested under it, even
-- though the paths nest textually. An eval is never silently sent to another
-- directory's session; when nothing matches the caller says so and asks.

local function within(outer_norm, inner_norm)
  if outer_norm == "" or inner_norm == "" then return false end
  return inner_norm == outer_norm or inner_norm:sub(1, #outer_norm + 1) == (outer_norm .. "/")
end

local function short_id(id) return (id or ""):sub(1, 8) end

local function project_label(s)
  local p = s.projects and s.projects[1]
  return (p and p ~= "") and p or "(no project)"
end

---@class sagefs.RouteTarget
---@field file string|nil     absolute path of the buffer, if it has one
---@field cwd string|nil      working directory (used when there is no file)
---@field root string|nil     checkout root of the file (nearest ancestor with .git, a file for a worktree)
---@field active_id string|nil  the session the plugin currently treats as active
---@field override_id string|nil  a session the user explicitly chose for this directory

--- Decide which session an eval from `target` goes to.
---@param list table[] normalized sessions
---@param target sagefs.RouteTarget
---@return { kind: "match", session: table }
---      | { kind: "ambiguous", candidates: table[], dir: string }
---      | { kind: "none", others: table[], dir: string }
function M.route(list, target)
  list = list or {}
  local dir = target.root or target.cwd or ""

  if target.override_id then
    for _, s in ipairs(list) do
      if s.id == target.override_id and s.status ~= "Stopped" then
        return { kind = "match", session = s }
      end
    end
  end

  local probe = M.normalize_path(target.file or target.cwd or "")
  local root = target.root and M.normalize_path(target.root) or nil

  local best, best_len = {}, -1
  for _, s in ipairs(list) do
    local d = M.normalize_path(s.working_directory)
    if s.status ~= "Stopped" and within(d, probe) and (root == nil or within(root, d)) then
      if #d > best_len then
        best, best_len = { s }, #d
      elseif #d == best_len then
        best[#best + 1] = s
      end
    end
  end

  if #best == 1 then return { kind = "match", session = best[1] } end
  if #best > 1 then
    if target.active_id then
      for _, s in ipairs(best) do
        if s.id == target.active_id then return { kind = "match", session = s } end
      end
    end
    local ready = {}
    for _, s in ipairs(best) do
      if s.status == "Ready" then ready[#ready + 1] = s end
    end
    if #ready == 1 then return { kind = "match", session = ready[1] } end
    return { kind = "ambiguous", candidates = best, dir = dir }
  end
  return { kind = "none", others = list, dir = dir }
end

--- Is a warmup_progress event about the session this editor is waiting on?
--- On a shared daemon every session's warmup reaches every client. With a
--- session id the answer is exact; without one (the legacy event shape) it is
--- ours only while we expect a warmup: a session we just created, or an active
--- session that is itself still warming.
---@param data table decoded event data
---@param active_session table|nil
---@param expecting boolean  we created a session recently and are waiting for it
---@return boolean
function M.warmup_event_is_ours(data, active_session, expecting)
  local sid = data.sessionId or data.SessionId or data.session_id
  if sid then
    if active_session then return active_session.id == sid end
    return expecting == true
  end
  if expecting then return true end
  if active_session then return M.WARMING_STATUSES[active_session.status] == true end
  return false
end

--- Session statuses that precede Ready.
M.WARMING_STATUSES = { Starting = true, Building = true, Restarting = true, WarmingUp = true }

--- One line per session: short id, project, directory, status.
---@param list table[]
---@param cap number|nil  show at most this many (default 6)
---@return string[]
function M.overview_lines(list, cap)
  cap = cap or 6
  local lines = {}
  for i, s in ipairs(list or {}) do
    if i > cap then
      lines[#lines + 1] = string.format("  … and %d more", #list - cap)
      break
    end
    lines[#lines + 1] = string.format("  %s  %s  %s  [%s]",
      short_id(s.id), project_label(s),
      (s.working_directory and s.working_directory ~= "") and s.working_directory or "(no directory)",
      s.status or "?")
  end
  return lines
end

--- The message for "nothing in this directory can take the eval".
---@param dir string
---@param others table[] sessions that exist (all of them belong elsewhere)
---@return string
function M.no_session_message(dir, others)
  local msg = string.format("No active session for this directory (%s); nothing was sent.", dir)
  if others and #others > 0 then
    msg = msg .. string.format(" %d other session%s on this daemon %s in other directories.",
      #others, #others == 1 and "" or "s", #others == 1 and "lives" or "live")
  end
  return msg
end

--- Picker label: the line the picker always showed, plus the working directory
--- and short id, so two sessions of one project can be told apart (and so the
--- picker's label -> session lookup cannot collide).
---@param s table normalized session
---@return string
function M.picker_label(s)
  local label = M.format_session_line(s)
  if s.working_directory and s.working_directory ~= "" then
    label = label .. "  " .. s.working_directory
  end
  return label .. "  [" .. short_id(s.id) .. "]"
end

function M.select_active_session(sessions_list, active_id, cwd)
  if sessions_list and active_id and active_id ~= "" then
    for _, session in ipairs(sessions_list) do
      if session.id == active_id then return session end
    end
  end
  return M.find_session_for_dir(sessions_list, cwd)
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
