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
