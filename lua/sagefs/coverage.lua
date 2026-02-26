-- sagefs/coverage.lua — Pure coverage state model
-- Tracks line-level IL coverage from SageFs server
-- Zero vim dependencies — fully testable under busted

local M = {}

local util = require("sagefs.util")

-- ─── State Constructor ────────────────────────────────────────────────────────

function M.new()
  return {
    files = {},
    enabled = false,
    _version = 0,
  }
end

-- ─── File Count ───────────────────────────────────────────────────────────────

function M.file_count(state)
  local count = 0
  for _ in pairs(state.files) do
    count = count + 1
  end
  return count
end

-- ─── Line-Level Tracking ──────────────────────────────────────────────────────

function M.update_file(state, path, lines)
  state.files[path] = lines
  state._version = (state._version or 0) + 1
  return state
end

function M.get_file_lines(state, path)
  return state.files[path] or {}
end

-- ─── Queries ──────────────────────────────────────────────────────────────────

function M.compute_file_summary(state, path)
  local lines = state.files[path]
  if not lines then
    return { total = 0, covered = 0, uncovered = 0, percent = 0 }
  end
  local total, covered = 0, 0
  for _, hits in pairs(lines) do
    total = total + 1
    if hits > 0 then covered = covered + 1 end
  end
  local uncovered = total - covered
  local percent = total > 0 and math.floor((covered / total) * 100 + 0.5) or 0
  return { total = total, covered = covered, uncovered = uncovered, percent = percent }
end

function M.compute_total_summary(state)
  local total, covered = 0, 0
  for path in pairs(state.files) do
    local s = M.compute_file_summary(state, path)
    total = total + s.total
    covered = covered + s.covered
  end
  local uncovered = total - covered
  local percent = total > 0 and math.floor((covered / total) * 100 + 0.5) or 0
  return { total = total, covered = covered, uncovered = uncovered, percent = percent }
end

-- ─── Gutter Signs ─────────────────────────────────────────────────────────────

function M.gutter_sign(hit_count)
  if hit_count == nil then
    return { text = " ", hl = "Normal" }
  elseif hit_count > 0 then
    return { text = "▎", hl = "SageFsCovered" }
  else
    return { text = "▎", hl = "SageFsUncovered" }
  end
end

-- ─── Formatting ───────────────────────────────────────────────────────────────

function M.format_summary(summary)
  if summary.total == 0 then
    return "0% covered (0/0)"
  end
  return string.format("%d%% covered (%d/%d)", summary.percent, summary.covered, summary.total)
end

function M.format_statusline(state)
  local summary = M.compute_total_summary(state)
  if summary.total == 0 then return "" end
  return string.format("☂ %d%%", summary.percent)
end

-- ─── Clear ────────────────────────────────────────────────────────────────────

function M.clear(state)
  state.files = {}
  state._version = (state._version or 0) + 1
  return state
end

-- ─── Parse Server Response ────────────────────────────────────────────────────

function M.parse_coverage_response(json_str)
  if not json_str or json_str == "" then
    return nil, "empty input"
  end
  local ok, data = util.json_decode(json_str)
  if not ok or not data then
    return nil, "invalid JSON"
  end
  return data, nil
end

function M.apply_coverage_response(state, data)
  if not data or not data.files then return state end
  for _, file_entry in ipairs(data.files) do
    local lines = {}
    if file_entry.lines then
      for _, line_entry in ipairs(file_entry.lines) do
        lines[line_entry.line] = line_entry.hits
      end
    end
    state = M.update_file(state, file_entry.path, lines)
  end
  return state
end

return M
