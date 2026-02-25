-- =============================================================================
-- Daemon lifecycle management — sagefs/daemon.lua
-- =============================================================================
-- Pure state machine for daemon start/stop. No vim APIs.
-- init.lua wires this to jobstart/jobstop.

local daemon = require("sagefs.daemon")

describe("daemon", function()

  describe("new", function()
    it("starts with idle status and no job", function()
      local state = daemon.new()
      assert.are.equal("idle", state.status)
      assert.is_nil(state.job_id)
      assert.is_nil(state.project)
      assert.is_nil(state.port)
    end)
  end)

  describe("start_command", function()
    it("builds sagefs command with --proj for .fsproj files", function()
      local cmd = daemon.start_command({
        project = "MyApp.fsproj",
        port = 37749,
      })
      assert.is_table(cmd)
      assert.are.equal("sagefs", cmd[1])
      local has_proj = false
      for i, v in ipairs(cmd) do
        if v == "--proj" then
          assert.are.equal("MyApp.fsproj", cmd[i + 1])
          has_proj = true
        end
      end
      assert.is_true(has_proj, "command must include --proj")
    end)

    it("uses --sln for .slnx files", function()
      local cmd = daemon.start_command({
        project = "Harmony.slnx",
        port = 37749,
      })
      local has_sln = false
      for i, v in ipairs(cmd) do
        if v == "--sln" then
          assert.are.equal("Harmony.slnx", cmd[i + 1])
          has_sln = true
        end
      end
      assert.is_true(has_sln, "command must include --sln for .slnx")
    end)

    it("uses --sln for .sln files", function()
      local cmd = daemon.start_command({
        project = "MyApp.sln",
        port = 37749,
      })
      local has_sln = false
      for i, v in ipairs(cmd) do
        if v == "--sln" then
          assert.are.equal("MyApp.sln", cmd[i + 1])
          has_sln = true
        end
      end
      assert.is_true(has_sln, "command must include --sln for .sln")
    end)

    it("includes --mcp-port when specified", function()
      local cmd = daemon.start_command({
        project = "MyApp.fsproj",
        port = 9999,
      })
      local has_port = false
      for i, v in ipairs(cmd) do
        if v == "--mcp-port" then
          assert.are.equal("9999", cmd[i + 1])
          has_port = true
        end
      end
      assert.is_true(has_port, "command must include --mcp-port")
    end)
  end)

  describe("mark_starting", function()
    it("transitions idle → starting with project and port", function()
      local state = daemon.new()
      state = daemon.mark_starting(state, "MyApp.fsproj", 37749)
      assert.are.equal("starting", state.status)
      assert.are.equal("MyApp.fsproj", state.project)
      assert.are.equal(37749, state.port)
    end)
  end)

  describe("mark_running", function()
    it("transitions starting → running with job_id", function()
      local state = daemon.new()
      state = daemon.mark_starting(state, "MyApp.fsproj", 37749)
      state = daemon.mark_running(state, 12345)
      assert.are.equal("running", state.status)
      assert.are.equal(12345, state.job_id)
    end)
  end)

  describe("mark_stopped", function()
    it("transitions running → idle and clears job_id", function()
      local state = daemon.new()
      state = daemon.mark_starting(state, "MyApp.fsproj", 37749)
      state = daemon.mark_running(state, 12345)
      state = daemon.mark_stopped(state)
      assert.are.equal("idle", state.status)
      assert.is_nil(state.job_id)
    end)

    it("preserves project after stop", function()
      local state = daemon.new()
      state = daemon.mark_starting(state, "MyApp.fsproj", 37749)
      state = daemon.mark_running(state, 12345)
      state = daemon.mark_stopped(state)
      assert.are.equal("MyApp.fsproj", state.project)
    end)
  end)

  describe("mark_failed", function()
    it("transitions to failed with reason", function()
      local state = daemon.new()
      state = daemon.mark_starting(state, "MyApp.fsproj", 37749)
      state = daemon.mark_failed(state, "port in use")
      assert.are.equal("failed", state.status)
      assert.are.equal("port in use", state.error)
    end)
  end)

  describe("is_running", function()
    it("returns true when running", function()
      local state = daemon.new()
      state = daemon.mark_starting(state, "MyApp.fsproj", 37749)
      state = daemon.mark_running(state, 12345)
      assert.is_true(daemon.is_running(state))
    end)

    it("returns false when idle", function()
      assert.is_false(daemon.is_running(daemon.new()))
    end)

    it("returns false when failed", function()
      local state = daemon.new()
      state = daemon.mark_starting(state, "MyApp.fsproj", 37749)
      state = daemon.mark_failed(state, "oops")
      assert.is_false(daemon.is_running(state))
    end)
  end)

  describe("format_statusline", function()
    it("shows idle when no daemon", function()
      local text = daemon.format_statusline(daemon.new())
      assert.is_string(text)
      assert.truthy(text:find("idle") or text:find("💤"))
    end)

    it("shows running with project", function()
      local state = daemon.new()
      state = daemon.mark_starting(state, "MyApp.fsproj", 37749)
      state = daemon.mark_running(state, 42)
      local text = daemon.format_statusline(state)
      assert.truthy(text:find("MyApp"))
    end)
  end)
end)
