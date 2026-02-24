require("spec.helper")
local export = require("sagefs.export")

describe("export", function()
  describe("format_fsx", function()
    it("returns empty string for empty events", function()
      assert.are.equal("", export.format_fsx({}))
    end)

    it("formats single event", function()
      local events = {
        { code = "let x = 42;;", result = "val x: int = 42", source = "user" },
      }
      local fsx = export.format_fsx(events)
      assert.truthy(fsx:match("let x = 42;;"))
      assert.truthy(fsx:match("// val x: int = 42"))
    end)

    it("formats multiple events", function()
      local events = {
        { code = "let a = 1;;", result = "val a: int = 1", source = "user" },
        { code = "let b = 2;;", result = "val b: int = 2", source = "user" },
      }
      local fsx = export.format_fsx(events)
      assert.truthy(fsx:match("let a = 1;;"))
      assert.truthy(fsx:match("let b = 2;;"))
    end)

    it("skips hotreload events", function()
      local events = {
        { code = "let a = 1;;", result = "val a: int = 1", source = "user" },
        { code = "module Lib", result = "", source = "hotreload" },
        { code = "let b = 2;;", result = "val b: int = 2", source = "user" },
      }
      local fsx = export.format_fsx(events)
      assert.truthy(fsx:match("let a = 1;;"))
      assert.truthy(fsx:match("let b = 2;;"))
      assert.is_nil(fsx:match("module Lib"))
    end)

    it("handles events without result", function()
      local events = {
        { code = "open System;;", source = "user" },
      }
      local fsx = export.format_fsx(events)
      assert.truthy(fsx:match("open System;;"))
      assert.is_nil(fsx:match("//"))
    end)

    it("handles empty result string", function()
      local events = {
        { code = "open System;;", result = "", source = "user" },
      }
      local fsx = export.format_fsx(events)
      assert.is_nil(fsx:match("//"))
    end)

    it("handles events with nil code", function()
      local events = {
        { source = "user", result = "something" },
      }
      local fsx = export.format_fsx(events)
      assert.truthy(fsx:match("// something"))
    end)
  end)
end)
