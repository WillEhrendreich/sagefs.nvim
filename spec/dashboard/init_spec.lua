-- spec/dashboard/init_spec.lua — Dashboard init module tests
-- Tests the pure logic parts (autocmd-to-event conversion, config defaults)
-- Full window tests require Neovim, so they go in e2e/

describe("Dashboard init", function()
  local dashboard

  before_each(function()
    -- Pre-load pure dependencies
    package.loaded["sagefs.dashboard.section"] = require("sagefs.dashboard.section")
    package.loaded["sagefs.dashboard.state"] = require("sagefs.dashboard.state")
    package.loaded["sagefs.dashboard.compositor"] = require("sagefs.dashboard.compositor")

    -- Load all section modules
    for _, name in ipairs({
      "health", "tests", "diagnostics", "failures", "session",
      "hot_reload", "output", "bindings", "coverage", "filmstrip", "alarms",
    }) do
      package.loaded["sagefs.dashboard.sections." .. name] =
        require("sagefs.dashboard.sections." .. name)
    end

    dashboard = require("sagefs.dashboard")
  end)

  after_each(function()
    -- Clear all dashboard modules from cache
    for k, _ in pairs(package.loaded) do
      if k:find("^sagefs%.dashboard") then
        package.loaded[k] = nil
      end
    end
  end)

  -- ─── Autocmd conversion ───────────────────────────────────────────────

  describe("_autocmd_to_event", function()
    it("converts SageFsConnected to connected", function()
      assert.equals("connected", dashboard._autocmd_to_event("SageFsConnected"))
    end)

    it("converts SageFsTestSummary to test_summary", function()
      assert.equals("test_summary", dashboard._autocmd_to_event("SageFsTestSummary"))
    end)

    it("converts SageFsHotreloadSnapshot to hotreload_snapshot", function()
      assert.equals("hotreload_snapshot", dashboard._autocmd_to_event("SageFsHotreloadSnapshot"))
    end)

    it("converts SageFsEvalResult to eval_result", function()
      assert.equals("eval_result", dashboard._autocmd_to_event("SageFsEvalResult"))
    end)

    it("converts SageFsSystemAlarm to system_alarm", function()
      assert.equals("system_alarm", dashboard._autocmd_to_event("SageFsSystemAlarm"))
    end)
  end)

  -- ─── Config ────────────────────────────────────────────────────────────

  describe("config defaults", function()
    it("has sensible default position", function()
      assert.equals("botright", dashboard.config.position)
    end)

    it("has default height", function()
      assert.equals(20, dashboard.config.height)
    end)

    it("has default sections", function()
      assert.is_true(#dashboard.config.default_sections >= 3)
    end)
  end)

  -- ─── State management ──────────────────────────────────────────────────

  describe("on_event without open dashboard", function()
    it("does not error on event when state is nil", function()
      dashboard._state = nil
      -- Should be a no-op, no error
      dashboard.on_event("connected", { version = "1.0" })
    end)

    it("updates state when state exists", function()
      local state = require("sagefs.dashboard.state")
      dashboard._state = state.new()
      dashboard.on_event("connected", { version = "2.0", sessionCount = 5 })
      assert.is_true(dashboard._state.daemon.connected)
      assert.equals("2.0", dashboard._state.daemon.version)
      assert.equals(5, dashboard._state.daemon.session_count)
    end)
  end)

  -- ─── Section registration ──────────────────────────────────────────────

  describe("section registration", function()
    it("registers all 11 sections", function()
      local sec = require("sagefs.dashboard.section")
      local all = sec.all()
      assert.is_true(#all >= 11, "expected 11+ sections, got " .. #all)
    end)

    it("includes health, tests, session sections", function()
      local sec = require("sagefs.dashboard.section")
      assert.is_not_nil(sec.get("health"))
      assert.is_not_nil(sec.get("tests"))
      assert.is_not_nil(sec.get("session"))
    end)
  end)

  -- ─── End-to-end pure render ────────────────────────────────────────────

  describe("pure render pipeline", function()
    it("composes visible sections into lines", function()
      local state_m = require("sagefs.dashboard.state")
      local comp = require("sagefs.dashboard.compositor")
      local sec = require("sagefs.dashboard.section")

      local s = state_m.new()
      s = state_m.update(s, "connected", {
        version = "0.6.163", sessionCount = 1,
      })

      -- Simulate what render() does
      local outputs = {}
      local sections = sec.ordered(s.visible_sections)
      for _, section in ipairs(sections) do
        local ok, output = pcall(section.render, s)
        if ok and output then
          table.insert(outputs, output)
        end
      end

      local composed = comp.compose(outputs, { separator = "─" })
      assert.is_true(#composed.lines > 5, "expected >5 lines, got " .. #composed.lines)
      assert.is_true(#composed.section_ranges >= 3, "expected >=3 sections")

      -- Verify section headers appear
      local joined = table.concat(composed.lines, "\n")
      assert.truthy(joined:find("Health"))
      assert.truthy(joined:find("Tests"))
      assert.truthy(joined:find("Sessions"))
    end)
  end)
end)
