-- sagefs/rebuild.lua: what the last rebuild of a session did
-- Pure Lua, zero vim dependencies
--
-- POST /hard-reset with rebuild=true answers at once ("Hard reset initiated ...") and
-- builds in the background, while the current worker keeps serving. The outcome is the
-- `lastRestart` field of every session report (SessionStatusPayload.lastRestartJson):
--   {outcome:"InProgress"|"Succeeded"|"FailedStillServing"|"FailedNotServing", message}
-- `message` is the daemon's own sentence, and for a failure it carries the compiler's
-- error. A session nobody rebuilt has `lastRestart: null`, which reads as absent.

local closed_set = require("sagefs.closed_set")

local M = {}

M.OUTCOME = closed_set.define("RebuildOutcome", {
  "InProgress", "Succeeded", "FailedStillServing", "FailedNotServing",
})

--- How many session-list reads a follow makes before it gives up (at
--- config.REBUILD_POLL_MS apart: about ten minutes).
M.MAX_POLLS = 300

local function levels()
  return vim and vim.log and vim.log.levels or { INFO = 1, WARN = 2, ERROR = 3 }
end

--- Read the lastRestart object. nil when there is none, so a session nobody rebuilt is
--- never read as one that rebuilt fine.
---@param v any
---@return table|nil
function M.parse(v)
  if type(v) ~= "table" or type(v.outcome) ~= "string" then return nil end
  return {
    outcome = v.outcome,
    known = M.OUTCOME.has(v.outcome),
    message = type(v.message) == "string" and v.message or nil,
  }
end

--- Statusline segment: "" unless something needs saying. A failed rebuild stays until
--- the next rebuild replaces the record, because it means the session runs an older build.
---@param f table|nil
---@param source table|nil the session's parsed sourceState; when it already says
---       Rebuilding the segment is not said twice
---@return string
function M.segment(f, source)
  if not f then return "" end
  if not f.known then return string.format("rebuild: %s?", tostring(f.outcome)) end
  if f.outcome == M.OUTCOME.InProgress then
    if source and source.state == "Rebuilding" then return "" end
    return "⟳ rebuilding"
  end
  if f.outcome == M.OUTCOME.FailedStillServing then return "⚠ rebuild FAILED (old build still serves)" end
  if f.outcome == M.OUTCOME.FailedNotServing then return "✖ rebuild FAILED (no worker)" end
  return ""
end

--- Whether the daemon's answer to POST /hard-reset says the build goes on in the
--- background. A daemon from before that answered when the work was done.
---@param reply any decoded reply body
---@return boolean
function M.started_in_background(reply)
  if type(reply) ~= "table" or type(reply.message) ~= "string" then return false end
  return reply.message:lower():find("initiated", 1, true) ~= nil
end

---@return string
function M.started_message()
  return "Hard reset started: building first, and the current worker keeps serving until the new build is ready."
end

-- ─── Following a rebuild ─────────────────────────────────────────────────────

--- Start following. `before` is the session's lastRestart as it was when the request went
--- out, so a record of an earlier rebuild is not taken for this one.
---@param before table|nil
---@return table
function M.follow_new(before)
  return { before = before, saw_in_progress = false, polls = 0 }
end

local function same_record(a, b)
  return a ~= nil and b ~= nil and a.outcome == b.outcome and a.message == b.message
end

--- One look at the session list. Returns the follow and, once there is something to say,
--- { outcome, level, text }. nil result means keep waiting.
---@param follow table
---@param current table|nil the session's parsed lastRestart now
---@return table follow, table|nil result
function M.follow_step(follow, current)
  local lv = levels()
  local f = { before = follow.before, saw_in_progress = follow.saw_in_progress, polls = follow.polls + 1 }
  if current and current.known then
    if current.outcome == M.OUTCOME.InProgress then
      f.saw_in_progress = true
    elseif f.saw_in_progress or not same_record(current, f.before) then
      if current.outcome == M.OUTCOME.Succeeded then
        return f, { outcome = current.outcome, level = lv.INFO,
          text = "Rebuild finished: the session runs the new build." }
      end
      local what = current.outcome == M.OUTCOME.FailedStillServing
        and "the session still runs the previous build."
        or "no worker is serving the session."
      return f, { outcome = current.outcome, level = lv.ERROR,
        text = "Rebuild FAILED, " .. what .. (current.message and ("\n" .. current.message) or "") }
    end
  end
  if f.polls >= M.MAX_POLLS then
    return f, { outcome = "GaveUp", level = lv.WARN,
      text = "Still waiting for the rebuild to end. :SageFsStatus shows where it stands." }
  end
  return f, nil
end

return M
