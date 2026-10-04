-- Tests: the live bindings model (sagefs.live_bindings), a pure fold over the
-- daemon's `live_bindings` SSE payloads plus the view model drawn from it.
--
-- Fixtures in spec/fixtures/wire are REAL payloads captured from the dev
-- daemon (d7e11077) on a session over the lemmings demoenv fixture, after
-- evaluating a class with a safe member, a getter that runs code, a getter that
-- throws, a nested class and a lazy sequence. Where a case could not be
-- provoked safely (a timed-out or uncontained getter) the payload is built by
-- hand from the documented shape and says so.
require("spec.helper")

local lb = require("sagefs.live_bindings")
local util = require("sagefs.util")

local function fixture(name)
  local src = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
  local f = assert(io.open(src .. "fixtures/wire/" .. name, "rb"))
  local text = f:read("*a")
  f:close()
  local ok, data = util.json_decode(text)
  assert(ok, "fixture " .. name .. " did not decode")
  return data, text
end

local function binding(snapshot, name)
  for _, b in ipairs(snapshot.bindings) do
    if b.name == name then return b end
  end
end

local function child(node, label)
  for _, c in ipairs(node.children) do
    if c.label == label then return c end
  end
end

-- ─── Payloads of the wrong shape ─────────────────────────────────────────────
--
-- The daemon's version drifts away from the plugin's. A field of the wrong type
-- must never throw on the fold or on a redraw: a throw on a redraw would leave
-- the pane broken for good.

