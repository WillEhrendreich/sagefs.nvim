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
      for _, v in ipairs({ false }) do
        local r = compat.check(v)
        assert.equals("unknown", r.status)
        assert.is_false(r.warn)
      end
      assert.equals("unknown", compat.check(nil).status)
    end)
  end)

  describe("check on an apiVersion that is not a usable whole number", function()
    local function assert_unknown_naming(v, raw)
      local r = compat.check(v)
      assert.equals("unknown", r.status)
      assert.is_false(r.warn)
      assert.is_truthy(r.message:find(raw, 1, true), "message should name the raw value " .. raw .. ": " .. r.message)
      assert.is_nil(r.message:find("daemon speaks api", 1, true), r.message)
      assert.is_nil(r.message:find("not known yet", 1, true), r.message)
      assert.is_nil(compat.startup_warning(v))
    end

    it("treats a fractional apiVersion as unknown, never as the integer below it", function()
      assert_unknown_naming(3.5, "3.5")
    end)

    it("treats a huge apiVersion as unknown, never as a wrapped negative", function()
      local r = compat.check(1e300)
      assert.is_nil(r.message:find("9223372036854775808", 1, true), r.message)
      assert_unknown_naming(1e300, "1e+300")
      assert_unknown_naming(-1e300, "-1e+300")
    end)

    it("treats infinity and NaN as unknown", function()
      assert_unknown_naming(math.huge, "inf")
      assert.equals("unknown", compat.check(0 / 0).status)
      assert.is_false(compat.check(0 / 0).warn)
    end)

    it("still judges a whole number held in a float as that integer", function()
      assert.equals("compatible", compat.check(3.0).status)
    end)
  end)

  describe("check on an apiVersion sent as a string", function()
    it("accepts a numeric string as that number", function()
      local r = compat.check("3")
      assert.equals("compatible", r.status)
      assert.equals("plugin understands api 3, daemon speaks api 3: compatible", r.message)
      assert.equals("plugin_too_old", compat.check("99").status)
      assert.is_true(compat.check("99").warn)
      assert.equals("daemon_too_old", compat.check("2").status)
      assert.equals("compatible", compat.check(" 3 ").status)
    end)

    it("warns at startup for a numeric string outside the range", function()
      assert.is_truthy(compat.startup_warning("99"):find("api 99", 1, true))
    end)

    it("says the value is not a number, and quotes it, when it is not numeric", function()
      for _, raw in ipairs({ "abc", "", "0x10", "1e2", "3-" }) do
        local r = compat.check(raw)
        assert.equals("unknown", r.status)
        assert.is_false(r.warn)
        assert.is_truthy(r.message:find("api version is not a number", 1, true), r.message)
        assert.is_truthy(r.message:find('"' .. raw .. '"', 1, true), r.message)
        assert.is_nil(r.message:find("not known yet", 1, true), r.message)
      end
    end)

    it("treats a string holding a fraction like a fractional number", function()
      local r = compat.check("3.5")
      assert.equals("unknown", r.status)
      assert.is_nil(r.message:find("daemon speaks api", 1, true), r.message)
    end)

    it("says it is not a number for a boolean or a table, not that it is not known yet", function()
      for _, v in ipairs({ true, {} }) do
        local r = compat.check(v)
        assert.equals("unknown", r.status)
        assert.is_false(r.warn)
        assert.is_truthy(r.message:find("api version is not a number", 1, true), r.message)
        assert.is_nil(r.message:find("not known yet", 1, true), r.message)
      end
    end)

    it("keeps the not-known-yet wording for nothing at all", function()
      assert.is_truthy(compat.check(nil).message:find("not known yet", 1, true))
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

    it("carries no [SageFs] prefix, because notify adds one", function()
      assert.is_nil(compat.startup_warning(99):find("[SageFs]", 1, true))
    end)

    it("reads as one plain instruction for each side", function()
      assert.is_truthy(compat.startup_warning(2):find("update the daemon (dotnet tool update --global sagefs)", 1, true))
      assert.is_truthy(compat.startup_warning(99):find("update the plugin (", 1, true))
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

-- The list says what this plugin reads off the wire beyond what the daemon has
-- always sent. A reader trusts `used` and `daemon` to be current, and an entry
-- that says "the daemon drops it" while the daemon sends it is a false note that
-- sent someone looking for a bug that was fixed (declarations was one).
describe("sagefs.compat.fields", function()
  local compat = require("sagefs.compat")

  it("every entry says where the daemon stands and why, and names are unique", function()
    local seen = {}
    for _, f in ipairs(compat.fields) do
      assert.is_string(f.name)
      assert.is_string(f.daemon)
      assert.is_true(#f.note > 0, f.name)
      assert.is_nil(seen[f.name], "duplicate " .. f.name)
      seen[f.name] = true
      assert.is_true(f.used == false or type(f.used) == "string", f.name .. ": used is false or the surface that reads it")
    end
  end)

  it("lists the fields this release reads: declarations and the session's workflowLabel", function()
    local used = {}
    for _, name in ipairs(compat.fields_in_use()) do used[name] = true end
    assert.is_true(used["lastReload.declarations"], "a PatchPending names what it applied")
    assert.is_true(used["sessions[].workflowLabel"], "the statusline's workflow label")
  end)

  it("does not say the daemon drops declarations, which 0.6.892 writes", function()
    for _, f in ipairs(compat.fields) do
      if f.name == "lastReload.declarations" then
        assert.is_nil(f.daemon:find("drops", 1, true))
      end
    end
  end)
end)
