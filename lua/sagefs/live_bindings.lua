-- sagefs/live_bindings.lua — Live bindings model: a pure fold over the daemon's payloads
-- Zero vim dependencies (beyond JSON decode via util) — fully testable with busted
--
-- The daemon walks every binding of a session reflectively and pushes the whole
-- snapshot as a `live_bindings` SSE event, on every eval, after a click and
-- after a mode switch (docs/sse-events.md). That is the only way a snapshot
-- arrives: there is no GET for it. Nodes of kind `NotEvaluated` are getters the
-- walk did not run; their `Preview` is already a sentence a person can read.
--
-- Two wire profiles meet here:
--   * the SSE event: PascalCase fields, unions as {"Case": ..., "Fields": [...]}
--   * the click route's `outcome`: camelCase, unions as {"type": ..., "value": [...]}
-- This module folds the first and reads the second.

local util = require("sagefs.util")

local M = {}

-- ─── Union readers ───────────────────────────────────────────────────────────

--- Read a PascalCase union {Case, Fields} (or a bare string case).
local function du(v)
  if type(v) == "string" then return v, nil end
  if type(v) == "table" then return v.Case or v.case, v.Fields or v.fields end
  return nil, nil
end

--- Read a camelCase union {type, value}.
local function tagged(v)
  if type(v) == "string" then return v, nil end
  if type(v) == "table" then return v.type or v.Type, v.value or v.Value end
  return nil, nil
end

-- ─── Node normalization ──────────────────────────────────────────────────────

local function normalize_node(raw)
  local kind, fields = du(raw.Kind or raw.kind)
  local node = {
    label = raw.Label or raw.label or "",
    type_name = raw.TypeName or raw.typeName or "",
    preview = raw.Preview or raw.preview or "",
    kind = kind or "Leaf",
    best_effort = (raw.BestEffort or raw.bestEffort) == true,
    depth = raw.Depth or raw.depth or 0,
    children = {},
  }
  if node.kind == "NotEvaluated" then
    local case, reason_fields = du(fields and fields[1])
    local detail = reason_fields and reason_fields[1]
    if type(detail) == "table" then detail = detail[1] end
    node.reason = { case = case or "Unknown", detail = detail }
  end
  for _, child in ipairs(raw.Children or raw.children or {}) do
    table.insert(node.children, normalize_node(child))
  end
  return node
end

-- ─── State ───────────────────────────────────────────────────────────────────

--- A fresh model: one snapshot per session.
function M.new()
  return { sessions = {}, _version = 0 }
end

--- Fold one `live_bindings` event. The event is the whole snapshot of its
--- session, so it replaces whatever that session had. The stream is ordered, so
--- the latest event wins (a generation does not move on a click, and a restarted
--- worker starts again from a low one, so comparing generations would drop real
--- snapshots).
---@param state table
---@param payload table|nil decoded event data
---@return table state
function M.apply_snapshot(state, payload)
  if type(payload) ~= "table" then return state end
  local sid = payload.SessionId or payload.sessionId
  if type(sid) ~= "string" or sid == "" then return state end
  local bindings = {}
  for _, raw in ipairs(payload.Bindings or payload.bindings or {}) do
    table.insert(bindings, {
      name = raw.Name or raw.name or "",
      type_signature = raw.TypeSignature or raw.typeSignature or "",
      root = normalize_node(raw.Root or raw.root or {}),
    })
  end
  state.sessions[sid] = {
    session_id = sid,
    generation = payload.Generation or payload.generation or 0,
    truncated = (payload.Truncated or payload.truncated) == true,
    captured_at = payload.CapturedAt or payload.capturedAt,
    bindings = bindings,
  }
  state._version = (state._version or 0) + 1
  return state
end

---@return table|nil snapshot
function M.get(state, session_id)
  if not state or not session_id then return nil end
  return state.sessions[session_id]
end

-- ─── Counts and row actions ──────────────────────────────────────────────────

local function count_held(node)
  local n = node.kind == "NotEvaluated" and 1 or 0
  for _, child in ipairs(node.children) do n = n + count_held(child) end
  return n
end

--- How many `NotEvaluated` nodes the snapshot holds, at any depth in any
--- binding. The dashboard shows the same count ("N not evaluated").
function M.not_evaluated_count(snapshot)
  local n = 0
  if not snapshot then return n end
  for _, b in ipairs(snapshot.bindings) do n = n + count_held(b.root) end
  return n