describe("live_bindings against payloads of the wrong shape", function()
  local function good_node(extra)
    local n = { Label = "b", TypeName = "T", Preview = "x", Kind = "Leaf", Depth = 0, Children = {} }
    for k, v in pairs(extra or {}) do n[k] = v end
    return n
  end

  local function snapshot_with(mutate)
    local payload = {
      SessionId = "s", Generation = 1,
      Bindings = { { Name = "b", TypeSignature = "T", Root = good_node({
        Children = { good_node({ Label = "c", Depth = 1 }) },
      }) } },
    }
    mutate(payload)
    return payload
  end

  local CASES = {
    { "Bindings is a string", function(p) p.Bindings = "oops" end },
    { "Bindings is a number", function(p) p.Bindings = 42 end },
    { "a binding is a number", function(p) p.Bindings = { 7 } end },
    { "a binding is a string", function(p) p.Bindings = { "x" } end },
    { "a binding Name is a table", function(p) p.Bindings[1].Name = {} end },
    { "a binding TypeSignature is a number", function(p) p.Bindings[1].TypeSignature = 5 end },
    { "Root is a number", function(p) p.Bindings[1].Root = 5 end },
    { "Root is a string", function(p) p.Bindings[1].Root = "x" end },
    { "Children is a string", function(p) p.Bindings[1].Root.Children = "kids" end },
    { "Children is a number", function(p) p.Bindings[1].Root.Children = 3 end },
    { "a child is a number", function(p) p.Bindings[1].Root.Children = { 3 } end },
    { "a child is a string", function(p) p.Bindings[1].Root.Children = { "s" } end },
    { "Preview is a table", function(p) p.Bindings[1].Root.Preview = { a = 1 } end },
    { "Label is a table", function(p) p.Bindings[1].Root.Label = {} end },
    { "TypeName is a number", function(p) p.Bindings[1].Root.TypeName = 5 end },
    { "Depth is a numeric string", function(p) p.Bindings[1].Root.Children[1].Depth = "1" end },
    { "Depth is words", function(p) p.Bindings[1].Root.Depth = "deep" end },
    { "Depth is a table", function(p) p.Bindings[1].Root.Depth = {} end },
    { "Kind is a number", function(p) p.Bindings[1].Root.Kind = 5 end },
    { "NotEvaluated with Fields a number", function(p) p.Bindings[1].Root.Kind = { Case = "NotEvaluated", Fields = 5 } end },
    { "NotEvaluated with a number reason", function(p) p.Bindings[1].Root.Kind = { Case = "NotEvaluated", Fields = { 7 } } end },
    { "NotEvaluated with reason Fields a number", function(p)
      p.Bindings[1].Root.Kind = { Case = "NotEvaluated", Fields = { { Case = "GetterRunsCode", Fields = 3 } } }
    end },
    { "Generation is words", function(p) p.Generation = "x" end },
  }

  for _, case in ipairs(CASES) do
    it("neither folds nor draws with a throw when " .. case[1], function()
      local payload = snapshot_with(case[2])
      local ok, err = pcall(function()
        local state = lb.apply_snapshot(lb.new(), payload)
        local snap = lb.get(state, "s")
        lb.render(snap, lb.new_view("s"))
        lb.not_evaluated_count(snap)
      end)
      assert.is_true(ok, tostring(err))
    end)
  end

  it("reads a numeric string Depth as that number", function()
    local snap = lb.get(lb.apply_snapshot(lb.new(), snapshot_with(function(p)
      p.Bindings[1].Root.Children[1].Depth = "1"
    end)), "s")
    assert.are.equal(1, snap.bindings[1].root.children[1].depth)
  end)

  it("reads a Depth that is no number as 0", function()
    local snap = lb.get(lb.apply_snapshot(lb.new(), snapshot_with(function(p)
      p.Bindings[1].Root.Depth = "deep"
    end)), "s")
    assert.are.equal(0, snap.bindings[1].root.depth)
  end)

  it("a huge Depth does not build a huge indentation", function()
    local snap = lb.get(lb.apply_snapshot(lb.new(), snapshot_with(function(p)
      p.Bindings[1].Root.Depth = 1e9
    end)), "s")
    local r = lb.render(snap, lb.new_view("s"))
    for _, line in ipairs(r.lines) do assert.is_true(#line < 1000) end
  end)

  it("keeps the good bindings next to a broken one", function()
    local snap = lb.get(lb.apply_snapshot(lb.new(), snapshot_with(function(p)
      table.insert(p.Bindings, 7)
      table.insert(p.Bindings, { Name = "ok", TypeSignature = "U", Root = good_node({ Label = "ok" }) })
    end)), "s")
    local names = {}
    for _, b in ipairs(snap.bindings) do table.insert(names, b.name) end
    assert.are.same({ "b", "ok" }, names)
  end)

  it("a click answer with an outcome of the wrong shape is still an answer", function()
    for _, outcome in ipairs({
      { type = "MemberRefused", value = 5 },
      { type = "MemberRefused", value = { 5 } },
      { type = "BindingNotFound", value = "x" },
      { type = "MemberUnavailable", value = { { type = "HostNotRunning", value = 7 } } },
    }) do
      local ok, r = pcall(lb.parse_click_response, true, vim.json.encode({ success = true, containment = "", outcome = outcome }))
      assert.is_true(ok, tostring(r))
    end
  end)
end)

-- ─── The fold ────────────────────────────────────────────────────────────────

describe("live_bindings.apply_snapshot", function()
  it("starts empty", function()
    local state = lb.new()
    assert.is_nil(lb.get(state, "57bbdfd8"))
  end)

  it("stores the whole snapshot of one session from a real payload", function()
    local state = lb.apply_snapshot(lb.new(), fixture("live_bindings_safe.json"))
    local snap = lb.get(state, "57bbdfd8")
    assert.is_truthy(snap)
    assert.are.equal("57bbdfd8", snap.session_id)
    assert.are.equal(1, snap.generation)
    assert.is_false(snap.truncated)
    local names = {}
    for _, b in ipairs(snap.bindings) do table.insert(names, b.name) end
    assert.are.same({ "_SageFsCompExpr", "_SageFsHotReload", "box", "nums", "pt" }, names)
  end)

  it("normalizes nodes: label, type name, preview, kind and children", function()
    local snap = lb.get(lb.apply_snapshot(lb.new(), fixture("live_bindings_safe.json")), "57bbdfd8")
    local box = binding(snap, "box")
    assert.are.equal("Box", box.type_signature)
    assert.are.equal("Class", box.root.kind)
    local size = child(box.root, "size")
    assert.are.equal("Leaf", size.kind)
    assert.are.equal("7", size.preview)
    assert.are.equal("Int32", size.type_name)
    assert.are.equal(1, size.depth)
    assert.are.equal("Record", binding(snap, "pt").root.kind)
    assert.are.equal("List", binding(snap, "nums").root.kind)
    assert.are.equal(3, #binding(snap, "nums").root.children)
  end)

  it("reads NotEvaluated reasons off the real wire, nested as Fields", function()
    local snap = lb.get(lb.apply_snapshot(lb.new(), fixture("live_bindings_clicked_boom.json")), "57bbdfd8")
    local box = binding(snap, "box")
    local boom = child(box.root, "Boom")
    assert.are.equal("NotEvaluated", boom.kind)
    assert.are.equal("EvaluationThrew", boom.reason.case)
    assert.are.equal("kaput", boom.reason.detail)
    assert.are.equal("not evaluated: the getter threw: kaput", boom.preview)
    local runs = child(box.root, "RunsCode")
    assert.are.equal("GetterRunsCode", runs.reason.case)
    assert.is_nil(runs.reason.detail)
  end)

  it("replaces the previous snapshot of the same session (the click answer arrives as a new snapshot)", function()
    local state = lb.apply_snapshot(lb.new(), fixture("live_bindings_safe.json"))
    state = lb.apply_snapshot(state, fixture("live_bindings_clicked_runscode.json"))
    local box = binding(lb.get(state, "57bbdfd8"), "box")
    assert.are.equal("Leaf", child(box.root, "RunsCode").kind)
    assert.are.equal("\"1,2,3\"", child(box.root, "RunsCode").preview)
    assert.are.equal("NotEvaluated", child(box.root, "Boom").kind)
  end)

  it("keeps snapshots of different sessions apart", function()
    local state = lb.apply_snapshot(lb.new(), fixture("live_bindings_safe.json"))
    local other = { SessionId = "deadbeef", Generation = 1, Truncated = false, Bindings = {} }
    state = lb.apply_snapshot(state, other)
    assert.is_truthy(lb.get(state, "57bbdfd8"))
    assert.are.same({}, lb.get(state, "deadbeef").bindings)
  end)

  it("bumps the version so renders can skip when nothing changed", function()
    local state = lb.new()
    local v0 = state._version
    state = lb.apply_snapshot(state, fixture("live_bindings_safe.json"))
    assert.is_true(state._version > v0)
  end)

  it("ignores a payload with no session id and a non-table payload", function()
    local state = lb.new()
    assert.are.equal(state, lb.apply_snapshot(state, { Bindings = {} }))
    assert.are.equal(state, lb.apply_snapshot(state, nil))
    assert.are.equal(0, state._version)
  end)

  it("treats a node kind it does not know as a leaf that still shows its preview", function()
    local payload = {
      SessionId = "s1", Generation = 1, Truncated = false,
      Bindings = { { Name = "x", TypeSignature = "T",
        Root = { Label = "x", TypeName = "T", Preview = "future", Kind = { Case = "SomethingNew" },
          Children = {}, BestEffort = false, Depth = 0 } } },
    }
    local snap = lb.get(lb.apply_snapshot(lb.new(), payload), "s1")
    assert.are.equal("SomethingNew", snap.bindings[1].root.kind)
    local rendered = lb.render(snap, lb.new_view("s1"))
    assert.is_truthy(table.concat(rendered.lines, "\n"):find("future", 1, true))
  end)

  it("keeps the Truncated flag", function()
    local payload = { SessionId = "s1", Generation = 2, Truncated = true, Bindings = {} }
    assert.is_true(lb.get(lb.apply_snapshot(lb.new(), payload), "s1").truncated)
  end)
end)

-- ─── Counts and row actions ──────────────────────────────────────────────────

describe("live_bindings.not_evaluated_count", function()
  local function count(name)
    local snap = lb.get(lb.apply_snapshot(lb.new(), fixture(name)), "57bbdfd8")
    return lb.not_evaluated_count(snap)
  end

  it("matches what the daemon said for each real snapshot", function()
    assert.are.equal(4, count("live_bindings_safe.json"))
    assert.are.equal(3, count("live_bindings_clicked_runscode.json"))
    assert.are.equal(4, count("live_bindings_clicked_boom.json"))
    assert.are.equal(0, count("live_bindings_everything.json"))
    assert.are.equal(1, count("live_bindings_off.json"))
  end)
end)

describe("live_bindings.row_action", function()
  local function node_with(case, detail)
    return { kind = "NotEvaluated", reason = { case = case, detail = detail } }
  end

  it("offers a click for a getter that runs code or loops", function()
    assert.are.equal("click", lb.row_action(node_with("GetterRunsCode")))
    assert.are.equal("click", lb.row_action(node_with("GetterLoops")))
  end)

  it("offers nothing for a lazy sequence or a collapsed class", function()
    assert.are.equal("none", lb.row_action(node_with("SequenceNotEnumerated")))
    assert.are.equal("none", lb.row_action(node_with("ClassesCollapsed")))
  end)

  it("shows unknown plus the reason after a click that timed out, threw or was not contained", function()
    assert.are.equal("failed", lb.row_action(node_with("EvaluationTimedOut")))
    assert.are.equal("failed", lb.row_action(node_with("EvaluationThrew", "kaput")))
    assert.are.equal("failed", lb.row_action(node_with("EvaluationNotContained", "no seccomp here")))
  end)

  it("a reason it does not know offers nothing but still shows the words", function()
    assert.are.equal("none", lb.row_action(node_with("BrandNewReason")))
  end)

  it("is nil for a node that is not held", function()
    assert.is_nil(lb.row_action({ kind = "Leaf" }))
  end)
end)

-- ─── Requests and responses ──────────────────────────────────────────────────

describe("live_bindings requests", function()
  it("builds the click request: the labels below the binding's root, never its own label", function()
    local req = lb.build_click_request("57bbdfd8", "box", { "RunsCode" })
    assert.are.equal("POST", req.method)
    assert.are.equal("/api/sessions/57bbdfd8/live-values/evaluate", req.path)
    assert.are.same({ binding = "box", path = { "RunsCode" } }, req.body)
    assert.are.same({ "inner", "Loops" }, lb.build_click_request("s", "box", { "inner", "Loops" }).body.path)
  end)

  it("builds the mode requests", function()
    assert.are.same({ method = "POST", path = "/api/sessions/s1/live-values/mode", body = { mode = "Everything" } },
      lb.build_mode_request("s1", "Everything"))
    assert.are.same({ method = "GET", path = "/api/sessions/s1/live-values/mode" }, lb.build_read_mode_request("s1"))
  end)
end)

describe("live_bindings.parse_click_response", function()
  it("reads a real click that ran the getter, and shows the containment line verbatim", function()
    local _, raw = fixture("click_runscode_response.json")
    local r = lb.parse_click_response(true, raw)
    assert.is_true(r.ok)
    assert.are.equal("MemberShown", r.outcome)
    assert.are.equal(3, r.not_evaluated)
    assert.is_truthy(r.containment:find("ran under a syscall filter (no network, no file writes, no new processes)", 1, true))
    assert.is_truthy(r.containment:find("guarded:", 1, true), "the guard outcome is part of the line")
    assert.is_nil(r.notice)
  end)

  it("a click that threw is still MemberShown: the row is the answer, not an error", function()
    local _, raw = fixture("click_boom_response.json")
    local r = lb.parse_click_response(true, raw)
    assert.is_true(r.ok)
    assert.are.equal("MemberShown", r.outcome)
  end)

  it("reads a binding that is gone", function()
    local _, raw = fixture("click_not_found_response.json")
    local r = lb.parse_click_response(true, raw)
    assert.are.equal("BindingNotFound", r.outcome)
    assert.are.equal("not run: nope is not in the session any more", r.containment)
    assert.is_truthy(r.notice:find("nope", 1, true))
  end)

  it("explains a refusal in the session's current mode (documented shape)", function()
    local raw = vim.json.encode({ success = true, containment = "not run: every getter already ran",
      notEvaluated = 0, outcome = { type = "MemberRefused", value = { { type = "EveryGetterAlreadyRan" } } } })
    local r = lb.parse_click_response(true, raw)
    assert.are.equal("MemberRefused", r.outcome)
    assert.is_truthy(r.notice:lower():find("everything", 1, true))
    local off = lb.parse_click_response(true, vim.json.encode({ success = true, containment = "not run: collapsed",
      notEvaluated = 1, outcome = { type = "MemberRefused", value = { { type = "ClassesAreCollapsed" } } } }))
    assert.is_truthy(off.notice:lower():find("off", 1, true))
  end)

  it("explains when no click could be put (documented shape)", function()
    local raw = vim.json.encode({ success = true, containment = "not run: the session runs FSI in the worker's own process",
      notEvaluated = 2, outcome = { type = "MemberUnavailable", value = { { type = "NoIsolatedHost" } } } })
    local r = lb.parse_click_response(true, raw)
    assert.are.equal("MemberUnavailable", r.outcome)
    assert.is_truthy(r.notice:find("isolated", 1, true))
  end)

  it("turns an HTTP error body into an error that names what the daemon said", function()
    local raw = vim.json.encode({ success = false, error = "this daemon does not keep live bindings" })
    local r = lb.parse_click_response(false, raw)
    assert.is_false(r.ok)
    assert.is_truthy(r.error:find("does not keep live bindings", 1, true))
  end)

  it("turns a transport failure into an error", function()
    local r = lb.parse_click_response(false, "timeout")
    assert.is_false(r.ok)
    assert.is_truthy(r.error:find("timeout", 1, true))
  end)
end)

describe("live_bindings.parse_mode_response", function()
  it("reads the real GET answer", function()
    local _, raw = fixture("mode_get_response.json")
    local r = lb.parse_mode_response(true, raw)
    assert.is_true(r.ok)
    assert.are.equal("Safe", r.mode)
    assert.are.equal("", r.containment)
  end)

  it("reads a mode switch", function()
    local r = lb.parse_mode_response(true, vim.json.encode({ success = true, mode = "Everything", notEvaluated = 0 }))
    assert.are.equal("Everything", r.mode)
    assert.are.equal(0, r.not_evaluated)
  end)

  it("reads the refusal of a mode that does not exist, with the daemon's words", function()
    local r = lb.parse_mode_response(false, vim.json.encode({ success = false,
      error = "'Bogus' is not a way to walk values. The choices are: Safe, Everything, Off." }))
    assert.is_false(r.ok)
    assert.is_truthy(r.error:find("The choices are: Safe, Everything, Off.", 1, true))
  end)
end)

describe("live_bindings modes", function()
  it("has the three the daemon has, Safe first", function()
    assert.are.same({ "Safe", "Everything", "Off" }, lb.MODES)
  end)

  it("describes each in the dashboard's words", function()
    assert.is_truthy(lb.mode_blurb("Safe"):find("runs only getters that provably do nothing", 1, true))
    assert.is_truthy(lb.mode_blurb("Everything"):find("That is your code running", 1, true))
    assert.is_truthy(lb.mode_blurb("Off"):find("Does not open class instances", 1, true))
  end)

  it("only Everything needs a confirmation: it runs your code after every eval", function()
    assert.is_true(lb.mode_needs_confirmation("Everything"))
    assert.is_false(lb.mode_needs_confirmation("Safe"))
    assert.is_false(lb.mode_needs_confirmation("Off"))
  end)

  it("a click only means something in Safe mode", function()
    assert.is_true(lb.click_meaningful("Safe"))
    assert.is_true(lb.click_meaningful(nil), "unknown mode: let the daemon answer")
    assert.is_false(lb.click_meaningful("Everything"))
    assert.is_false(lb.click_meaningful("Off"))
  end)
end)

-- ─── The view model ──────────────────────────────────────────────────────────

describe("live_bindings.sync_view", function()
  it("resets the mode, the containment line, the notice and the folds when the session changes", function()
    local view = lb.new_view("A")
    view.mode, view.containment, view.notice = "Everything", "line", "note"
    view.expanded.k = true
    view._effective.k = true
    lb.sync_view(view, "B")
    assert.are.equal("B", view.session_id)
    assert.is_nil(view.mode)
    assert.are.equal("", view.containment)
    assert.is_nil(view.notice)
    assert.are.same({}, view.expanded)
    assert.are.same({}, view._effective)
  end)

  it("leaves the view alone while the session stays the same", function()
    local view = lb.new_view("A")
    view.mode, view.notice = "Off", "note"
    lb.sync_view(view, "A")
    assert.are.equal("Off", view.mode)
    assert.are.equal("note", view.notice)
  end)
end)

describe("live_bindings.render", function()
  local function render(name, view_fn)
    local snap = lb.get(lb.apply_snapshot(lb.new(), fixture(name)), "57bbdfd8")
    local view = lb.new_view("57bbdfd8")
    if view_fn then view_fn(view) end
    return lb.render(snap, view), snap
  end

  local function text_of(r) return table.concat(r.lines, "\n") end

  local function row_for(r, label)
    for lnum, row in pairs(r.rows) do
      if row.node and row.node.label == label then return row, lnum end
    end
  end

  it("draws a header with the session, the mode and how many are not evaluated", function()
    local r = render("live_bindings_safe.json", function(v) v.mode = "Safe" end)
    assert.is_truthy(r.lines[1]:find("57bbdfd8", 1, true))
    assert.is_truthy(r.lines[1]:find("Safe", 1, true))
    assert.is_truthy(r.lines[1]:find("4 not evaluated", 1, true))
  end)

  it("shows the containment line when a click has set one, and not before", function()
    local before = render("live_bindings_safe.json")
    assert.is_nil(text_of(before):find("syscall filter", 1, true))
    local after = render("live_bindings_clicked_runscode.json", function(v)
      v.containment = "ran under a syscall filter (no network, no file writes, no new processes)"
    end)
    assert.is_truthy(text_of(after):find("ran under a syscall filter", 1, true))
  end)

  it("draws the tree: bindings, their members, types and previews", function()
    local r = render("live_bindings_safe.json")
    local text = text_of(r)
    assert.is_truthy(text:find("box", 1, true))
    assert.is_truthy(text:find("size", 1, true))
    assert.is_truthy(text:find("Int32", 1, true))
    assert.is_truthy(text:find("= 7", 1, true))
    assert.is_truthy(text:find("[0]", 1, true), "list elements are labeled by index")
    assert.is_truthy(text:find("X", 1, true))
  end)

  it("a held row always shows its reason, never an empty value", function()
    local r = render("live_bindings_safe.json")
    local row = row_for(r, "RunsCode")
    local line = r.lines[select(2, row_for(r, "RunsCode"))]
    assert.is_truthy(line:find("not evaluated: the getter calls other code", 1, true))
    assert.is_truthy(line:lower():find("run", 1, true))
    assert.are.equal("click", row.action)
  end)

  it("a click-failed row says unknown and shows the reason", function()
    local r = render("live_bindings_clicked_boom.json")
    local row, lnum = row_for(r, "Boom")
    assert.are.equal("failed", row.action)
    assert.is_truthy(r.lines[lnum]:find("unknown", 1, true))
    assert.is_truthy(r.lines[lnum]:find("the getter threw: kaput", 1, true))
  end)

  it("the click path is the labels from the root down, excluding the binding's own label", function()
    local r = render("live_bindings_safe.json")
    local row = row_for(r, "RunsCode")
    assert.are.equal("box", row.binding)
    assert.are.same({ "RunsCode" }, row.path)
  end)

  it("a nested getter has the whole path", function()
    local function n(label, depth, kind, children, preview)
      return { Label = label, TypeName = "T", Preview = preview or label, Kind = kind, Children = children or {},
        BestEffort = false, Depth = depth }
    end
    local loops = n("Loops", 2, { Case = "NotEvaluated", Fields = { { Case = "GetterLoops" } } }, nil,
      "not evaluated: the getter loops or calls itself")
    local inner = n("inner", 1, { Case = "Class" }, { loops })
    local payload = { SessionId = "s1", Generation = 1, Truncated = false,
      Bindings = { { Name = "box", TypeSignature = "Box", Root = n("box", 0, { Case = "Class" }, { inner }) } } }
    local snap = lb.get(lb.apply_snapshot(lb.new(), payload), "s1")
    local r = lb.render(snap, lb.new_view("s1"))
    local row = row_for(r, "Loops")
    assert.are.same({ "inner", "Loops" }, row.path)
    assert.are.equal("click", row.action)
  end)

  it("rows only exist for lines that mean something; header lines have none", function()
    local r = render("live_bindings_safe.json")
    assert.is_nil(r.rows[1])
  end)

  it("folds a binding when asked, and keeps the choice across renders", function()
    local snap = lb.get(lb.apply_snapshot(lb.new(), fixture("live_bindings_safe.json")), "57bbdfd8")
    local view = lb.new_view("57bbdfd8")
    local open = lb.render(snap, view)
    local row_open = row_for(open, "box")
    lb.toggle(view, row_open.key)
    local closed = lb.render(snap, view)
    assert.is_nil(table.concat(closed.lines, "\n"):find("RunsCode : String", 1, true), "children are hidden")
    assert.is_true(#closed.lines < #open.lines)
    lb.toggle(view, row_open.key)
    assert.are.equal(#open.lines, #lb.render(snap, view).lines)
  end)

  it("says so when the daemon sent nothing yet", function()
    local r = lb.render(nil, lb.new_view("57bbdfd8"))
    assert.is_truthy(table.concat(r.lines, "\n"):find("no live bindings", 1, true))
  end)

  it("says so when the session has no bindings", function()
    local snap = lb.get(lb.apply_snapshot(lb.new(), { SessionId = "s1", Generation = 1, Truncated = false, Bindings = {} }), "s1")
    local r = lb.render(snap, lb.new_view("s1"))
    assert.is_truthy(table.concat(r.lines, "\n"):find("no bindings", 1, true))
  end)

  it("shows a notice under the header (a refused click, a failed request)", function()
    local r = render("live_bindings_safe.json", function(v) v.notice = "nothing to run: the mode is Off" end)
    assert.is_truthy(text_of(r):find("nothing to run: the mode is Off", 1, true))
  end)

  it("tells you the mode when it is Off and every class is collapsed", function()
    local r = render("live_bindings_off.json", function(v) v.mode = "Off" end)
    assert.is_truthy(text_of(r):find("this mode does not open class instances", 1, true))
    local row = row_for(r, "box")
    assert.are.equal("none", row.action)
  end)

  it("Everything shows the walked values", function()
    local r = render("live_bindings_everything.json", function(v) v.mode = "Everything" end)
    assert.is_truthy(text_of(r):find("Boom", 1, true))
    assert.is_truthy(text_of(r):find("<error>", 1, true))
  end)
end)

describe("live_bindings.render a click in flight", function()
  local function render_with(view_fn)
    local snap = lb.get(lb.apply_snapshot(lb.new(), fixture("live_bindings_safe.json")), "57bbdfd8")
    local view = lb.new_view("57bbdfd8")
    view_fn(view)
    return lb.render(snap, view)
  end

  it("says which getter is running, under the header", function()
    local r = render_with(function(v) v.pending = { binding = "box", path = { "RunsCode" } } end)
    local text = table.concat(r.lines, "\n")
    assert.is_truthy(text:find("running box.RunsCode", 1, true))
  end)

  it("says nothing about a click when none is in flight", function()
    local r = render_with(function() end)
    assert.is_nil(table.concat(r.lines, "\n"):find("running", 1, true))
  end)

  it("is cleared when the session changes", function()
    local view = lb.new_view("A")
    view.pending = { binding = "box", path = { "X" } }
    lb.sync_view(view, "B")
    assert.is_nil(view.pending)
  end)
end)

describe("live_bindings.render a long containment line", function()
  local LONG = "ran under a syscall filter (no network, no file writes, no new processes); "
    .. "guarded: stack and loops checked in 1 method; "
    .. "not guarded: 2 x code in FSharp.Core, which SageFs does not own; "
    .. "1 x code in System.Private.CoreLib, which SageFs does not own"

  local function render_with(containment)
    local snap = lb.get(lb.apply_snapshot(lb.new(), fixture("live_bindings_clicked_runscode.json")), "57bbdfd8")
    local view = lb.new_view("57bbdfd8")
    view.containment = containment
    return lb.render(snap, view)
  end

  it("is split at its own semicolons so no line is wider than a pane can show", function()
    local r = render_with(LONG)
    local widest = 0
    for _, l in ipairs(r.lines) do
      if l:find("syscall filter", 1, true) or l:find("guarded", 1, true) or l:find("FSharp.Core", 1, true)
        or l:find("CoreLib", 1, true) then
        widest = math.max(widest, #l)
      end
    end
    assert.is_true(widest > 0)
    assert.is_true(widest <= 90, "widest containment line is " .. widest)
  end)

  it("loses no word: the lines joined with the daemon's separator are the daemon's line", function()
    local r = render_with(LONG)
    local parts = {}
    for _, l in ipairs(r.lines) do
      if l:find("syscall filter", 1, true) or l:find("guarded", 1, true) or l:find("FSharp.Core", 1, true)
        or l:find("CoreLib", 1, true) then
        table.insert(parts, l)
      end
    end
    assert.are.equal(LONG, table.concat(parts, "; "))
  end)

  it("highlights every piece of it as containment", function()
    local r = render_with(LONG)
    local n = 0
    for _, h in ipairs(r.highlights) do
      if h.group == "SageFsBindingsContainment" then n = n + 1 end
    end
    assert.are.equal(4, n)
  end)

  it("keeps a short line as one line", function()
    local r = render_with("not run: nope is not in the session any more")
    assert.are.equal("not run: nope is not in the session any more", r.lines[2])
  end)
end)

describe("live_bindings.line_of_key", function()
  it("finds the line a row key is on, so a redraw can keep the cursor on the same row", function()
    local rows = { [5] = { key = "box" }, [6] = { key = "box\31RunsCode" }, [7] = { key = "box\31Boom" } }
    assert.are.equal(6, lb.line_of_key(rows, "box\31RunsCode"))
    assert.are.equal(5, lb.line_of_key(rows, "box"))
  end)

  it("is nil for a key that is not drawn any more, or no key", function()
    assert.is_nil(lb.line_of_key({ [5] = { key = "box" } }, "gone"))
    assert.is_nil(lb.line_of_key({ [5] = { key = "box" } }, nil))
  end)
end)
