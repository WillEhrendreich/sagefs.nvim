-- spec/type_explorer_cache_spec.lua — Tests for type explorer cache module

local cache

setup(function()
  cache = require("sagefs.type_explorer_cache")
end)

before_each(function()
  cache.clear()
end)

describe("type_explorer_cache", function()

  describe("assemblies cache", function()
    it("returns nil on cache miss", function()
      assert.is_nil(cache.get_assemblies())
    end)

    it("stores and retrieves assemblies", function()
      local asms = { { name = "mscorlib" }, { name = "System" } }
      cache.set_assemblies(asms)
      assert.same(asms, cache.get_assemblies())
    end)

    it("returns nil after clear", function()
      cache.set_assemblies({ { name = "mscorlib" } })
      cache.clear()
      assert.is_nil(cache.get_assemblies())
    end)
  end)

  describe("namespaces cache", function()
    it("returns nil for unknown assembly", function()
      assert.is_nil(cache.get_namespaces("mscorlib"))
    end)

    it("stores and retrieves per assembly", function()
      local ns = { "System", "System.IO", "System.Text" }
      cache.set_namespaces("mscorlib", ns)
      assert.same(ns, cache.get_namespaces("mscorlib"))
    end)

    it("isolates by assembly", function()
      cache.set_namespaces("mscorlib", { "System" })
      cache.set_namespaces("System.Runtime", { "System.Runtime" })
      assert.same({ "System" }, cache.get_namespaces("mscorlib"))
      assert.same({ "System.Runtime" }, cache.get_namespaces("System.Runtime"))
    end)

    it("clears with assemblies", function()
      cache.set_namespaces("mscorlib", { "System" })
      cache.clear()
      assert.is_nil(cache.get_namespaces("mscorlib"))
    end)
  end)

  describe("types cache", function()
    it("returns nil for unknown namespace", function()
      assert.is_nil(cache.get_types("System.IO"))
    end)

    it("stores and retrieves per namespace", function()
      local types = { { name = "File", kind = "class" }, { name = "Path", kind = "class" } }
      cache.set_types("System.IO", types)
      assert.same(types, cache.get_types("System.IO"))
    end)

    it("clears with everything else", function()
      cache.set_types("System.IO", { { name = "File" } })
      cache.clear()
      assert.is_nil(cache.get_types("System.IO"))
    end)
  end)

  describe("members cache", function()
    it("returns nil for unknown type", function()
      assert.is_nil(cache.get_members("System.String"))
    end)

    it("stores and retrieves per type", function()
      local members = { { name = "Length", kind = "property" } }
      cache.set_members("System.String", members)
      assert.same(members, cache.get_members("System.String"))
    end)

    it("clears with everything else", function()
      cache.set_members("System.String", { { name = "Length" } })
      cache.clear()
      assert.is_nil(cache.get_members("System.String"))
    end)
  end)

  describe("flat types cache", function()
    it("returns nil when not cached", function()
      assert.is_nil(cache.get_flat_types())
    end)

    it("stores and retrieves all flat types", function()
      local flat = {
        { label = "◆ System.String", fullName = "System.String" },
        { label = "◆ System.Int32", fullName = "System.Int32" },
      }
      cache.set_flat_types(flat)
      assert.same(flat, cache.get_flat_types())
    end)

    it("clears with everything", function()
      cache.set_flat_types({ { label = "test" } })
      cache.clear()
      assert.is_nil(cache.get_flat_types())
    end)
  end)

  describe("has_data", function()
    it("returns false when empty", function()
      assert.is_false(cache.has_data())
    end)

    it("returns true when assemblies cached", function()
      cache.set_assemblies({ { name = "mscorlib" } })
      assert.is_true(cache.has_data())
    end)

    it("returns false after clear", function()
      cache.set_assemblies({ { name = "mscorlib" } })
      cache.clear()
      assert.is_false(cache.has_data())
    end)
  end)

  describe("stats", function()
    it("reports zero counts when empty", function()
      local s = cache.stats()
      assert.equal(0, s.assemblies)
      assert.equal(0, s.namespaces)
      assert.equal(0, s.types)
      assert.equal(0, s.members)
      assert.is_false(s.has_flat)
    end)

    it("reports correct counts", function()
      cache.set_assemblies({ { name = "a" }, { name = "b" } })
      cache.set_namespaces("a", { "X", "Y" })
      cache.set_types("X", { { name = "T1" } })
      cache.set_members("T1", { { name = "M1" } })
      cache.set_flat_types({ { label = "flat" } })
      local s = cache.stats()
      assert.equal(2, s.assemblies)
      assert.equal(1, s.namespaces)
      assert.equal(1, s.types)
      assert.equal(1, s.members)
      assert.is_true(s.has_flat)
    end)
  end)

end)
