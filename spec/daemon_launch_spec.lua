-- Tests: how the e2e harness starts a daemon (spec/e2e/daemon_launch.lua). The
-- harness used to start `sagefs --mcp-port N --ttl 4h` with the user's own data
-- directory, so every e2e run read and wrote the real ~/.SageFs (the session
-- manifest, resumed sessions), and nothing ended the daemon if the test run died.
require("spec.helper")

local launch = require("spec.e2e.daemon_launch")

describe("e2e daemon launch", function()
  it("starts a daemon on the given port that does not resume the user's sessions", function()
    local cmd = launch.command("/usr/bin/sagefs", 47791, 4242)
    assert.are.equal("/usr/bin/sagefs", cmd[1])
    local joined = " " .. table.concat(cmd, " ") .. " "
    assert.is_truthy(joined:find(" --mcp-port 47791 ", 1, true))
    assert.is_truthy(joined:find(" --no-resume ", 1, true))
  end)

  it("ends the daemon when the test run does: owner pid, and a ttl as the backstop", function()
    local joined = " " .. table.concat(launch.command("sagefs", 47791, 4242), " ") .. " "
    assert.is_truthy(joined:find(" --owner-pid 4242 ", 1, true))
    assert.is_truthy(joined:find(" --ttl ", 1, true))
  end)

  it("sends the port and the pid as separate arguments, so nothing is shell-split", function()
    for _, arg in ipairs(launch.command("sagefs", 47791, 4242)) do
      assert.are.equal("string", type(arg))
      assert.is_nil(arg:find("%s"), "argument with a space: " .. arg)
    end
  end)

  it("gives the daemon its own data directory", function()
    local env = launch.environment("/tmp/e2e-data-1")
    assert.are.equal("/tmp/e2e-data-1", env.SAGEFS_DATA_DIR)
  end)

  it("refuses to run with no data directory, because that would be the user's own", function()
    assert.has_error(function() launch.environment(nil) end)
    assert.has_error(function() launch.environment("") end)
  end)

  it("refuses the user's own data directory", function()
    local home = os.getenv("HOME") or "/home/x"
    assert.has_error(function() launch.environment(home .. "/.SageFs") end)
  end)
end)