end

--- What a row offers: "click" (run the getter), "failed" (a click ran and did
--- not give a value: show unknown and the reason), "none" (nothing to offer),
--- or nil for a node that is not held.
function M.row_action(node)
  if not node or node.kind ~= "NotEvaluated" then return nil end
  local case = node.reason and node.reason.case
  if case == "GetterRunsCode" or case == "GetterLoops" then return "click" end
  if case == "EvaluationTimedOut" or case == "EvaluationThrew" or case == "EvaluationNotContained" then
    return "failed"
  end
  return "none"
end

-- ─── Modes ───────────────────────────────────────────────────────────────────

M.MODES = { "Safe", "Everything", "Off" }

local BLURBS = {
  Safe = "Reads fields and runs only getters that provably do nothing. Every other getter is listed, and runs only when you click it.",
  Everything = "Runs your getters: every public property of every class value, after every eval. That is your code running, and it can take time or change things.",
  Off = "Does not open class instances. Records, unions, tuples, lists and maps still show.",
}

function M.mode_blurb(mode)
  return BLURBS[mode] or ""
end

--- Only Everything runs your code on its own, so only it asks first.
function M.mode_needs_confirmation(mode)
  return mode == "Everything"
end

--- A click is meaningful in Safe mode only. With the mode unknown the daemon
--- gets to answer.
function M.click_meaningful(mode)
  return mode == nil or mode == "Safe"
end

-- ─── Requests and responses ──────────────────────────────────────────────────

local function base(sid)
  return string.format("/api/sessions/%s/live-values", sid)
end

--- The path of a click is the labels from the binding's root down to the member,
--- excluding the binding's own label.
function M.build_click_request(sid, binding_name, path)
  return { method = "POST", path = base(sid) .. "/evaluate", body = { binding = binding_name, path = path } }
end

function M.build_mode_request(sid, mode)
  return { method = "POST", path = base(sid) .. "/mode", body = { mode = mode } }
end

function M.build_read_mode_request(sid)
  return { method = "GET", path = base(sid) .. "/mode" }
end

local function error_of(ok, raw)
  local decoded, data = util.json_decode(raw)
  if decoded and type(data) == "table" then
    return util.format_server_error(data, raw)
  end
  local text = (type(raw) == "string" and raw ~= "") and raw or "no response"
  if #text > 200 then text = text:sub(1, 200) .. "…" end
  return (ok and "unexpected answer from the daemon: " or "request failed: ") .. text
end

local function notice_for(outcome)
  local kind, value = tagged(outcome)
  local detail_kind, detail_value = tagged(value and value[1])
  if kind == "MemberShown" then
    return nil
  elseif kind == "MemberRefused" then
    if detail_kind == "EveryGetterAlreadyRan" then
      return "Nothing to run: the mode is Everything, so every getter already ran."
    elseif detail_kind == "ClassesAreCollapsed" then
      return "Nothing to run: the mode is Off, which does not open class instances. Switch the mode to open them."
    end
    return "The daemon refused the click in this mode."
  elseif kind == "MemberUnavailable" then
    if detail_kind == "NoIsolatedHost" then
      return "No getter can be run here: this session runs FSI in the worker's own process, not an isolated host."
    elseif detail_kind == "HostNotRunning" then
      local why = detail_value and detail_value[1]
      return "No getter can be run: the isolated host is not running" .. (why and (": " .. tostring(why)) or ".")
    end
    return "No getter can be run in this session."
  elseif kind == "BindingNotFound" then
    local name = value and value[1]
    return string.format("The binding '%s' is not in the session any more.", tostring(name or "?"))
  end
  return string.format("The daemon answered '%s'.", tostring(kind))
end

--- Read the click route's answer. A click that timed out or threw is NOT an
--- error: it is MemberShown and the row of the next snapshot is the answer.
---@return table { ok, outcome, containment, not_evaluated, notice, error }
function M.parse_click_response(ok, raw)
  local decoded, data = util.json_decode(raw)
  if decoded and type(data) == "table" and data.outcome ~= nil and data.success ~= false then
    local kind = tagged(data.outcome)
    return {
      ok = true,
      outcome = kind,
      containment = data.containment or "",
      not_evaluated = data.notEvaluated,
      notice = notice_for(data.outcome),
    }
  end
  return { ok = false, error = error_of(ok, raw) }
