-- sagefs/pending.lua — Why is nothing happening?
-- Pure Lua, no vim API dependencies — fully testable with busted.
--
-- An eval that has been out longer than config.EVAL_SLOW_AFTER_MS with no
-- result is not a blank screen: it is one of a handful of real states, and
-- the plugin knows which. classify() turns what the model and a fresh
-- /api/sessions probe say into a short inline form and a long message-line
-- form.
local M = {}

--- Session statuses in which an eval cannot finish yet (SageFs session
--- lifecycle: Starting/Building/Restarting/WarmingUp precede Ready).
M.WARMING_STATUSES = {
  Starting = true,
  Building = true,
  Restarting = true,
  WarmingUp = true,
}

--- Longest inline form; it sits at the end of a code line.
M.MAX_SHORT = 60

local function clip(text)
  if #text <= M.MAX_SHORT then return text end
  -- cut on a character boundary
  local cut = M.MAX_SHORT - 3 -- "…" is three bytes
  while cut > 1 and text:byte(cut + 1) and text:byte(cut + 1) >= 128 and text:byte(cut + 1) < 192 do
    cut = cut - 1
  end
  return text:sub(1, cut) .. "…"
end

local function seconds(ms)
  return string.format("%ds", math.floor((ms or 0) / 1000))
end

local function session_label(session)
  local name = session.name
  if not name or name == "" then name = session.id or "?" end
  return name
end

local function phase_label(warmup)
  if not warmup or not warmup.phase or warmup.phase == "" then return nil end
  local label = warmup.phase:gsub("_", " ")
  if warmup.total and warmup.total > 0 and warmup.step and warmup.step > 0 then
    label = string.format("%s %d/%d", label, warmup.step, warmup.total)
  end
  return label
end

---@class sagefs.PendingInfo
---@field elapsed_ms number
---@field connection string  "connected"|"disconnected"|"reconnecting" (event stream)
---@field daemon_reachable boolean|nil  result of a fresh probe; nil = not probed
---@field port number
---@field session table|nil  { id, name, status, fault_reason }
---@field warmup table|nil   { phase, step, total } while the daemon reports warmup

---@class sagefs.PendingState
---@field kind string
---@field level string  "info"|"warn"|"error"
---@field short string  inline form
---@field long string   message-line form

---@param info sagefs.PendingInfo
---@return sagefs.PendingState
function M.classify(info)
  local secs = seconds(info.elapsed_ms)
  local port = info.port or 37749

  -- An eval's answer comes back over HTTP, not the event stream, so a fresh
  -- successful probe outranks the stream's state; the stream only counts
  -- when we have no probe.
  local probed = info.daemon_reachable ~= nil
  if info.daemon_reachable == false or (not probed and info.connection == "disconnected") then
    return {
      kind = "daemon_unreachable",
      level = "error",
      short = clip(secs .. ": daemon not reachable"),
      long = string.format("No result after %s: the SageFs daemon is not reachable on port %d. Run :SageFsStart, or start it from a shell.", secs, port),
    }
  end

  if not probed and info.connection == "reconnecting" then
    return {
      kind = "daemon_reconnecting",
      level = "warn",
      short = clip(secs .. ": reconnecting to daemon"),
      long = string.format("No result after %s: the plugin lost the SageFs event stream on port %d and is reconnecting; this eval may be lost.", secs, port),
    }
  end

  local session = info.session
  if not session then
    return {
      kind = "no_session",
      level = "warn",
      short = clip(secs .. ": no session attached"),
      long = string.format("No result after %s: no SageFs session is attached to this buffer. Run :SageFsCreateSession to start one for this directory.", secs),
    }
  end

  local name = session_label(session)
  local status = session.status or ""

  if status == "Faulted" then
    local reason = session.fault_reason and session.fault_reason ~= "" and session.fault_reason or "no reason reported"
    return {
      kind = "session_faulted",
      level = "error",
      short = clip(secs .. ": session " .. name .. " faulted: " .. reason),
      long = string.format("No result after %s: session %s faulted: %s. :SageFsHardReset rebuilds it, or :SageFsSessions to pick another.", secs, name, reason),
    }
  end

  if status == "Stopped" then
    return {
      kind = "session_stopped",
      level = "error",
      short = clip(secs .. ": session " .. name .. " stopped"),
      long = string.format("No result after %s: session %s is stopped. :SageFsSessions to pick or create one.", secs, name),
    }
  end

  local phase = phase_label(info.warmup)
  if M.WARMING_STATUSES[status] or phase then
    local shown_status = M.WARMING_STATUSES[status] and status or "WarmingUp"
    return {
      kind = "session_warming",
      level = "warn",
      short = clip(secs .. ": session still warming" .. (phase and (" (" .. phase .. ")") or "")),
      long = string.format("No result after %s: session %s is still warming up (%s%s); an eval cannot finish until it is Ready.",
        secs, name, shown_status, phase and (", " .. phase) or ""),
    }
  end

  return {
    kind = "evaluating",
    level = "info",
    short = clip(secs .. ": still running"),
    long = string.format("Still evaluating after %s in session %s (%s). :SageFsCancel stops it.", secs, name, status ~= "" and status or "status unknown"),
  }
end

return M
