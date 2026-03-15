-- spec/dashboard/auto_open_spec.lua — Auto-open policy tests
-- Tests the auto-open flag logic in dashboard state

describe("dashboard auto-open policy", function()
  local state_mod

  before_each(function()
    state_mod = require("sagefs.dashboard.state")
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.state"] = nil
  end)

  -- ─── Auto-open flag defaults ───────────────────────────────────────────

  it("new state has auto_open_enabled = true by default", function()
    local s = state_mod.new()
    assert.is_true(s.auto_open_enabled)
  end)

  -- ─── should_auto_open logic ────────────────────────────────────────────

  describe("should_auto_open", function()
    it("returns true when auto_open_enabled and dashboard is closed", function()
      local s = state_mod.new()
      s.auto_open_enabled = true
      assert.is_true(state_mod.should_auto_open(s, false))
    end)

    it("returns false when auto_open_enabled but dashboard is already open", function()
      local s = state_mod.new()
      s.auto_open_enabled = true
      assert.is_false(state_mod.should_auto_open(s, true))
    end)

    it("returns false when auto_open_enabled is false", function()
      local s = state_mod.new()
      s.auto_open_enabled = false
      assert.is_false(state_mod.should_auto_open(s, false))
    end)

    it("returns false when auto_open_enabled is false and dashboard is open", function()
      local s = state_mod.new()
      s.auto_open_enabled = false
      assert.is_false(state_mod.should_auto_open(s, true))
    end)
  end)

  -- ─── Explicit close disables auto-open ─────────────────────────────────

  describe("mark_explicit_close", function()
    it("sets auto_open_enabled to false", function()
      local s = state_mod.new()
      assert.is_true(s.auto_open_enabled)
      state_mod.mark_explicit_close(s)
      assert.is_false(s.auto_open_enabled)
    end)
  end)

  -- ─── Explicit open re-enables auto-open ────────────────────────────────

  describe("mark_explicit_open", function()
    it("sets auto_open_enabled to true", function()
      local s = state_mod.new()
      state_mod.mark_explicit_close(s)
      assert.is_false(s.auto_open_enabled)
      state_mod.mark_explicit_open(s)
      assert.is_true(s.auto_open_enabled)
    end)
  end)

  -- ─── Full lifecycle scenario ───────────────────────────────────────────

  describe("lifecycle", function()
    it("close → reopen → auto-open works again", function()
      local s = state_mod.new()

      -- Initially auto-open is enabled
      assert.is_true(state_mod.should_auto_open(s, false))

      -- User explicitly closes → auto-open disabled
      state_mod.mark_explicit_close(s)
      assert.is_false(state_mod.should_auto_open(s, false))

      -- User explicitly re-opens → auto-open re-enabled
      state_mod.mark_explicit_open(s)
      assert.is_true(state_mod.should_auto_open(s, false))
    end)

    it("test_failure event triggers should_auto_open check", function()
      local s = state_mod.new()
      -- Simulate receiving a test failure event (state update)
      s = state_mod.update(s, "test_summary", {
        total = 10, passed = 9, failed = 1, stale = 0, running = 0,
      })
      -- After failure, auto-open should still be true (event doesn't change it)
      assert.is_true(s.auto_open_enabled)
      assert.is_true(state_mod.should_auto_open(s, false))
    end)
  end)
end)
