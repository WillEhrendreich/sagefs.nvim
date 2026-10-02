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
    views = {}, -- coverage_view badges: normalized file path -> { generation, by_symbol }
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
    return { text = "│", hl = "SageFsCovered" }
  else
    return { text = "█", hl = "SageFsUncovered" }
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
  state.views = {}
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

-- ─── coverage_view: per-symbol badges, merged per (session, file, generation) ─
--
-- One `coverage_view` event per symbol, each stamped with the run Generation
-- that produced the burst. Generations are counted per session, so views are
-- kept per (session, file) and a generation never sweeps another session's
-- views. Per file: a NEWER generation replaces the file's
-- whole set (symbols the burst no longer names were renamed or deleted), the
-- SAME generation appends one view per symbol (a symbol sent again replaces its
-- own view), an OLDER generation is a straggler from a superseded burst and is
-- dropped. An absent Generation reads as 0, which is never newer than anything,
-- so a daemon without generations never sweeps. This is the same rule the VS
-- Code client folds with.

local function norm_path(path)
  return (path:gsub("\\", "/"))
end

--- Find a key of `map` for `file`: exact, then separator-normalized, then a
--- relative path (a daemon path relative to the project) against the absolute
--- buffer path that ends with it, on a whole path component. Two absolute paths
--- never match by suffix: /b/a/Util.fs is not /a/Util.fs.
local function resolve_key(map, file)
  if not map or type(file) ~= "string" or file == "" then return nil end
  local key = norm_path(file)
  if map[key] ~= nil then return key end
  for candidate in pairs(map) do
    if util.paths_match(key, candidate) then return candidate end
  end
  return nil
end

--- The entry for `file` as seen by `session_id`: that session's own views, else
--- views the daemon sent without a session id. With no session given, the first
--- session (in id order) that has the file.
local function find_entry(state, file, session_id)
  local views = state.views
  if not views then return nil end
  local order = {}
  if session_id ~= nil then
    order = { tostring(session_id), "" }
  else
    for sid in pairs(views) do table.insert(order, sid) end
    table.sort(order)
  end
  for _, sid in ipairs(order) do
    local bucket = views[sid]
    local key = bucket and resolve_key(bucket, file)
    if key then return bucket[key] end
  end
  return nil
end

local function overflow_hidden(overflow)
  if type(overflow) ~= "table" then return nil end
  local case = overflow.Case or overflow.case
  if case ~= "Overflow" then return nil end
  local fields = overflow.Fields or overflow.fields
  return fields and tonumber(fields[1]) or nil
end

local function case_of(v)
  if type(v) == "table" then return v.Case or v.case end
  return v
end

local function normalize_view(data, generation)
  return {
    symbol = data.Symbol or data.symbol or "",
    file = data.FilePath or data.filePath,
    definition_line = tonumber(data.DefinitionLine or data.definitionLine) or 0,
    total = tonumber(data.TotalCount or data.totalCount) or 0,
    overflow_hidden = overflow_hidden(data.Overflow or data.overflow),
    badge = data.InlineBadgeText or data.inlineBadgeText or "",
    health = case_of(data.Health or data.health) or "Absent",
    generation = generation,
    session_id = data.SessionId or data.sessionId,
  }
end

--- Fold one `coverage_view` event.
---@param state table
---@param data table|nil decoded event data
---@return table state
function M.apply_coverage_view(state, data)
  if type(data) ~= "table" then return state end
  local file = data.FilePath or data.filePath
  if type(file) ~= "string" or file == "" then return state end
  local generation = tonumber(data.Generation or data.generation) or 0
  state.views = state.views or {}
  local sid = data.SessionId or data.sessionId
  sid = sid and tostring(sid) or ""
  local bucket = state.views[sid]
  if not bucket then
    bucket = {}
    state.views[sid] = bucket
  end
  local key = norm_path(file)
  local entry = bucket[key]
  local existing = entry and entry.generation or 0
  if generation < existing then return state end -- a straggler: already superseded
  local view = normalize_view(data, generation)
  if not entry or generation > existing then
    bucket[key] = { generation = generation, by_symbol = { [view.symbol] = view } }
  else
    entry.by_symbol[view.symbol] = view
  end
  state._version = (state._version or 0) + 1
  return state
end

