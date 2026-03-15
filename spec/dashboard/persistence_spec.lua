-- spec/dashboard/persistence_spec.lua — Section persistence tests
-- Tests that section visibility is serialized/deserialized to/from vim.g

describe("dashboard section persistence", function()
  local state_mod

  before_each(function()
    -- Reset vim.g for clean test
    vim.g = {}
    state_mod = require("sagefs.dashboard.state")
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.state"] = nil
  end)

  -- ─── Serialization ──────────────────────────────────────────────────────

  describe("persist_visible_sections", function()
    it("writes visible_sections to vim.g.sagefs_dashboard_sections", function()
      local s = state_mod.new()
      s.visible_sections = { "health", "tests", "failures" }
      state_mod.persist_visible_sections(s)
      assert.is_table(vim.g.sagefs_dashboard_sections)
      assert.same({ "health", "tests", "failures" }, vim.g.sagefs_dashboard_sections)
    end)

    it("persists empty list when all sections toggled off", function()
      local s = state_mod.new()
      s.visible_sections = {}
      state_mod.persist_visible_sections(s)
      assert.same({}, vim.g.sagefs_dashboard_sections)
    end)
  end)

  -- ─── Deserialization ────────────────────────────────────────────────────

  describe("restore_visible_sections", function()
    it("restores from vim.g.sagefs_dashboard_sections", function()
      vim.g.sagefs_dashboard_sections = { "diagnostics", "coverage" }
      local s = state_mod.new()
      state_mod.restore_visible_sections(s)
      assert.same({ "diagnostics", "coverage" }, s.visible_sections)
    end)

    it("keeps defaults when vim.g has no persisted state", function()
      vim.g.sagefs_dashboard_sections = nil
      local s = state_mod.new()
      local defaults = vim.deepcopy(s.visible_sections)
      state_mod.restore_visible_sections(s)
      assert.same(defaults, s.visible_sections)
    end)

    it("keeps defaults when vim.g has empty table", function()
      vim.g.sagefs_dashboard_sections = {}
      local s = state_mod.new()
      local defaults = vim.deepcopy(s.visible_sections)
      state_mod.restore_visible_sections(s)
      assert.same(defaults, s.visible_sections)
    end)
  end)

  -- ─── Toggle + persist round-trip ───────────────────────────────────────

  describe("toggle + persist round-trip", function()
    it("remembers toggled-off sections across state recreation", function()
      -- Initial state, toggle off "health"
      local s = state_mod.new()
      state_mod.toggle_section(s, "health")
      state_mod.persist_visible_sections(s)

      -- Create new state (simulates close/reopen)
      local s2 = state_mod.new()
      state_mod.restore_visible_sections(s2)

      assert.is_false(state_mod.is_visible(s2, "health"))
    end)

    it("remembers toggled-on sections across state recreation", function()
      local s = state_mod.new()
      state_mod.toggle_section(s, "filmstrip") -- add filmstrip
      state_mod.persist_visible_sections(s)

      local s2 = state_mod.new()
      state_mod.restore_visible_sections(s2)

      assert.is_true(state_mod.is_visible(s2, "filmstrip"))
    end)
  end)
end)
