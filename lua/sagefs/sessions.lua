-- sagefs/sessions.lua — Pure session management logic
-- No vim API dependencies — fully testable with busted
local M = {}

-- ─── JSON decode helper ──────────────────────────────────────────────────────

local function json_decode(s)
  if vim and vim.json and vim.json.decode then
    return pcall(vim.json.decode, s)
  elseif vim and vim.fn and vim.fn.json_decode then
    return pcall(vim.fn.json_decode, s)
  end
  return false, "no JSON decoder available"
end

-- ─── Path normalization ──────────────────────────────────────────────────────

function M.normalize_path(p)
  if not p or p == "" then return "" end
  local s = p:lower()
  -- strip trailing slash/backslash
  s = s:gsub("[/\\]$", "")
  return s
end

-- ─── Parse GET /api/sessions response ────────────────────────────────────────

local function normalize_session(raw)
  return {
    id = raw.id or "",
    status = raw.status or "",
    projects = raw.projects or {},
    working_directory = raw.workingDirectory or "",
    eval_count = raw.evalCount or 0,
    avg_duration_ms = raw.avgDurationMs or 0,
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

function M.format_session_line(s)
  local proj = #s.projects > 0
    and table.concat(s.projects, ", ")
    or "(no project)"
  local evals = s.eval_count > 0
    and string.format(" [%d evals]", s.eval_count)
    or ""
  return string.format("%s  %s%s", proj, s.status, evals)
end

function M.format_statusline(s)
  if not s then return "" end
  local name = s.projects and s.projects[1] or ""
  name = name:gsub("%.fsproj$", "")
  if name == "" then name = s.id or "?" end
  return string.format("⚡ %s (%s)", name, s.status or "?")
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

-- ─── Available actions per session ───────────────────────────────────────────

function M.session_actions(s)
  local actions = {}
  table.insert(actions, { name = "switch", label = "Switch to this session" })
  table.insert(actions, { name = "stop", label = "Stop this session" })
  table.insert(actions, { name = "create", label = "Create new session" })
  return actions
end

return M
