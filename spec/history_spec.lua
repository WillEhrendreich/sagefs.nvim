require("spec.helper")
local history = require("sagefs.history")

describe("history", function()
  -- ─── format_events ───────────────────────────────────────────────────────
  describe("format_events", function()
    it("returns empty table for empty input", function()
      assert.are.same({}, history.format_events({}))
    end)

    it("formats a single event", function()
      local events = {
        { code = "let x = 42;;", result = "val x: int = 42", timestamp = "2024-01-01T00:00:00", source = "user" },
      }
      local items = history.format_events(events)
      assert.are.equal(1, #items)
      assert.truthy(items[1].label:match("let x = 42;;"))
      assert.are.equal("let x = 42;;", items[1].code)
      assert.are.equal("val x: int = 42", items[1].result)
    end)

    it("uses ▶ icon for user source", function()
      local items = history.format_events({
        { code = "x", source = "user", timestamp = "" },
      })
      assert.truthy(items[1].label:match("▶"))
    end)

    it("uses ⟳ icon for hotreload source", function()
      local items = history.format_events({
        { code = "x", source = "hotreload", timestamp = "" },
      })
      assert.truthy(items[1].label:match("⟳"))
    end)

    it("truncates long code in label", function()
      local long_code = string.rep("a", 200)
      local items = history.format_events({
        { code = long_code, source = "user", timestamp = "" },
      })
      assert.is_true(#items[1].label <= 140)
      assert.truthy(items[1].label:match("%.%.%."))
    end)

    it("preserves full code in item data", function()
      local long_code = string.rep("a", 200)
      local items = history.format_events({
        { code = long_code, source = "user", timestamp = "" },
      })
      assert.are.equal(200, #items[1].code)
    end)

    it("handles missing fields gracefully", function()
      local items = history.format_events({ {} })
      assert.are.equal(1, #items)
      assert.are.equal("", items[1].code)
      assert.are.equal("", items[1].result)
      assert.are.equal("", items[1].timestamp)
      assert.are.equal("", items[1].source)
    end)
  end)

  -- ─── format_preview ──────────────────────────────────────────────────────
  describe("format_preview", function()
    it("returns lines with header, code, and result sections", function()
      local event = {
        code = "let x = 42;;",
        result = "val x: int = 42",
        timestamp = "2024-01-01",
        source = "user",
      }
      local lines = history.format_preview(event)
      assert.is_true(#lines > 0)
      -- Header with source and timestamp
      assert.truthy(lines[1]:match("user"))
      assert.truthy(lines[1]:match("2024%-01%-01"))
      -- Code section
      local has_code = false
      for _, l in ipairs(lines) do
        if l:match("let x = 42") then has_code = true; break end
      end
      assert.is_true(has_code)
      -- Result section
      local has_result = false
      for _, l in ipairs(lines) do
        if l:match("val x: int = 42") then has_result = true; break end
      end
      assert.is_true(has_result)
    end)

    it("handles multi-line code", function()
      local event = {
        code = "let a = 1\nlet b = 2",
        result = "",
        source = "user",
        timestamp = "",
      }
      local lines = history.format_preview(event)
      local code_lines = {}
      for _, l in ipairs(lines) do
        if l:match("let [ab]") then table.insert(code_lines, l) end
      end
      assert.are.equal(2, #code_lines)
    end)

    it("handles missing fields", function()
      local lines = history.format_preview({})
      assert.is_table(lines)
      assert.is_true(#lines > 0)
    end)
  end)

  -- ─── parse_events_response ───────────────────────────────────────────────
  describe("parse_events_response", function()
    it("returns nil for empty input", function()
      local data, err = history.parse_events_response("")
      assert.is_nil(data)
      assert.truthy(err)
    end)

    it("returns nil for nil input", function()
      local data, err = history.parse_events_response(nil)
      assert.is_nil(data)
      assert.truthy(err)
    end)

    it("parses valid JSON array", function()
      local json = '[{"code":"x","result":"y","source":"user","timestamp":"now"}]'
      local data, err = history.parse_events_response(json)
      assert.is_nil(err)
      assert.is_table(data)
      assert.are.equal(1, #data)
      assert.are.equal("x", data[1].code)
    end)
  end)
end)
