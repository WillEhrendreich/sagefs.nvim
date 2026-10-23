-- What a `test_results_batch` frame needs beyond what it carries.
--
-- The stream is moving to a summary on the wire with the list behind
-- GET /api/live-testing/entries, so a frame can arrive with a tally, a freshness and a completion and
-- no Entries. Whether to go and fetch, and how to splice the answer back in, are two pure questions:
-- they belong here rather than in the SSE dispatcher (which does IO) or in testing's reducer (which
-- must stay a pure (state, data) -> state function).
local M = {}

--- Does this frame need the list fetched?
---@param data table|nil the decoded `test_results_batch` payload
---@return boolean
function M.needs_entries(data)
  if type(data) ~= "table" then return false end
  if data.Entries or data.entries then return false end
  local sid = data.SessionId or data.sessionId
  if type(sid) ~= "string" or sid == "" then return false end
  return true
end

--- The session a frame belongs to, in either spelling.
---@param data table
---@return string|nil
function M.session_of(data)
  if type(data) ~= "table" then return nil end
  local sid = data.SessionId or data.sessionId
  if type(sid) == "string" and sid ~= "" then return sid end
  return nil
end

--- Splice fetched entries onto a frame. Returns a NEW table and leaves the frame it was given alone:
--- the dispatcher still owns the decoded payload, and a hydrator that rewrote it in place would be
--- the reason a later render showed someone else's list.
---@param data table the decoded frame
---@param entries table the entries read from /api/live-testing/entries
---@return table
function M.with_entries(data, entries)
  local enriched = {}
  for key, value in pairs(data) do
    enriched[key] = value
  end
  enriched.Entries = entries
  return enriched
end

return M
