-- spec/type_explorer_cache_spec.lua — Tests for type explorer cache module

local cache

setup(function()
  cache = require("sagefs.type_explorer_cache")
end)

before_each(function()
  cache.clear()
end)

describe("type_explorer_cache", function()

  describe("get/set", function()
    it("returns nil on cache miss", function()
      assert.is_nil(cache.get("System"))
    end)

    it("stores and retrieves completions by name", function()
      local items = { { label = "String", kind = "Class" }, { label = "Int32", kind = "Struct" } }
      cache.set("System", items)
      assert.same(items, cache.get("System"))
    end)

    it("isolates by qualified name", function()
      cache.set("System", { { label = "String" } })
      cache.set("System.IO", { { label = "File" } })
      assert.same({ { label = "String" } }, cache.get("System"))
      assert.same({ { label = "File" } }, cache.get("System.IO"))
    end)

    it("returns nil after clear", function()
      cache.set("System", { { label = "String" } })
      cache.clear()
      assert.is_nil(cache.get("System"))
    end)
  end)

  describe("has_data", function()
    it("returns false when empty", function()
      assert.is_false(cache.has_data())
    end)

    it("returns true when data cached", function()
      cache.set("System", { { label = "String" } })
      assert.is_true(cache.has_data())
    end)

    it("returns false after clear", function()
      cache.set("System", { { label = "String" } })
      cache.clear()
      assert.is_false(cache.has_data())
    end)
  end)

  describe("stats", function()
    it("reports zero when empty", function()
      local s = cache.stats()
      assert.equal(0, s.cached_names)
    end)

    it("reports correct count", function()
      cache.set("System", { { label = "String" } })
      cache.set("System.IO", { { label = "File" } })
      local s = cache.stats()
      assert.equal(2, s.cached_names)
    end)
  end)

end)
