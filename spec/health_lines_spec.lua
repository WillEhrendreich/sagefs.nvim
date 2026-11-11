-- Two :checkhealth lines that said something false or pointed at the wrong command:
-- an active session with an empty session list printed `Active session: table: 0x...`,
-- and "Live testing: not enabled" told the user to run :SageFsRunTests, which runs tests
-- but does not turn live testing on (:SageFsEnableTesting does).
require("spec.helper")

describe("sagefs.health lines", function()
  local saved = {}
  local ok_msgs, info_msgs

  local function run(sagefs_fields)
    package.loaded["sagefs.health"] = nil
    saved.system, saved.v, saved.health, saved.sagefs = vim.fn.system, vim.v, vim.health, package.loaded["sagefs"]
    vim.v = { shell_error = 1 }
    vim.fn.system = function() return "" end
    ok_msgs, info_msgs = {}, {}
    vim.health = {
      start = function() end, warn = function() end, error = function() end,
      ok = function(m) table.insert(ok_msgs, m) end,
      info = function(m) table.insert(info_msgs, m) end,
    }
    local base = {
      version = "test", state = { status = "connected" },
      config = { port = 37749, dashboard_port = 37750, auto_connect = false, check_on_save = false },
      session_list = {}, active_session = nil, testing_state = nil,
    }
    for k, v in pairs(sagefs_fields) do base[k] = v end
    package.loaded["sagefs"] = base
    require("sagefs.health").check()
  end

  after_each(function()
    vim.fn.system, vim.v, vim.health, package.loaded["sagefs"] = saved.system, saved.v, saved.health, saved.sagefs
    package.loaded["sagefs.health"] = nil
  end)

  it("names the active session when the session list is empty, never a table address", function()
    run({ active_session = { id = "abc123", name = "App", status = "Ready" } })
    local line
    for _, m in ipairs(ok_msgs) do if m:find("Active session", 1, true) then line = m end end
    assert.is_truthy(line, "an Active session line")
    assert.is_nil(line:find("table: ", 1, true), line)
    assert.is_truthy(line:find("abc123", 1, true), line)
  end)

  it("points a disabled live-testing line at :SageFsEnableTesting", function()
    run({ testing_state = { enabled = false, summary = {} } })
    local line
    for _, m in ipairs(info_msgs) do if m:find("Live testing: not enabled", 1, true) then line = m end end
    assert.is_truthy(line, "a 'not enabled' line")
    assert.is_truthy(line:find(":SageFsEnableTesting", 1, true), line)
    assert.is_nil(line:find(":SageFsRunTests", 1, true), line)
  end)
end)
