-- sagefs/sse.lua — SSE message parser
-- Pure parsing logic, no vim API dependencies — fully testable with busted
local M = {}

--- Parse a chunk of SSE text into events and unconsumed remainder
--- Events are delimited by blank lines (\n\n)
--- Each event can have: event: <type>, data: <payload>, : <comment>
---@param chunk string
---@return {type: string?, data: string?}[], string remainder
function M.parse_chunk(chunk)
  local events = {}
  local remainder = ""

  if not chunk or chunk == "" then
    return events, ""
  end

  -- Split on double-newline (event boundary)
  -- Handle both \n\n and \r\n\r\n
  local normalized = chunk:gsub("\r\n", "\n")

  -- Find all complete events (terminated by \n\n)
  local pos = 1
  while true do
    local boundary = normalized:find("\n\n", pos, true)
    if not boundary then
      -- No more complete events; rest is remainder
      remainder = normalized:sub(pos)
      break
    end

    local event_text = normalized:sub(pos, boundary - 1)
    pos = boundary + 2

    -- Parse the event lines
    local event_type = nil
    local data_parts = {}

    for line in (event_text .. "\n"):gmatch("([^\n]*)\n") do
      if line:match("^:") then
        -- Comment, ignore
      elseif line:match("^event: ") then
        event_type = line:match("^event: (.+)")
      elseif line:match("^data: ") then
        table.insert(data_parts, line:match("^data: (.+)"))
      elseif line:match("^data:$") then
        table.insert(data_parts, "")
      end
    end

    local data = nil
    if #data_parts > 0 then
      data = table.concat(data_parts, "\n")
    end

    table.insert(events, { type = event_type, data = data })
  end

  return events, remainder
end

--- Calculate reconnection delay with exponential backoff
---@param attempt number Attempt number (1-based)
---@return number Delay in milliseconds
function M.reconnect_delay(attempt)
  local delay = 1000 * (2 ^ (attempt - 1))
  if delay > 32000 then delay = 32000 end
  return delay
end

--- Classify an SSE event into an action type
---@param event {type: string?, data: string?}|nil
---@return {action: string, data: string?}|nil
function M.classify_event(event)
  if not event then return nil end

  local type_to_action = {
    EvalCompleted = "eval_completed",
    TestRunCompleted = "test_run_completed",
    SessionCreated = "session_created",
    SessionStopped = "session_stopped",
    DiagnosticsUpdated = "diagnostics_updated",
    state = "state_update",
  }

  local action = type_to_action[event.type] or "unknown"
  return { action = action, data = event.data }
end

return M
