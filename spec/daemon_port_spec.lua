-- =============================================================================
-- Which port the daemon binds, and which port a client asks for — sagefs/daemon_port.lua
-- =============================================================================
-- The same rule as SageFs.Core/DaemonPort.fs: SAGEFS_MCP_PORT, then the port the Settings panel
-- persisted (daemon.mcpPort), then 37749. It is here because the plugin only ever read the
-- environment, so a port set in the Settings panel made every command in this plugin ask a daemon
-- that was not there.

local port = require("sagefs.daemon_port")

describe("daemon_port", function()

  describe("choose", function()

    it("the environment wins over the persisted panel value", function()
      assert.are.equal(40001, port.choose("40001", "40000", 37749))
    end)

    it("the panel's value wins over the default", function()
      assert.are.equal(40000, port.choose(nil, "40000", 37749))
    end)

    it("the default holds when neither names a port", function()
      assert.are.equal(37749, port.choose(nil, nil, 37749))
    end)

    it("a value that is not a number names nothing", function()
      assert.are.equal(37749, port.choose("nope", "nope", 37749))
      assert.are.equal(37749, port.choose("", "", 37749))
    end)
  end)

  describe("configured", function()

    local saved
    before_each(function()
      saved = { data = vim.env.SAGEFS_DATA_DIR, port = vim.env.SAGEFS_MCP_PORT }
    end)

    after_each(function()
      vim.env.SAGEFS_DATA_DIR = saved.data
      vim.env.SAGEFS_MCP_PORT = saved.port
    end)

    it("takes the environment when it is set", function()
      vim.env.SAGEFS_MCP_PORT = "40003"
      assert.are.equal(40003, port.configured())
    end)

    it("reads the panel's daemon.mcpPort out of the data directory when the environment says nothing", function()
      vim.env.SAGEFS_MCP_PORT = nil
      local dir = "/tmp/sagefs-daemon-port-spec-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000))
      os.execute("mkdir -p '" .. dir .. "'")
      local handle = assert(io.open(dir .. "/settings.json", "w"))
      handle:write('{"daemon.mcpPort":"40004"}')
      handle:close()
      vim.env.SAGEFS_DATA_DIR = dir
      local configured = port.configured()
      os.execute("rm -rf '" .. dir .. "'")
      assert.are.equal(40004, configured)
    end)

    it("falls back to 37749 when the data directory holds no settings", function()
      vim.env.SAGEFS_MCP_PORT = nil
      vim.env.SAGEFS_DATA_DIR = "/tmp/sagefs-daemon-port-spec-missing-" .. tostring(os.time())
      assert.are.equal(37749, port.configured())
    end)
  end)
end)
