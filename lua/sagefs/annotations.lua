-- sagefs/annotations.lua — FileAnnotations state model
-- No vim API dependencies — fully testable with busted
--
-- Stores per-file inline annotations pushed via SSE: test line markers,
-- coverage details, CodeLens entries, and inline failure details.
-- The render layer reads this state to place extmarks.
local M = {}

-- ─── State constructor ───────────────────────────────────────────────────────

--- Create a new empty annotations state
---@return table
function M.new()
  return {
    files = {},  -- filepath → FileAnnotations
  }
end

-- ─── Helpers: unwrap F# DU JSON ─────────────────────────────────────────────

--- Unwrap an F# discriminated union value like {Case: "Passed", Fields: [0.012]}
--- Returns the case name as a string, and the fields array (or empty).
---@param du any
---@return string|nil case, any[]|nil fields
local function unwrap_du(du)
  if type(du) == "string" then return du, {} end
  if type(du) == "table" then
    local case = du.Case or du.case
    local fields = du.Fields or du.fields or {}
    if case then return case, fields end
  end
  return nil, nil
end

--- Extract a simple status string from a TestRunStatus DU
--- e.g. {Case: "Passed", Fields: ["00:00:00.012"]} → "Passed"
---@param status any
---@return string
function M.unwrap_status(status)
  local case, _ = unwrap_du(status)
  return case or "Unknown"
end

--- Extract duration from a TestRunStatus DU (Passed/Failed carry duration)
---@param status any
---@return number|nil duration_ms
function M.extract_duration_ms(status)
  local case, fields = unwrap_du(status)
  if not case or not fields then return nil end
  if case == "Passed" and fields[1] then
    return M.parse_timespan_ms(fields[1])
  elseif case == "Failed" and fields[2] then
    return M.parse_timespan_ms(fields[2])
  end
  return nil
end

--- Parse a .NET TimeSpan string like "00:00:00.0123456" to milliseconds
---@param ts string
---@return number|nil
function M.parse_timespan_ms(ts)
  if type(ts) ~= "string" then return nil end
  local h, m, s = ts:match("(%d+):(%d+):([%d%.]+)")
  if not h then return nil end
  return (tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)) * 1000
end

-- ─── State update ────────────────────────────────────────────────────────────

--- Handle a file_annotations SSE event
--- Replaces the annotations for the given file path.
---@param state table annotations state
---@param data table decoded JSON payload (FileAnnotations record)
---@return table new state
function M.handle_file_annotations(state, data)
  local fp = data and (data.filePath or data.FilePath)
  if not fp then return state end
  local new_state = {
    files = {},
  }
  -- Copy existing files
  for k, v in pairs(state.files) do
    new_state.files[k] = v
  end
  -- Normalize the file path for cross-platform matching
  local path = fp:gsub("\\", "/")
  new_state.files[path] = data
  return new_state
end

--- Get annotations for a specific file
---@param state table
---@param file string
---@return table|nil FileAnnotations or nil
function M.get_file(state, file)
  if not file then return nil end
  local normalized = file:gsub("\\", "/")
  -- Try exact match first
  if state.files[normalized] then
    return state.files[normalized]
  end
  -- Try suffix match (buffer paths may differ from daemon paths)
  for path, ann in pairs(state.files) do
    local norm_path = path:gsub("\\", "/")
    if normalized:sub(-#norm_path) == norm_path or norm_path:sub(-#normalized) == normalized then
      return ann
    end
  end
  return nil
end

-- ─── CodeLens formatting ─────────────────────────────────────────────────────

--- Format a CodeLens entry for virtual text display
---@param lens table {Line, Label, TestId, Command}
---@return string text, string hl_group
function M.format_codelens(lens)
  local label = lens.Label or lens.label or ""
  -- Determine color from label prefix (daemon pre-formats: ✓/✗/●/◆/~/○)
  if label:match("^✓") then
    return label, "SageFsCodeLensPassed"
  elseif label:match("^✗") then
    return label, "SageFsCodeLensFailed"
  elseif label:match("^●") then
    return label, "SageFsCodeLensRunning"
  elseif label:match("^~") then
    return label, "SageFsCodeLensStale"
  elseif label:match("^○") then
    return label, "SageFsCodeLensDetected"
  elseif label:match("^◆") then
    return label, "SageFsCodeLensDetected"
  else
    return label, "SageFsCodeLensDetected"
  end
end

--- Format an inline failure for virtual text display (truncated to fit EOL)
---@param failure table {Line, TestId, TestName, Failure, Duration}
---@param max_len number|nil max characters (default 80)
---@return string text, string hl_group
function M.format_inline_failure(failure, max_len)
  max_len = max_len or 80
  local test_name = failure.TestName or failure.testName or "?"
  local fail_data = failure.Failure or failure.failure or {}
  local label = fail_data.InlineLabel or fail_data.inlineLabel
  if not label then
    -- Fall back to extracting from the failure DU
    local case, fields = unwrap_du(fail_data)
    if case == "RawMessage" and fields then
      label = tostring(fields[1] or "error")
    elseif case == "AssertionDiff" and fields then
      label = string.format("Expected: %s Got: %s",
        tostring(fields[1] or "?"), tostring(fields[2] or "?"))
    elseif case == "ExceptionMessage" and fields then
      label = tostring(fields[1] or "error")
    elseif case == "StackTraceOnly" then
      label = "(stack trace)"
    elseif case and fields and fields[1] then
      label = tostring(fields[1])
    else
      label = tostring(fail_data)
    end
  end
  local text = string.format(" ✗ %s: %s", test_name, label)
  if #text > max_len then
    text = text:sub(1, max_len - 3) .. "..."
  end
  return text, "SageFsInlineFailure"
end

-- ─── Clear ───────────────────────────────────────────────────────────────────

--- Clear all annotations
---@param state table
---@return table new state
function M.clear(state)
  return M.new()
end

--- Clear annotations for a specific file
---@param state table
---@param file string
---@return table new state
function M.clear_file(state, file)
  if not file then return state end
  local normalized = file:gsub("\\", "/")
  local new_state = { files = {} }
  for k, v in pairs(state.files) do
    if k ~= normalized then
      new_state.files[k] = v
    end
  end
  return new_state
end

return M
