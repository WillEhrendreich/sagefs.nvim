require("spec.helper")
local completions = require("sagefs.completions")

describe("completions", function()

  describe("parse_response", function()
    it("returns empty list for nil input", function()
      assert.same({}, completions.parse_response(nil))
    end)

    it("returns empty list for invalid JSON", function()
      assert.same({}, completions.parse_response("{bad json"))
    end)

    it("returns empty list when completions field missing", function()
      local json = '{"other": "data"}'
      assert.same({}, completions.parse_response(json))
    end)

    it("maps label to abbr and word", function()
      local json = '{"completions": [{"label": "Printf", "insertText": "Printf"}]}'
      local result = completions.parse_response(json)
      assert.are.equal(1, #result)
      assert.are.equal("Printf", result[1].word)
      assert.are.equal("Printf", result[1].abbr)
      assert.are.equal("[SageFs]", result[1].menu)
    end)

    it("uses insertText over label for word", function()
      local json = '{"completions": [{"label": "List.map", "insertText": "map"}]}'
      local result = completions.parse_response(json)
      assert.are.equal("map", result[1].word)
      assert.are.equal("List.map", result[1].abbr)
    end)

    it("includes kind when present", function()
      local json = '{"completions": [{"label": "x", "kind": "Method"}]}'
      local result = completions.parse_response(json)
      assert.are.equal("Method", result[1].kind)
    end)

    it("defaults kind to empty string", function()
      local json = '{"completions": [{"label": "x"}]}'
      local result = completions.parse_response(json)
      assert.are.equal("", result[1].kind)
    end)

    it("handles multiple completions", function()
      local json = '{"completions": [{"label": "a"}, {"label": "b"}, {"label": "c"}]}'
      local result = completions.parse_response(json)
      assert.are.equal(3, #result)
    end)
  end)

  describe("build_request_body", function()
    it("returns table with code, cursor_position, working_directory", function()
      local body = completions.build_request_body("let x = 1", 5, "/my/dir")
      assert.are.equal("let x = 1", body.code)
      assert.are.equal(5, body.cursor_position)
      assert.are.equal("/my/dir", body.working_directory)
    end)
  end)

end)
