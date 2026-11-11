-- spec/dashboard/actions_spec.lua — no dead controls in the dashboard
--
-- Every action a section can attach to a line must resolve to something that
-- happens. The dispatcher used to guard each call with `if sagefs.<fn> then`, and
-- four of the functions it named did not exist, so those keys did nothing.

local actions = require("sagefs.dashboard.actions")
local state_mod = require("sagefs.dashboard.state")
local section_mod = require("sagefs.dashboard.section")

local function populated_state()
  local s = state_mod.new()
  s.testing.enabled = true
  s.testing.summary = { total = 2, passed = 1, failed = 1, stale = 0, running = 0 }
  s.testing.failure_narratives = { { testName = "my_test", summary = "boom" } }
  s.bindings = { { name = "foo", typeSig = "int", value = "1" } }
  s.filmstrip = { { index = 1, label = "let x = 1", durationMs = 4, status = "ok" } }
  s.sessions = { { id = "abc12345-long", status = "Ready", project = "Tests" } }
  s.hot_reload = { enabled = true, watched_files = { "a.fs" }, total_files = 1 }
  return s
end

local function emitted_actions()
  local seen, list = {}, {}
  for _, id in ipairs({ "health", "tests", "diagnostics", "failures", "session", "hot_reload", "output",
                        "bindings", "coverage", "filmstrip", "alarms", "help" }) do
    local sec = require("sagefs.dashboard.sections." .. id)
    local out = sec.render(populated_state())
    for _, km in ipairs(out.keymaps or {}) do
      if not seen[km.action.type] then
        seen[km.action.type] = true
        table.insert(list, { section = id, action = km.action })
      end
    end
  end
  return list
end

describe("dashboard actions", function()
  it("every action a section emits resolves to an effect", function()
    local ctx = { testing_state = { tests = { t1 = { displayName = "my_test", file = "src/A.fs", line = 7, status = "Failed" } } } }
    local list = emitted_actions()
    assert.is_true(#list >= 5, "the populated state should make several sections emit actions")
    for _, e in ipairs(list) do
      local effect = actions.resolve(e.action, ctx)
      assert.is_truthy(effect, e.section .. " emits '" .. e.action.type .. "' and nothing handles it")
      assert.is_truthy(actions.KINDS[effect.kind], "unknown effect kind " .. tostring(effect.kind))
    end
  end)

  it("jump_to_test opens the file and line of the test with that name", function()
    local ctx = { testing_state = { tests = { t1 = { displayName = "my_test", file = "src/A.fs", line = 7 } } } }
    local effect = actions.resolve({ type = "jump_to_test", test_name = "my_test" }, ctx)
    assert.equals("open", effect.kind)
    assert.equals("src/A.fs", effect.file)
    assert.equals(7, effect.line)
  end)

  it("jump_to_test says so when the test has no known source", function()
    local effect = actions.resolve({ type = "jump_to_test", test_name = "ghost" }, { testing_state = { tests = {} } })
    assert.equals("notify", effect.kind)
    assert.is_truthy(effect.message:find("ghost", 1, true))
  end)

  it("an action nobody handles resolves to nothing, so the dispatcher can say so", function()
    assert.is_nil(actions.resolve({ type = "no_such_action" }, {}))
  end)
end)
