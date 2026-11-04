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

--- A fresh gate: the newest ticket taken for each session.
---@return table
function M.new_gate()
  return {}
end

--- Take the next ticket for a session. Tickets only grow. The gate is changed in place, because the
--- dispatcher owns one for the life of the connection and every fetch callback has to see the same one.
---@param gate table
---@param session_id string
---@return integer
function M.take_ticket(gate, session_id)
  local ticket = (gate[session_id] or 0) + 1
  gate[session_id] = ticket
  return ticket
end

--- Is this still the newest ticket taken for the session? A newer frame has its own fetch coming, so
--- an older answer that lands after it would put an older generation, freshness and completion over
--- the newer ones.
---@param gate table
---@param session_id string
---@param ticket integer
---@return boolean
function M.is_current(gate, session_id, ticket)
  return gate[session_id] == ticket
end

return M
