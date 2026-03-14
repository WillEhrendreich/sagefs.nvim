-- sagefs/dashboard/event_index.lua — O(1) event → section reverse index
-- Pure Lua, zero vim dependencies, fully testable with busted
--
-- Each section declares which SSE events it cares about (Section.events).
-- This module inverts that relationship: given an event type, which sections
-- need re-rendering? Built once at startup, queried on every event.

local M = {}

--- Build a reverse index from event types to section IDs.
--- @param sections table[] sections with .id and .events fields
--- @return table<string, string[]>
function M.build(sections)
  local idx = {}
  for _, s in ipairs(sections) do
    for _, evt in ipairs(s.events or {}) do
      if not idx[evt] then idx[evt] = {} end
      table.insert(idx[evt], s.id)
    end
  end
  return idx
end

--- Look up which sections are affected by an event.
--- Returns empty table for unknown events (never nil — safe to iterate).
--- @param idx table
--- @param event_type string
--- @return string[]
function M.lookup(idx, event_type)
  return idx[event_type] or {}
end

--- Convert a lookup result to a set for O(1) membership testing.
--- @param section_ids string[]
--- @return table<string, true>
function M.to_set(section_ids)
  local set = {}
  for _, id in ipairs(section_ids) do
    set[id] = true
  end
  return set
end

--- Get all known event types in the index.
--- @param idx table
--- @return string[]
function M.known_events(idx)
  local result = {}
  for evt, _ in pairs(idx) do
    table.insert(result, evt)
  end
  table.sort(result)
  return result
end

return M
