require("spec.helper")
local te = require("sagefs.type_explorer")

describe("type_explorer", function()
  -- ─── format_assemblies ───────────────────────────────────────────────────
  describe("format_assemblies", function()
    it("returns empty table for empty input", function()
      assert.are.same({}, te.format_assemblies({}))
    end)

    it("formats assemblies with name and path", function()
      local assemblies = {
        { name = "System.Runtime", path = "/usr/lib/System.Runtime.dll" },
        { name = "FSharp.Core", path = "/usr/lib/FSharp.Core.dll" },
      }
      local items = te.format_assemblies(assemblies)
      assert.are.equal(2, #items)
      assert.are.equal("System.Runtime", items[1].label)
      assert.are.equal("System.Runtime", items[1].name)
      assert.are.equal("/usr/lib/System.Runtime.dll", items[1].path)
    end)

    it("handles missing path", function()
      local items = te.format_assemblies({ { name = "MyLib" } })
      assert.are.equal("MyLib", items[1].label)
      assert.are.equal("", items[1].path)
    end)
  end)

  -- ─── format_namespaces ───────────────────────────────────────────────────
  describe("format_namespaces", function()
    it("returns empty table for empty input", function()
      assert.are.same({}, te.format_namespaces({}))
    end)

    it("formats namespace strings", function()
      local items = te.format_namespaces({ "System", "System.IO", "FSharp.Core" })
      assert.are.equal(3, #items)
      assert.are.equal("System", items[1].label)
      assert.are.equal("System", items[1].namespace)
      assert.are.equal("System.IO", items[2].namespace)
    end)
  end)

  -- ─── format_types ────────────────────────────────────────────────────────
  describe("format_types", function()
    it("returns empty table for empty input", function()
      assert.are.same({}, te.format_types({}))
    end)

    it("formats types with kind icons", function()
      local types = {
        { name = "String", fullName = "System.String", kind = "class" },
        { name = "Point", fullName = "My.Point", kind = "struct" },
        { name = "IDisposable", fullName = "System.IDisposable", kind = "interface" },
        { name = "Color", fullName = "My.Color", kind = "enum" },
        { name = "Option", fullName = "FSharp.Core.Option", kind = "union" },
        { name = "List", fullName = "FSharp.Collections.List", kind = "module" },
      }
      local items = te.format_types(types)
      assert.are.equal(6, #items)
      assert.truthy(items[1].label:match("◆"), "class icon")
      assert.truthy(items[2].label:match("◇"), "struct icon")
      assert.truthy(items[3].label:match("◈"), "interface icon")
      assert.truthy(items[4].label:match("▣"), "enum icon")
      assert.truthy(items[5].label:match("▤"), "union icon")
      assert.truthy(items[6].label:match("▥"), "module icon")
    end)

    it("preserves fullName on items", function()
      local items = te.format_types({ { name = "X", fullName = "My.X", kind = "class" } })
      assert.are.equal("My.X", items[1].fullName)
    end)

    it("uses ● for unknown kind", function()
      local items = te.format_types({ { name = "X", fullName = "X", kind = "exotic" } })
      assert.truthy(items[1].label:match("●"))
    end)
  end)

  -- ─── format_members ──────────────────────────────────────────────────────
  describe("format_members", function()
    it("returns header line with type name", function()
      local lines = te.format_members("System.String", {})
      assert.truthy(lines[1]:match("System%.String"))
    end)

    it("groups members by kind", function()
      local members = {
        { name = "new", kind = "constructor", parameters = "string", returnType = "String" },
        { name = "Length", kind = "property", returnType = "int" },
        { name = "Substring", kind = "method", parameters = "int, int", returnType = "string" },
        { name = "Empty", kind = "field", returnType = "string" },
      }
      local lines = te.format_members("System.String", members)
      local text = table.concat(lines, "\n")
      assert.truthy(text:match("Constructors:"))
      assert.truthy(text:match("Properties:"))
      assert.truthy(text:match("Methods:"))
      assert.truthy(text:match("Fields:"))
    end)

    it("formats method signatures with parameters and return type", function()
      local members = {
        { name = "Substring", kind = "method", parameters = "int, int", returnType = "string" },
      }
      local lines = te.format_members("T", members)
      local text = table.concat(lines, "\n")
      assert.truthy(text:match("Substring%(int, int%) : string"))
    end)

    it("handles members without parameters", function()
      local members = {
        { name = "Length", kind = "property", returnType = "int" },
      }
      local lines = te.format_members("T", members)
      local text = table.concat(lines, "\n")
      assert.truthy(text:match("Length : int"))
      assert.is_nil(text:match("%("))
    end)

    it("handles members without returnType", function()
      local members = {
        { name = "Dispose", kind = "method", parameters = "" },
      }
      local lines = te.format_members("T", members)
      local text = table.concat(lines, "\n")
      assert.truthy(text:match("Dispose"))
    end)

    it("omits empty sections", function()
      local members = {
        { name = "Foo", kind = "method", returnType = "int" },
      }
      local lines = te.format_members("T", members)
      local text = table.concat(lines, "\n")
      assert.is_nil(text:match("Constructors:"))
      assert.is_nil(text:match("Properties:"))
      assert.truthy(text:match("Methods:"))
    end)

    it("handles Events section", function()
      local members = {
        { name = "Changed", kind = "event", returnType = "EventHandler" },
      }
      local lines = te.format_members("T", members)
      local text = table.concat(lines, "\n")
      assert.truthy(text:match("Events:"))
      assert.truthy(text:match("Changed"))
    end)
  end)

  -- ─── format_flat_entry ───────────────────────────────────────────────────
  describe("format_flat_entry", function()
    it("formats a flat entry with icon and qualified name", function()
      local entry = te.format_flat_entry("System.Runtime", "System", {
        name = "String", fullName = "System.String", kind = "class",
      })
      assert.are.equal("System.String", entry.fullName)
      assert.are.equal("System.Runtime", entry.assembly)
      assert.truthy(entry.label:find("◆"), "should have class icon")
      assert.truthy(entry.label:find("System.String"), "should contain full name")
    end)

    it("uses fullName from type entry", function()
      local entry = te.format_flat_entry("FSharp.Core", "Microsoft.FSharp.Core", {
        name = "Option", fullName = "Microsoft.FSharp.Core.Option", kind = "union",
      })
      assert.are.equal("Microsoft.FSharp.Core.Option", entry.fullName)
      assert.truthy(entry.label:find("▤"), "should have union icon")
    end)

    it("falls back to name when fullName is missing", function()
      local entry = te.format_flat_entry("MyLib", "MyNs", {
        name = "MyType", kind = "struct",
      })
      assert.are.equal("MyType", entry.fullName)
    end)
  end)
end)
