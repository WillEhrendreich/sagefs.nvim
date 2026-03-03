require("spec.helper")
local diagnostics = require("sagefs.diagnostics")

describe("diagnostics", function()
  -- ─── group_by_file ───────────────────────────────────────────────────────
  describe("group_by_file", function()
    it("returns empty table for empty input", function()
      local groups = diagnostics.group_by_file({})
      assert.are.same({}, groups)
    end)

    it("groups single diagnostic", function()
      local diags = { { file = "a.fs", message = "err1" } }
      local groups = diagnostics.group_by_file(diags)
      assert.are.equal(1, #groups["a.fs"])
      assert.are.equal("err1", groups["a.fs"][1].message)
    end)

    it("groups multiple diagnostics by file", function()
      local diags = {
        { file = "a.fs", message = "e1" },
        { file = "b.fs", message = "e2" },
        { file = "a.fs", message = "e3" },
      }
      local groups = diagnostics.group_by_file(diags)
      assert.are.equal(2, #groups["a.fs"])
      assert.are.equal(1, #groups["b.fs"])
    end)

    it("uses empty string for missing file", function()
      local diags = { { message = "e1" } }
      local groups = diagnostics.group_by_file(diags)
      assert.are.equal(1, #groups[""])
    end)
  end)

  -- ─── severity_to_level ───────────────────────────────────────────────────
  describe("severity_to_level", function()
    it("maps error to 1", function()
      assert.are.equal(1, diagnostics.severity_to_level("error"))
    end)

    it("maps warning to 2", function()
      assert.are.equal(2, diagnostics.severity_to_level("warning"))
    end)

    it("maps info to 3", function()
      assert.are.equal(3, diagnostics.severity_to_level("info"))
    end)

    it("maps hint to 4", function()
      assert.are.equal(4, diagnostics.severity_to_level("hint"))
    end)

    it("defaults unknown to 4 (hint)", function()
      assert.are.equal(4, diagnostics.severity_to_level("unknown"))
    end)
  end)

  -- ─── to_vim_diagnostic ───────────────────────────────────────────────────
  describe("to_vim_diagnostic", function()
    it("converts 1-indexed to 0-indexed", function()
      local raw = { startLine = 10, startColumn = 5, endLine = 10, endColumn = 15, message = "err", severity = "error" }
      local vd = diagnostics.to_vim_diagnostic(raw)
      assert.are.equal(9, vd.lnum)
      assert.are.equal(4, vd.col)
      assert.are.equal(9, vd.end_lnum)
      assert.are.equal(14, vd.end_col)
    end)

    it("sets message and severity", function()
      local vd = diagnostics.to_vim_diagnostic({ message = "type mismatch", severity = "error" })
      assert.are.equal("type mismatch", vd.message)
      assert.are.equal(1, vd.severity)
    end)

    it("sets source to sagefs", function()
      local vd = diagnostics.to_vim_diagnostic({})
      assert.are.equal("sagefs", vd.source)
    end)

    it("defaults missing fields", function()
      local vd = diagnostics.to_vim_diagnostic({})
      assert.are.equal(0, vd.lnum)
      assert.are.equal(0, vd.col)
      assert.are.equal("", vd.message)
      assert.are.equal(4, vd.severity)
    end)

    it("uses startLine for missing endLine", function()
      local vd = diagnostics.to_vim_diagnostic({ startLine = 5, startColumn = 3 })
      assert.are.equal(4, vd.lnum)
      assert.are.equal(4, vd.end_lnum)
    end)
  end)

  -- ─── to_vim_diagnostics ──────────────────────────────────────────────────
  describe("to_vim_diagnostics", function()
    it("converts list of raw diagnostics", function()
      local raw = {
        { startLine = 1, startColumn = 1, message = "a", severity = "error" },
        { startLine = 2, startColumn = 1, message = "b", severity = "warning" },
      }
      local vds = diagnostics.to_vim_diagnostics(raw)
      assert.are.equal(2, #vds)
      assert.are.equal(0, vds[1].lnum)
      assert.are.equal(1, vds[2].lnum)
    end)

    it("returns empty for empty input", function()
      assert.are.same({}, diagnostics.to_vim_diagnostics({}))
    end)
  end)

  -- ─── parse_sse_payload ───────────────────────────────────────────────────
  describe("parse_sse_payload", function()
    it("returns error for nil input", function()
      local data, err = diagnostics.parse_sse_payload(nil)
      assert.is_nil(data)
      assert.truthy(err)
    end)

    it("returns error for empty string", function()
      local data, err = diagnostics.parse_sse_payload("")
      assert.is_nil(data)
      assert.truthy(err)
    end)

    it("parses valid JSON with diagnostics key", function()
      local json = '{"diagnostics":[{"file":"a.fs","message":"err","startLine":1,"startColumn":1,"severity":"error"}]}'
      local data, err = diagnostics.parse_sse_payload(json)
      assert.is_nil(err)
      assert.is_table(data)
      assert.are.equal(1, #data)
      assert.are.equal("a.fs", data[1].file)
    end)

    it("returns empty table when diagnostics key missing", function()
      local data, err = diagnostics.parse_sse_payload('{"other":"value"}')
      assert.is_nil(err)
      assert.are.same({}, data)
    end)
  end)

  -- ─── process_sse_event ───────────────────────────────────────────────────
  describe("process_sse_event", function()
    it("returns error for invalid JSON", function()
      local groups, err = diagnostics.process_sse_event("not json")
      assert.is_nil(groups)
      assert.truthy(err)
    end)

    it("processes full cycle", function()
      local json = '{"diagnostics":[' ..
        '{"file":"a.fs","message":"err1","startLine":1,"startColumn":1,"severity":"error"},' ..
        '{"file":"a.fs","message":"err2","startLine":5,"startColumn":1,"severity":"warning"},' ..
        '{"file":"b.fs","message":"warn1","startLine":3,"startColumn":2,"severity":"warning"}' ..
        ']}'
      local groups, err = diagnostics.process_sse_event(json)
      assert.is_nil(err)
      assert.is_table(groups)
      assert.are.equal(2, #groups["a.fs"])
      assert.are.equal(1, #groups["b.fs"])
      -- Check converted format
      assert.are.equal(0, groups["a.fs"][1].lnum)
      assert.are.equal(1, groups["a.fs"][1].severity)
      assert.are.equal("sagefs", groups["a.fs"][1].source)
    end)

    it("returns empty groups for no diagnostics", function()
      local groups, err = diagnostics.process_sse_event('{"diagnostics":[]}')
      assert.is_nil(err)
      assert.are.same({}, groups)
    end)
  end)

  -- ─── parse_check_response ─────────────────────────────────────────────────
  describe("parse_check_response", function()
    it("returns nil and error for nil input", function()
      local result, err = diagnostics.parse_check_response(nil)
      assert.is_nil(result)
      assert.is_not_nil(err)
    end)

    it("returns nil and error for empty string", function()
      local result, err = diagnostics.parse_check_response("")
      assert.is_nil(result)
      assert.is_not_nil(err)
    end)

    it("returns nil and error for invalid JSON", function()
      local result, err = diagnostics.parse_check_response("not json")
      assert.is_nil(result)
      assert.is_not_nil(err)
    end)

    it("returns grouped vim diagnostics for valid response", function()
      local json = '{"diagnostics":[' ..
        '{"file":"Foo.fs","startLine":3,"startColumn":5,"endLine":3,"endColumn":10,"message":"err1","severity":"error"},' ..
        '{"file":"Foo.fs","startLine":7,"startColumn":1,"endLine":7,"endColumn":4,"message":"warn1","severity":"warning"},' ..
        '{"file":"Bar.fs","startLine":1,"startColumn":1,"endLine":1,"endColumn":2,"message":"hint1","severity":"hint"}' ..
      ']}'
      local result, err = diagnostics.parse_check_response(json)
      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.are.equal(2, #result["Foo.fs"])
      assert.are.equal(1, #result["Bar.fs"])
      -- verify vim diagnostic format
      assert.are.equal(2, result["Foo.fs"][1].lnum) -- 0-indexed
      assert.are.equal("err1", result["Foo.fs"][1].message)
      assert.are.equal("sagefs", result["Foo.fs"][1].source)
    end)

    it("returns empty table when diagnostics array is empty", function()
      local result, err = diagnostics.parse_check_response('{"diagnostics":[]}')
      assert.is_nil(err)
      assert.are.same({}, result)
    end)

    it("handles response with no diagnostics key", function()
      local result, err = diagnostics.parse_check_response('{"other":"data"}')
      assert.is_nil(err)
      assert.are.same({}, result)
    end)
  end)
end)
