require("spec.helper")
local te = require("sagefs.type_explorer")

describe("type_explorer", function()
  -- ─── format_completions ───────────────────────────────────────────────
  describe("format_completions", function()
    it("returns empty table for empty input", function()
      assert.are.same({}, te.format_completions({}))
    end)

    it("formats completions with kind icons", function()
      local completions = {
        { label = "String", kind = "Class", insertText = "String" },
        { label = "IO", kind = "Namespace", insertText = "IO" },
        { label = "Length", kind = "Property", insertText = "Length" },
      }
      local items = te.format_completions(completions)
      assert.are.equal(3, #items)
    end)

    it("marks drillable items with arrow", function()
      local completions = {
        { label = "IO", kind = "Namespace", insertText = "IO" },
        { label = "Length", kind = "Property", insertText = "Length" },
      }
      local items = te.format_completions(completions)
      local ns_item, prop_item
      for _, item in ipairs(items) do
        if item.insertText == "IO" then ns_item = item end
        if item.insertText == "Length" then prop_item = item end
      end
      assert.is_true(ns_item.drillable)
      assert.is_false(prop_item.drillable)
      assert.truthy(ns_item.label:find("→"))
      assert.is_nil(prop_item.label:find("→"))
    end)

    it("sorts drillable items first", function()
      local completions = {
        { label = "Length", kind = "Property", insertText = "Length" },
        { label = "IO", kind = "Namespace", insertText = "IO" },
      }
      local items = te.format_completions(completions)
      assert.is_true(items[1].drillable)
      assert.is_false(items[2].drillable)
    end)

    it("uses insertText for navigation", function()
      local items = te.format_completions({
        { label = "String", kind = "Class", insertText = "String" },
      })
      assert.are.equal("String", items[1].insertText)
    end)

    it("handles missing kind gracefully", function()
      local items = te.format_completions({
        { label = "Unknown", insertText = "Unknown" },
      })
      assert.are.equal(1, #items)
      assert.is_false(items[1].drillable)
    end)
  end)

  -- ─── format_members_panel ─────────────────────────────────────────────
  describe("format_members_panel", function()
    it("returns header with qualified name", function()
      local lines = te.format_members_panel("System.String", {})
      assert.truthy(lines[1]:match("System%.String"))
    end)

    it("groups members by kind", function()
      local completions = {
        { label = "Length", kind = "Property" },
        { label = "Substring", kind = "Method" },
        { label = "Empty", kind = "Field" },
      }
      local lines = te.format_members_panel("System.String", completions)
      local text = table.concat(lines, "\n")
      assert.truthy(text:match("Field:"))
      assert.truthy(text:match("Method:"))
      assert.truthy(text:match("Property:"))
    end)

    it("shows member labels under their kind", function()
      local completions = {
        { label = "Length", kind = "Property" },
        { label = "Substring", kind = "Method" },
      }
      local lines = te.format_members_panel("T", completions)
      local text = table.concat(lines, "\n")
      assert.truthy(text:match("Length"))
      assert.truthy(text:match("Substring"))
    end)
  end)

  -- ─── common_roots ─────────────────────────────────────────────────────
  describe("common_roots", function()
    it("returns non-empty list", function()
      local roots = te.common_roots()
      assert.is_true(#roots > 0)
    end)

    it("includes System", function()
      local roots = te.common_roots()
      local found = false
      for _, r in ipairs(roots) do
        if r == "System" then found = true; break end
      end
      assert.is_true(found)
    end)
  end)
end)