--- The views of a file, ordered by definition line.
---@param session_id string|nil the session whose views to read (the active one)
---@return table[]
function M.views_for_file(state, file, session_id)
  local entry = find_entry(state, file, session_id)
  local out = {}
  if not entry then return out end
  for _, view in pairs(entry.by_symbol) do table.insert(out, view) end
  table.sort(out, function(a, b)
    if a.definition_line ~= b.definition_line then return a.definition_line < b.definition_line end
    return a.symbol < b.symbol
  end)
  return out
end

---@return number|nil
function M.generation_for_file(state, file, session_id)
  local entry = find_entry(state, file, session_id)
  return entry and entry.generation or nil
end

--- The one-line badge of a view and its health, or nil when no test covers the
--- symbol (the daemon sends such views too; they draw nothing).
---@return string|nil text, string|nil health
function M.format_badge(view)
  if not view or view.total == 0 or view.badge == "" then return nil end
  local text = view.badge
  if view.overflow_hidden and view.overflow_hidden > 0 then
    text = string.format("%s +%d more", text, view.overflow_hidden)
  end
  return text, view.health
end

-- ─── Per-line covering tests (file_annotations CoveringTests) ────────────────

local function annotation_range(a)
  local first = a.Line or a.line or 0
  local last = a.EndLine or a.endLine
  if not last or last < first then last = first end
  return first, last
end

local function covering_refs(a, testing_state)
  local refs = a.CoveringTests or a.coveringTests or {}
  local out = {}
  if #refs > 0 then
    for _, ref in ipairs(refs) do
      table.insert(out, { test_id = ref.TestId or ref.testId, name = ref.DisplayName or ref.displayName })
    end
  else
    for _, id in ipairs(a.CoveringTestIds or a.coveringTestIds or {}) do
      table.insert(out, { test_id = id })
    end
  end
  for _, test in ipairs(out) do
    local known = testing_state and testing_state.tests and testing_state.tests[test.test_id]
    if not test.name or test.name == "" then
      test.name = known and known.displayName ~= "" and known.displayName or test.test_id
    end
    test.status = known and known.status or nil
  end
  return out
end

--- Which tests cover a line, from the daemon's file annotations: exactly the
--- tests whose own recorded coverage reaches it, named, with their last result
--- from the live testing state. The innermost annotation that has covering tests
--- wins; when none has, the innermost one answers "no test covers this".
---@param file_ann table|nil one file's FileAnnotations payload
---@param line number 1-based
---@param testing_state table
---@return table|nil info { line, span, status, health, hits, tests }
function M.covering_info(file_ann, line, testing_state)
  local anns = file_ann and (file_ann.CoverageAnnotations or file_ann.coverageAnnotations)
  if not anns or #anns == 0 then return nil end

  local best_with, best_any
  local function tighter(a, b)
    if not b then return true end
    local af, al = annotation_range(a)
    local bf, bl = annotation_range(b)
    if (al - af) ~= (bl - bf) then return (al - af) < (bl - bf) end
    return af > bf
  end
  for _, a in ipairs(anns) do
    local first, last = annotation_range(a)
    if line >= first and line <= last then
      local has = #(a.CoveringTests or a.coveringTests or {}) > 0 or #(a.CoveringTestIds or a.coveringTestIds or {}) > 0
      if has and tighter(a, best_with) then best_with = a end
      if tighter(a, best_any) then best_any = a end
    end
  end
  local chosen = best_with or best_any
  if not chosen then return nil end

  local first, last = annotation_range(chosen)
  local detail = chosen.Detail or chosen.detail
  local status, fields = case_of(detail), type(detail) == "table" and (detail.Fields or detail.fields) or nil
  return {
    line = line,
    span = { from = first, to = last },
    status = status or "Pending",
    hits = fields and tonumber(fields[1]) or nil,
    health = fields and case_of(fields[2]) or nil,
    tests = covering_refs(chosen, testing_state),
  }
end

--- Where a test lives, to jump to it: the file and line the live testing state
--- mapped it to, else the daemon's source locations by name.
---@return string|nil file, number|nil line
function M.test_location(testing_state, test_id, name)
  local known = testing_state and testing_state.tests and testing_state.tests[test_id]
  if known and known.file then return known.file, known.line end
  local locations = testing_state and testing_state.source_locations
  if locations then
    for _, key in ipairs({ name, known and known.fullName, known and known.displayName }) do
      local loc = key and locations[key]
      if loc then
        local file = loc.FilePath or loc.filePath
        if file then return file, loc.StartLine or loc.startLine end
      end
    end
  end
  return nil, nil
end
return M
