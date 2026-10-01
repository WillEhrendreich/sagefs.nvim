require("spec.helper")

-- The plugin and the daemon are versioned in lockstep (the plugin's version
-- is the SageFs release it was tested against), but the thing that decides
-- whether they can talk is the daemon's wire contract: the integer
-- `apiVersion` on /health and /version. Compatibility is judged on that
-- alone. A version-number difference is information, never a warning.

describe("sagefs.compat", function()
  local compat

  before_each(function()
    package.loaded["sagefs.compat"] = nil
    compat = require("sagefs.compat")
  end)

  describe("the declared api range", function()
    it("is a closed table with a numeric min and max and a reason for each", function()
      local r = compat.api_range
      assert.is_number(r.min)
      assert.is_number(r.max)
      assert.is_true(r.min <= r.max)
      assert.is_string(r.min_reason)
      assert.is_string(r.max_reason)
    end)

    it("covers api 3, the first one with the run-app and stop-app routes", function()
      assert.equals(3, compat.api_range.min)
      assert.is_true(compat.api_range.max >= 3)
    end)
  end)

  describe("check", function()
    it("reports compatible inside the range, naming both sides", function()
      local r = compat.check(3)
      assert.equals("compatible", r.status)
      assert.equals("plugin understands api 3, daemon speaks api 3: compatible", r.message)
      assert.is_false(r.warn)
    end)

    it("names a daemon older than the range and says to update the daemon", function()
      local r = compat.check(2)
      assert.equals("daemon_too_old", r.status)
      assert.is_true(r.warn)
      assert.is_truthy(r.message:find("daemon speaks api 2", 1, true))
      assert.is_truthy(r.message:find("api 3", 1, true))
      assert.is_truthy(r.advice:find("update the daemon", 1, true))
      assert.is_truthy(r.advice:find("dotnet tool update --global sagefs", 1, true))
    end)

    it("names a daemon newer than the range and says to update the plugin", function()
      local r = compat.check(compat.api_range.max + 1)
      assert.equals("plugin_too_old", r.status)
      assert.is_true(r.warn)
      assert.is_truthy(r.message:find("daemon speaks api " .. (compat.api_range.max + 1), 1, true))
      assert.is_truthy(r.advice:find("update the plugin", 1, true))
    end)

    it("is unknown, and never a warning, when no apiVersion has been seen", function()
      for _, v in ipairs({ "nope", false }) do
        local r = compat.check(v)
        assert.equals("unknown", r.status)
        assert.is_false(r.warn)
      end
      assert.equals("unknown", compat.check(nil).status)
    end)
  end)

  describe("startup_warning", function()
    it("is nil when compatible", function()
      assert.is_nil(compat.startup_warning(3))
    end)

    it("is nil when the api version is unknown", function()
      assert.is_nil(compat.startup_warning(nil))
    end)

    it("is a message with the remedy for a real incompatibility", function()
      local w = compat.startup_warning(99)
      assert.is_string(w)
      assert.is_truthy(w:find("api 99", 1, true))
      assert.is_truthy(w:find("update the plugin", 1, true))
    end)
  end)

  describe("version_relation", function()
    it("is same for equal versions, ignoring a build suffix or a fourth part", function()
      assert.equals("same", compat.version_relation("0.6.875", "0.6.875"))
      assert.equals("same", compat.version_relation("0.6.875", "0.6.875.0"))
      assert.equals("same", compat.version_relation("0.6.875", "0.6.875+d7e1107"))
    end)

    it("is plugin_older when the daemon has a higher number, patch included", function()
      assert.equals("plugin_older", compat.version_relation("0.6.875", "0.6.880"))
      assert.equals("plugin_older", compat.version_relation("0.6.875", "0.7.0"))
    end)

    it("is plugin_newer when the plugin has a higher number", function()
      assert.equals("plugin_newer", compat.version_relation("0.6.880", "0.6.875"))
    end)

    it("compares numbers, not strings", function()
      assert.equals("plugin_older", compat.version_relation("0.6.99", "0.6.100"))
    end)

    it("is unknown for unparseable input", function()
      assert.equals("unknown", compat.version_relation(nil, "0.6.0"))
      assert.equals("unknown", compat.version_relation("0.6.0", "garbage"))
    end)
  end)
end)
