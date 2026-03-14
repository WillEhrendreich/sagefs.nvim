-- spec/dashboard/section_spec.lua — Section protocol validation tests

describe("Section protocol", function()
  local section

  before_each(function()
    section = require("sagefs.dashboard.section")
    section.clear()
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.section"] = nil
  end)

  -- ─── Validation ──────────────────────────────────────────────────────────

  describe("validate", function()
    it("accepts a valid section", function()
      local valid = {
        id = "test_section",
        label = "Test",
        events = { "SageFsTestState" },
        render = function(_) return { lines = {}, highlights = {}, keymaps = {} } end,
      }
      assert.is_true(section.validate(valid))
    end)

    it("rejects nil", function()
      assert.is_false(section.validate(nil))
    end)

    it("rejects non-table", function()
      assert.is_false(section.validate("not a table"))
      assert.is_false(section.validate(42))
    end)

    it("rejects section missing id", function()
      local invalid = { label = "X", events = {}, render = function() return { lines = {} } end }
      assert.is_false(section.validate(invalid))
    end)

    it("rejects section with empty id", function()
      local invalid = { id = "", label = "X", events = {}, render = function() return { lines = {} } end }
      assert.is_false(section.validate(invalid))
    end)

    it("rejects section missing label", function()
      local invalid = { id = "x", events = {}, render = function() return { lines = {} } end }
      assert.is_false(section.validate(invalid))
    end)

    it("rejects section missing events", function()
      local invalid = { id = "x", label = "X", render = function() return { lines = {} } end }
      assert.is_false(section.validate(invalid))
    end)

    it("rejects section with non-function render", function()
      local invalid = { id = "x", label = "X", events = {}, render = "not a function" }
      assert.is_false(section.validate(invalid))
    end)

    it("rejects section missing render", function()
      local invalid = { id = "x", label = "X", events = {} }
      assert.is_false(section.validate(invalid))
    end)
  end)

  -- ─── Registry ────────────────────────────────────────────────────────────

  describe("register", function()
    local function make_section(id)
      return {
        id = id,
        label = id:upper(),
        events = { "SageFs" .. id },
        render = function(_) return { lines = { id }, highlights = {}, keymaps = {} } end,
      }
    end

    it("registers a valid section and retrieves it", function()
      local s = make_section("health")
      assert.is_true(section.register(s))
      assert.equals("health", section.get("health").id)
    end)

    it("rejects invalid section", function()
      assert.is_false(section.register({ bad = true }))
      assert.is_nil(section.get("bad"))
    end)

    it("returns nil for unregistered id", function()
      assert.is_nil(section.get("nonexistent"))
    end)

    it("lists all registered sections sorted by id", function()
      section.register(make_section("tests"))
      section.register(make_section("health"))
      section.register(make_section("alarms"))
      local all = section.all()
      assert.equals(3, #all)
      assert.equals("alarms", all[1].id)
      assert.equals("health", all[2].id)
      assert.equals("tests", all[3].id)
    end)

    it("returns ordered sections matching id list", function()
      section.register(make_section("health"))
      section.register(make_section("tests"))
      section.register(make_section("diags"))
      local ordered = section.ordered({ "tests", "health", "nonexistent" })
      assert.equals(2, #ordered)
      assert.equals("tests", ordered[1].id)
      assert.equals("health", ordered[2].id)
    end)

    it("clear removes all sections", function()
      section.register(make_section("health"))
      assert.equals(1, #section.all())
      section.clear()
      assert.equals(0, #section.all())
    end)
  end)

  -- ─── Empty Output ────────────────────────────────────────────────────────

  describe("empty_output", function()
    it("returns structured empty output", function()
      local out = section.empty_output("test")
      assert.same({}, out.lines)
      assert.same({}, out.highlights)
      assert.same({}, out.keymaps)
      assert.equals("test", out.section_id)
    end)
  end)
end)
