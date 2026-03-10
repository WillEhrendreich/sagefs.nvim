-- sagefs/timeline.lua — Eval timeline with sparkline and flame chart
-- Pure Lua, no vim dependencies.

local M = {}

function M.new()
  return { events = {}, session_start_ms = nil }
end

--- Record a new eval event.
---@param state table timeline state
---@param entry table {cell_id, start_ms, duration_ms, status}
---@return table state (mutated)
function M.record(state, entry)
  if not state.session_start_ms then
    state.session_start_ms = entry.start_ms
  end
  state.events[#state.events + 1] = {
    cell_id = entry.cell_id,
    start_ms = entry.start_ms,
    duration_ms = entry.duration_ms,
    status = entry.status,
  }
  return state
end

local SPARK_CHARS = { "\xe2\x96\x81", "\xe2\x96\x82", "\xe2\x96\x83", "\xe2\x96\x85", "\xe2\x96\x86", "\xe2\x96\x88" }

--- Render ASCII sparkline (one char per recent eval, height = log(duration)).
---@param state table
---@param width number max characters
---@return string
function M.sparkline(state, width)
  if #state.events == 0 then return "" end
  local n = math.min(#state.events, width)
  local start = #state.events - n + 1
  local max_dur = 0
  for i = start, #state.events do
    if state.events[i].duration_ms > max_dur then
      max_dur = state.events[i].duration_ms
    end
  end
  if max_dur == 0 then max_dur = 1 end
  local chars = {}
  for i = start, #state.events do
    local e = state.events[i]
    local ratio = math.log(e.duration_ms + 1) / math.log(max_dur + 1)
    local idx = math.max(1, math.min(#SPARK_CHARS, math.ceil(ratio * #SPARK_CHARS)))
    chars[#chars + 1] = SPARK_CHARS[idx]
  end
  return table.concat(chars)
end

--- Compute percentile latency.
---@param state table
---@param pct number 0.0-1.0
---@return number|nil ms
function M.percentile(state, pct)
  if #state.events == 0 then return nil end
  local durations = {}
  for _, e in ipairs(state.events) do
    durations[#durations + 1] = e.duration_ms
  end
  table.sort(durations)
  local idx = math.max(1, math.ceil(pct * #durations))
  return durations[idx]
end

--- Render ASCII flame chart for floating window.
---@param state table
---@param width number column width
---@return string[] lines
function M.flame_chart(state, width)
  if #state.events == 0 then return { "(no evaluations)" } end
  local lines = { string.format("═══ Eval Timeline (%d evals) ═══", #state.events) }
  local t_min = state.events[1].start_ms
  local t_max = 0
  for _, e in ipairs(state.events) do
    local t_end = e.start_ms + e.duration_ms
    if t_end > t_max then t_max = t_end end
  end
  local span = math.max(t_max - t_min, 1)
  local bar_width = math.max(width - 20, 10)
  for _, e in ipairs(state.events) do
    local bar_start = math.floor((e.start_ms - t_min) / span * bar_width)
    local bar_len = math.max(1, math.floor(e.duration_ms / span * bar_width))
    local prefix = string.rep(" ", bar_start)
    local marker = e.status == "error" and "x" or "-"
    local bar = string.rep(marker, bar_len)
    local label = string.format(" c%d %dms", e.cell_id, e.duration_ms)
    lines[#lines + 1] = prefix .. bar .. label
  end
  return lines
end

--- Format statusline component from server-pushed eval_timeline stats.
---@param stats table|nil {count, sparkline, p50Ms, p95Ms, p99Ms, meanMs}
---@return string
function M.format_statusline(stats)
  if not stats or (stats.count or 0) == 0 then return "" end
  local spark = stats.sparkline or ""
  local p50 = stats.p50Ms and string.format(" p50=%.0fms", stats.p50Ms) or ""
  return "⚡" .. spark .. p50
end

return M