end

--- Read the mode route's answer (GET and POST share the shape).
---@return table { ok, mode, not_evaluated, containment, error }
function M.parse_mode_response(ok, raw)
  local decoded, data = util.json_decode(raw)
  if decoded and type(data) == "table" and data.success ~= false and type(data.mode) == "string" then
    return { ok = true, mode = data.mode, not_evaluated = data.notEvaluated, containment = data.containment or "" }
  end
  return { ok = false, error = error_of(ok, raw) }
end

-- ─── The view model ──────────────────────────────────────────────────────────

--- View state for one session's pane: what is folded, the mode, the containment
--- line of the last click and a notice to show under the header.
function M.new_view(session_id)
  return {
    session_id = session_id,
    mode = nil,
    containment = "",
    notice = nil,
    expanded = {},
    _effective = {},
  }
end

--- Fold or unfold a row (by the key a render gave it).
function M.toggle(view, key)
  local current = view.expanded[key]
  if current == nil then current = view._effective[key] end
  view.expanded[key] = not current
end

local SEP = "\31"
local function key_of(binding_name, path)
  if #path == 0 then return binding_name end
  return binding_name .. SEP .. table.concat(path, SEP)
end

--- Draw one snapshot as buffer lines.
---@param snapshot table|nil
---@param view table
---@return table { lines: string[], rows: table<number, table>, highlights: table[] }
function M.render(snapshot, view)
  local lines, rows, highlights = {}, {}, {}

  local function add(text, hl)
    table.insert(lines, text)
    if hl then table.insert(highlights, { line = #lines, group = hl }) end
    return #lines
  end

  local held = snapshot and M.not_evaluated_count(snapshot) or 0
  add(string.format("Live bindings  session %s  mode %s  %d not evaluated",
    tostring(view.session_id or "?"), view.mode or "?", held), "SageFsBindingsHeader")
  if view.containment and view.containment ~= "" then
    add(view.containment, "SageFsBindingsContainment")
  end
  if view.notice and view.notice ~= "" then
    add(view.notice, "SageFsBindingsNotice")
  end
  add("<CR> run getter   <Tab> fold   m mode   r refresh   q close", "Comment")
  add("")

  if not snapshot then
    add("no live bindings yet: evaluate something, or press r to ask the daemon for the current ones.")
    return { lines = lines, rows = rows, highlights = highlights }
  end
  if #snapshot.bindings == 0 then
    add("no bindings in this session yet.")
    return { lines = lines, rows = rows, highlights = highlights }
  end

  local function emit(node, binding_name, path)
    local key = key_of(binding_name, path)
    local expandable = #node.children > 0
    local open = false
    if expandable then
      open = view.expanded[key]
      if open == nil then open = node.depth < 2 end
      view._effective[key] = open
    end
    local marker = expandable and (open and "▾ " or "▸ ") or "  "
    local indent = string.rep("  ", node.depth)
    local head = string.format("%s%s%s : %s", indent, marker, node.label, node.type_name)
    local action = M.row_action(node)
    local text, hl
    if node.kind == "NotEvaluated" then
      if action == "click" then
        text = head .. "  " .. node.preview .. "   [<CR> run]"
        hl = "SageFsBindingsHeld"
      elseif action == "failed" then
        text = head .. "  = unknown (" .. node.preview .. ")"
        hl = "SageFsBindingsFailed"
      else
        text = head .. "  " .. node.preview
        hl = "SageFsBindingsHeld"
      end
    else
      text = head .. "  = " .. node.preview
    end
    local lnum = add(text, hl)
    rows[lnum] = {
      kind = node.depth == 0 and "binding" or "node",
      key = key,
      binding = binding_name,
      path = path,
      action = action,
      node = node,
      expandable = expandable,
    }
    if expandable and open then
      for _, child in ipairs(node.children) do
        local child_path = {}
        for i, label in ipairs(path) do child_path[i] = label end
        table.insert(child_path, child.label)
        emit(child, binding_name, child_path)
      end
    end
  end

  for _, b in ipairs(snapshot.bindings) do
    emit(b.root, b.name, {})
  end
  if snapshot.truncated then
    add("(the daemon truncated this snapshot)", "Comment")
  end
  return { lines = lines, rows = rows, highlights = highlights }
end

return M
