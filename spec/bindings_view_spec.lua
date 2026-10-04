-- Tests: the live bindings controller (sagefs.bindings_view): the click, the
-- mode switch and the refresh, against a fake HTTP layer. The buffer and window
-- are not touched here; headless Neovim covers those against the dev daemon.
require("spec.helper")

local bv = require("sagefs.bindings_view")
local util = require("sagefs.util")

local function fixture_text(name)
  local src = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
  local f = assert(io.open(src .. "fixtures/wire/" .. name, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

local function make(script, overrides)
  local env = { calls = {}, notes = {}, changes = 0, confirms = {} }
  local deps = {
    base_url = function() return "http://localhost:37749" end,
    session_id = function() return "57bbdfd8" end,
    notify = function(msg, level) table.insert(env.notes, { msg = msg, level = level }) end,
    on_change = function() env.changes = env.changes + 1 end,
    confirm = function(prompt, cb)
      table.insert(env.confirms, prompt)
      cb(env.confirm_answer ~= false)
    end,
    http = function(opts)
      table.insert(env.calls, opts)
      local reply = table.remove(script, 1)
      if reply then opts.callback(reply[1], reply[2]) end
    end,
  }
  for k, v in pairs(overrides or {}) do deps[k] = v end
  env.ctl = bv.new_controller(deps)
  return env
end

local CLICK_ROW = { kind = "node", binding = "box", path = { "RunsCode" }, action = "click",
  node = { label = "RunsCode", kind = "NotEvaluated" } }

describe("bindings_view click", function()
  it("posts the binding and the path to the evaluate route for the session", function()
    local env = make({ { true, fixture_text("click_runscode_response.json") } })
    env.ctl.click(CLICK_ROW)
    assert.are.equal(1, #env.calls)
    assert.are.equal("POST", env.calls[1].method)
    assert.are.equal("http://localhost:37749/api/sessions/57bbdfd8/live-values/evaluate", env.calls[1].url)
    assert.are.same({ binding = "box", path = { "RunsCode" } }, env.calls[1].body)
  end)

  it("gives a click the time a getter deadline needs", function()
    local env = make({ { true, fixture_text("click_runscode_response.json") } })
    env.ctl.click(CLICK_ROW)
    assert.is_true(env.calls[1].timeout >= 15)
  end)

  it("puts the containment line, verbatim, under the header and does not patch the tree itself", function()
    local env = make({ { true, fixture_text("click_runscode_response.json") } })
    env.ctl.click(CLICK_ROW)
    assert.is_truthy(env.ctl.view.containment:find("ran under a syscall filter", 1, true))
    assert.is_true(env.changes >= 1)
  end)

  it("does not send a click for a row that offers none", function()
    local env = make({})
    env.ctl.click({ kind = "node", binding = "box", path = { "Lazy" }, action = "none" })
    assert.are.equal(0, #env.calls)
    assert.are.equal(1, #env.notes)
  end)

  it("does not send a click for a header or blank line", function()
    local env = make({})
    env.ctl.click(nil)
    assert.are.equal(0, #env.calls)
  end)

  it("says why when the mode makes the click meaningless, without a request", function()
    local env = make({})
    env.ctl.view.mode = "Everything"
    env.ctl.click(CLICK_ROW)
    assert.are.equal(0, #env.calls)
    assert.is_truthy(env.ctl.view.notice:find("Everything", 1, true))
  end)

  it("shows a refusal or an unavailable click as a notice", function()
    local env = make({ { true, vim.json.encode({ success = true, containment = "not run: the session runs FSI in the worker's own process",
      notEvaluated = 2, outcome = { type = "MemberUnavailable", value = { { type = "NoIsolatedHost" } } } }) } })
    env.ctl.click(CLICK_ROW)
    assert.is_truthy(env.ctl.view.notice:find("isolated", 1, true))
  end)

  it("shows a daemon error as a notice, with the daemon's words", function()
    local env = make({ { false, vim.json.encode({ success = false, error = "Session '57bbdfd8' not found or not ready" }) } })
    env.ctl.click(CLICK_ROW)
    assert.is_truthy(env.ctl.view.notice:find("not found or not ready", 1, true))
  end)

  it("shows a transport failure as a notice", function()
    local env = make({ { false, "timeout" } })
    env.ctl.click(CLICK_ROW)
    assert.is_truthy(env.ctl.view.notice:find("timeout", 1, true))
  end)

  it("a click with no active session says so and sends nothing", function()
    local env = make({}, { session_id = function() return nil end })
    env.ctl.click(CLICK_ROW)
    assert.are.equal(0, #env.calls)
    assert.is_truthy(env.notes[1].msg:find("session", 1, true))
  end)
end)

describe("bindings_view when the active session changes", function()
  local function mode_json(mode, containment)
    return vim.json.encode({ success = true, mode = mode, containment = containment or "", notEvaluated = 1 })
  end

  it("forgets the previous session's mode, containment and notice", function()
    local sid = "A"
    local env = make({ { true, mode_json("Off", "line from A") } }, { session_id = function() return sid end })
    env.ctl.read_mode()
    assert.are.equal("Off", env.ctl.view.mode)
    assert.are.equal("line from A", env.ctl.view.containment)
    env.ctl.view.notice = "a notice about A"
    sid = "B"
    env.ctl.click(nil) -- any controller entry point sees the new session
    assert.is_nil(env.ctl.view.mode)
    assert.are.equal("", env.ctl.view.containment)
    assert.is_nil(env.ctl.view.notice)
    assert.are.equal("B", env.ctl.view.session_id)
  end)

  it("does not refuse a click in session B because session A was in Off mode", function()
    local sid = "A"
    local env = make({ { true, mode_json("Off") }, { true, fixture_text("click_runscode_response.json") } },
      { session_id = function() return sid end })
    env.ctl.read_mode()
    sid = "B"
    env.ctl.click(CLICK_ROW)
    assert.are.equal(2, #env.calls, "the click for B went out")
    assert.is_truthy(env.calls[2].url:find("/api/sessions/B/live-values/evaluate", 1, true))
  end)

  it("keeps the mode while the session stays the same", function()
    local env = make({ { true, mode_json("Off") } })
    env.ctl.read_mode()
    env.ctl.click(nil)
    assert.are.equal("Off", env.ctl.view.mode)
  end)
end)

describe("bindings_view mode", function()
  it("switches to Off with one request and remembers the mode", function()
    local env = make({ { true, vim.json.encode({ success = true, mode = "Off", notEvaluated = 1 }) } })
    env.ctl.view.containment = "ran under a syscall filter"
    env.ctl.set_mode("Off")
    assert.are.equal("http://localhost:37749/api/sessions/57bbdfd8/live-values/mode", env.calls[1].url)
    assert.are.same({ mode = "Off" }, env.calls[1].body)
    assert.are.equal("Off", env.ctl.view.mode)
    assert.are.equal("", env.ctl.view.containment, "the daemon drops the last click's line when the mode changes")
  end)

  it("asks before running your getters on every eval, and sends nothing when you decline", function()
    local env = make({ { true, vim.json.encode({ success = true, mode = "Everything", notEvaluated = 0 }) } })
    env.confirm_answer = false
    env.ctl.set_mode("Everything")
    assert.are.equal(1, #env.confirms)
    assert.is_truthy(env.confirms[1]:find("your code", 1, true))
    assert.are.equal(0, #env.calls)
  end)

  it("switches to Everything once you agree", function()
    local env = make({ { true, vim.json.encode({ success = true, mode = "Everything", notEvaluated = 0 }) } })
    env.ctl.set_mode("Everything")
    assert.are.equal(1, #env.calls)
    assert.are.equal("Everything", env.ctl.view.mode)
  end)

  it("does not ask to go back to Safe", function()
    local env = make({ { true, vim.json.encode({ success = true, mode = "Safe", notEvaluated = 4 }) } })
    env.ctl.set_mode("Safe")
    assert.are.equal(0, #env.confirms)
  end)

  it("keeps the old mode and shows the daemon's words when the switch is refused", function()
    local env = make({ { false, vim.json.encode({ success = false, error = "'Bogus' is not a way to walk values. The choices are: Safe, Everything, Off." }) } })
    env.ctl.view.mode = "Safe"
    env.ctl.set_mode("Bogus")
    assert.are.equal("Safe", env.ctl.view.mode)
    assert.is_truthy(env.ctl.view.notice:find("The choices are", 1, true))
  end)

  it("cycles Safe, Everything, Off, Safe", function()
    assert.are.equal("Everything", bv.next_mode("Safe"))
    assert.are.equal("Off", bv.next_mode("Everything"))
    assert.are.equal("Safe", bv.next_mode("Off"))
    assert.are.equal("Safe", bv.next_mode(nil))
  end)
end)

describe("bindings_view refresh", function()
  it("reads the mode, then posts the same mode so the daemon pushes a fresh snapshot (there is no snapshot GET)", function()
    local env = make({
      { true, fixture_text("mode_get_response.json") },
      { true, vim.json.encode({ success = true, mode = "Safe", notEvaluated = 4 }) },
    })
    env.ctl.refresh()
    assert.are.equal(2, #env.calls)
    assert.are.equal("GET", env.calls[1].method)
    assert.are.equal("POST", env.calls[2].method)
    assert.are.same({ mode = "Safe" }, env.calls[2].body)
    assert.are.equal("Safe", env.ctl.view.mode)
  end)

  it("drops the click's containment line, because re-posting the mode makes the daemon drop it", function()
    local env = make({
      { true, vim.json.encode({ success = true, mode = "Safe", notEvaluated = 3, containment = "ran under a syscall filter" }) },
      { true, vim.json.encode({ success = true, mode = "Safe", notEvaluated = 3 }) },
    })
    env.ctl.refresh()
    assert.are.equal("", env.ctl.view.containment)
  end)

  it("shows the daemon's words when the session is not ready", function()
    local env = make({ { false, vim.json.encode({ success = false, error = "Session '57bbdfd8' not found or not ready" }) } })
    env.ctl.refresh()
    assert.are.equal(1, #env.calls)
    assert.is_truthy(env.ctl.view.notice:find("not found or not ready", 1, true))
  end)

  it("a daemon that keeps no live bindings says so", function()
    local env = make({ { false, vim.json.encode({ success = false, error = "this daemon does not keep live bindings" }) } })
    env.ctl.refresh()
    assert.is_truthy(env.ctl.view.notice:find("does not keep live bindings", 1, true))
  end)

  it("only reads the mode (no re-walk) when asked to, so opening a view that has data changes nothing", function()
    local env = make({ { true, fixture_text("mode_get_response.json") } })
    env.ctl.read_mode()
    assert.are.equal(1, #env.calls)
    assert.are.equal("GET", env.calls[1].method)
    assert.are.equal("Safe", env.ctl.view.mode)
  end)
end)

-- A click runs the user's getter on the daemon, under a deadline. A getter that
-- spins takes about ten seconds to answer (seen against 0.6.892), and until the
-- answer arrives the pane used to look exactly as it did before the click.
describe("bindings_view a click in flight", function()
  -- A fake HTTP layer that holds the callback until the test lets it answer.
  local function make_held(overrides)
    local env = { calls = {}, notes = {}, changes = 0, waiting = {}, sid = "57bbdfd8" }
    local deps = {
      base_url = function() return "http://localhost:37749" end,
      session_id = function() return env.sid end,
      notify = function(msg, level) table.insert(env.notes, { msg = msg, level = level }) end,
      on_change = function() env.changes = env.changes + 1 end,
      confirm = function(_, cb) cb(true) end,
      http = function(opts)
        table.insert(env.calls, opts)
        table.insert(env.waiting, opts.callback)
      end,
    }
    for k, v in pairs(overrides or {}) do deps[k] = v end
    env.ctl = bv.new_controller(deps)
    return env
  end

  it("marks the row as running as soon as the click is sent, and redraws", function()
    local env = make_held()
    env.ctl.click(CLICK_ROW)
    assert.are.same({ binding = "box", path = { "RunsCode" } }, env.ctl.view.pending)
    assert.is_true(env.changes >= 1, "the pane redraws so the user sees the click went out")
  end)

  it("clears the running mark when the answer arrives", function()
    local env = make_held()
    env.ctl.click(CLICK_ROW)
    env.waiting[1](true, fixture_text("click_runscode_response.json"))
    assert.is_nil(env.ctl.view.pending)
  end)

  it("clears the running mark when the request fails", function()
    local env = make_held()
    env.ctl.click(CLICK_ROW)
    env.waiting[1](false, "timeout")
    assert.is_nil(env.ctl.view.pending)
    assert.is_truthy(env.ctl.view.notice:find("timeout", 1, true))
  end)

  it("does not send a second click while one is running", function()
    local env = make_held()
    env.ctl.click(CLICK_ROW)
    env.ctl.click(CLICK_ROW)
    assert.are.equal(1, #env.calls)
    assert.is_truthy(env.notes[1].msg:find("running", 1, true))
  end)

  it("takes the next click once the first has answered", function()
    local env = make_held()
    env.ctl.click(CLICK_ROW)
    env.waiting[1](true, fixture_text("click_runscode_response.json"))
    env.ctl.click(CLICK_ROW)
    assert.are.equal(2, #env.calls)
  end)

  it("drops an answer that comes back after the active session changed", function()
    local env = make_held()
    env.ctl.click(CLICK_ROW)
    env.sid = "aaaaaaaa"
    env.waiting[1](true, fixture_text("click_runscode_response.json"))
    assert.are.equal("", env.ctl.view.containment, "session A's containment line must not show on session B")
    assert.is_nil(env.ctl.view.pending)
  end)
end)

-- The same rule for the other two routes: an answer is about the session it was
-- asked of, and a slow answer must not put session A's mode on session B's pane.
describe("bindings_view a late mode answer", function()
  local function make_held()
    local env = { calls = {}, waiting = {}, sid = "A" }
    env.ctl = bv.new_controller({
      base_url = function() return "http://localhost:37749" end,
      session_id = function() return env.sid end,
      notify = function() end,
      on_change = function() end,
      confirm = function(_, cb) cb(true) end,
      http = function(opts) table.insert(env.calls, opts); table.insert(env.waiting, opts.callback) end,
    })
    return env
  end

  it("a mode switch answered after the session changed is not shown on the new session", function()
    local env = make_held()
    env.ctl.set_mode("Off")
    env.sid = "B"
    env.waiting[1](true, vim.json.encode({ success = true, mode = "Off", notEvaluated = 0 }))
    assert.is_nil(env.ctl.view.mode)
  end)

  it("a mode read answered after the session changed is not shown on the new session", function()
    local env = make_held()
    env.ctl.read_mode()
    env.sid = "B"
    env.waiting[1](true, vim.json.encode({ success = true, mode = "Off", notEvaluated = 0, containment = "line from A" }))
    assert.is_nil(env.ctl.view.mode)
    assert.are.equal("", env.ctl.view.containment)
  end)

  it("a mode answer for the session still active is applied", function()
    local env = make_held()
    env.ctl.set_mode("Off")
    env.waiting[1](true, vim.json.encode({ success = true, mode = "Off", notEvaluated = 0 }))
    assert.are.equal("Off", env.ctl.view.mode)
  end)
end)
