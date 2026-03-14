-- spec/dashboard/state_spec.lua — Dashboard state tests

describe("Dashboard state", function()
  local state_mod

  before_each(function()
    state_mod = require("sagefs.dashboard.state")
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.state"] = nil
  end)

  -- ─── Initialization ────────────────────────────────────────────────────

  describe("new", function()
    it("creates initial state with defaults", function()
      local s = state_mod.new()
      assert.is_table(s)
      assert.is_false(s.daemon.connected)
      assert.equals(0, s.daemon.session_count)
      assert.is_nil(s.daemon.version)
      assert.is_false(s.testing.enabled)
      assert.equals(0, s.testing.summary.total)
      assert.is_false(s.hot_reload.enabled)
      assert.is_table(s.visible_sections)
      assert.is_true(#s.visible_sections > 0)
    end)
  end)

  -- ─── Section Visibility ────────────────────────────────────────────────

  describe("is_visible", function()
    it("returns true for default visible sections", function()
      local s = state_mod.new()
      assert.is_true(state_mod.is_visible(s, "health"))
      assert.is_true(state_mod.is_visible(s, "tests"))
    end)

    it("returns false for non-visible sections", function()
      local s = state_mod.new()
      assert.is_false(state_mod.is_visible(s, "filmstrip"))
      assert.is_false(state_mod.is_visible(s, "coverage"))
    end)
  end)

  describe("toggle_section", function()
    it("removes a visible section", function()
      local s = state_mod.new()
      assert.is_true(state_mod.is_visible(s, "health"))
      s = state_mod.toggle_section(s, "health")
      assert.is_false(state_mod.is_visible(s, "health"))
    end)

    it("adds an invisible section", function()
      local s = state_mod.new()
      assert.is_false(state_mod.is_visible(s, "filmstrip"))
      s = state_mod.toggle_section(s, "filmstrip")
      assert.is_true(state_mod.is_visible(s, "filmstrip"))
    end)

    it("toggles twice returns to original state", function()
      local s = state_mod.new()
      local was_visible = state_mod.is_visible(s, "health")
      s = state_mod.toggle_section(s, "health")
      s = state_mod.toggle_section(s, "health")
      assert.equals(was_visible, state_mod.is_visible(s, "health"))
    end)
  end)

  -- ─── Event Updates ─────────────────────────────────────────────────────

  describe("update", function()
    it("updates daemon health on connected event", function()
      local s = state_mod.new()
      s = state_mod.update(s, "connected", {
        version = "0.6.163",
        uptime = "2h 15m",
        memoryMb = 412,
        sessionCount = 3,
      })
      assert.is_true(s.daemon.connected)
      assert.equals("0.6.163", s.daemon.version)
      assert.equals("2h 15m", s.daemon.uptime)
      assert.equals(412, s.daemon.memory_mb)
      assert.equals(3, s.daemon.session_count)
    end)

    it("handles PascalCase payload for connected", function()
      local s = state_mod.new()
      s = state_mod.update(s, "connected", {
        Version = "0.7.0",
        Uptime = "1h",
        MemoryMb = 200,
        SessionCount = 1,
      })
      assert.equals("0.7.0", s.daemon.version)
      assert.equals(1, s.daemon.session_count)
    end)

    it("sets connected=false on disconnected", function()
      local s = state_mod.new()
      s = state_mod.update(s, "connected", { version = "1.0" })
      assert.is_true(s.daemon.connected)
      s = state_mod.update(s, "disconnected", {})
      assert.is_false(s.daemon.connected)
    end)

    it("updates test summary", function()
      local s = state_mod.new()
      s = state_mod.update(s, "test_summary", {
        total = 100, passed = 95, failed = 5, stale = 0, running = 0,
      })
      assert.equals(100, s.testing.summary.total)
      assert.equals(95, s.testing.summary.passed)
      assert.equals(5, s.testing.summary.failed)
    end)

    it("updates testing enabled state", function()
      local s = state_mod.new()
      s = state_mod.update(s, "test_state", { enabled = true })
      assert.is_true(s.testing.enabled)
      s = state_mod.update(s, "test_state", { enabled = false })
      assert.is_false(s.testing.enabled)
    end)

    it("updates eval result", function()
      local s = state_mod.new()
      s = state_mod.update(s, "eval_result", {
        output = "val it: int = 42",
        cellId = 7,
        durationMs = 15,
      })
      assert.equals("val it: int = 42", s.eval.output)
      assert.equals(7, s.eval.cell_id)
      assert.equals(15, s.eval.duration_ms)
    end)

    it("updates hot reload snapshot", function()
      local s = state_mod.new()
      s = state_mod.update(s, "hotreload_snapshot", {
        enabled = true,
        files = { "A.fs", "B.fs" },
        totalFiles = 10,
      })
      assert.is_true(s.hot_reload.enabled)
      assert.equals(2, #s.hot_reload.watched_files)
      assert.equals(10, s.hot_reload.total_files)
    end)

    it("appends system alarm", function()
      local s = state_mod.new()
      s = state_mod.update(s, "system_alarm", { type = "queue_depth", value = 300 })
      s = state_mod.update(s, "system_alarm", { type = "memory", value = 1024 })
      assert.equals(2, #s.alarms)
    end)

    it("updates coverage", function()
      local s = state_mod.new()
      s = state_mod.update(s, "coverage_updated", {
        total = 500, covered = 400, percent = 80,
      })
      assert.equals(500, s.coverage.total)
      assert.equals(80, s.coverage.percent)
    end)

    it("ignores unknown event types gracefully", function()
      local s = state_mod.new()
      local s2 = state_mod.update(s, "totally_unknown_event", { foo = 1 })
      assert.is_table(s2)
      assert.is_false(s2.daemon.connected)
    end)

    it("handles nil payload gracefully", function()
      local s = state_mod.new()
      -- Should not error on nil payload
      s = state_mod.update(s, "connected", nil)
      -- connected handler with nil payload just sets connected=true
      assert.is_true(s.daemon.connected)
    end)

    it("updates failure narratives", function()
      local s = state_mod.new()
      s = state_mod.update(s, "failure_narratives", {
        narratives = {
          { testName = "my test", summary = "failed because X" },
        },
      })
      assert.equals(1, #s.testing.failure_narratives)
    end)

    it("updates bindings snapshot", function()
      local s = state_mod.new()
      s = state_mod.update(s, "bindings_snapshot", {
        bindings = { { name = "x", value = "42", typeSig = "int" } },
      })
      assert.equals(1, #s.bindings)
    end)

    it("updates warmup context", function()
      local s = state_mod.new()
      s = state_mod.update(s, "warmup_context", {
        assemblies = 12, namespaces = 30, files = 5,
      })
      assert.is_table(s.warmup_context)
      assert.equals(12, s.warmup_context.assemblies)
    end)

    it("marks session faulted", function()
      local s = state_mod.new()
      s.sessions = { { id = "abc", status = "Ready" }, { id = "def", status = "Ready" } }
      s = state_mod.update(s, "session_faulted", { sessionId = "abc" })
      assert.equals("Faulted", s.sessions[1].status)
      assert.equals("Ready", s.sessions[2].status)
    end)
  end)

  -- ─── Handled Events ────────────────────────────────────────────────────

  describe("handled_events", function()
    it("returns a sorted list of event types", function()
      local events = state_mod.handled_events()
      assert.is_table(events)
      assert.is_true(#events > 5)
      -- Verify sorted
      for i = 2, #events do
        assert.is_true(events[i - 1] <= events[i],
          "expected sorted: " .. events[i - 1] .. " <= " .. events[i])
      end
    end)

    it("includes connected and test_summary", function()
      local events = state_mod.handled_events()
      local has_connected, has_test_summary = false, false
      for _, e in ipairs(events) do
        if e == "connected" then has_connected = true end
        if e == "test_summary" then has_test_summary = true end
      end
      assert.is_true(has_connected)
      assert.is_true(has_test_summary)
    end)
  end)
end)
