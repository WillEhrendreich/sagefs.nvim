-- spec/util_spec.lua — Tests for shared json_decode utility
local helper = require("spec.helper")
local util = require("sagefs.util")

describe("sagefs.util", function()
  describe("json_decode", function()
    it("decodes valid JSON object", function()
      local ok, data = util.json_decode('{"name":"test","value":42}')
      assert.is_true(ok)
      assert.equals("test", data.name)
      assert.equals(42, data.value)
    end)

    it("decodes valid JSON array", function()
      local ok, data = util.json_decode('[1,2,3]')
      assert.is_true(ok)
      assert.equals(3, #data)
    end)

    it("returns false for invalid JSON", function()
      local ok, _ = util.json_decode("{bad json")
      assert.is_false(ok)
    end)

    it("returns false for nil input", function()
      local ok, _ = util.json_decode(nil)
      assert.is_false(ok)
    end)

    it("returns false for empty string", function()
      local ok, _ = util.json_decode("")
      assert.is_false(ok)
    end)

    it("handles nested objects", function()
      local ok, data = util.json_decode('{"a":{"b":{"c":1}}}')
      assert.is_true(ok)
      assert.equals(1, data.a.b.c)
    end)

    it("handles boolean values", function()
      local ok, data = util.json_decode('{"enabled":true,"disabled":false}')
      assert.is_true(ok)
      assert.is_true(data.enabled)
      assert.is_false(data.disabled)
    end)

    it("handles null values", function()
      local ok, data = util.json_decode('{"key":null}')
      assert.is_true(ok)
      assert.is_table(data)
    end)
  end)

  -- ─── format_server_error ──────────────────────────────────────────────────
  -- The server's error shape is `{case, fields, message, suggestedAction}`,
  -- or `/api/sessions/*` action errors wrap it in
  -- `{success=false, error=<describe>, errorDetails={message, suggestedAction}}`.
  -- Across the plugin, ~84 error sites parsed `message`/`reason` only and
  -- threw `suggestedAction` away. This is the one shared function every
  -- site should route through instead.

  describe("format_server_error", function()
    it("appends suggestedAction to message when both are present (flat shape)", function()
      local msg = util.format_server_error({ message = "No session", suggestedAction = "Create one first" }, nil)
      assert.equals("No session → Create one first", msg)
    end)

    it("supports PascalCase Message/SuggestedAction", function()
      local msg = util.format_server_error({ Message = "Boom", SuggestedAction = "Retry" }, nil)
      assert.equals("Boom → Retry", msg)
    end)

    it("returns bare message when there is no suggestedAction (flat shape)", function()
      local msg = util.format_server_error({ message = "No session" }, nil)
      assert.equals("No session", msg)
    end)

    it("reads message and suggestedAction from a nested errorDetails wrapper", function()
      local msg = util.format_server_error({
        success = false,
        error = "Session not found",
        errorDetails = { case = "NotFound", message = "Session not found", suggestedAction = "Run :SageFsCreateSession" },
      }, nil)
      assert.equals("Session not found → Run :SageFsCreateSession", msg)
    end)

    it("falls back to the top-level error field when errorDetails is absent", function()
      local msg = util.format_server_error({ success = false, error = "unknown error" }, nil)
      assert.equals("unknown error", msg)
    end)

    it("falls back to raw text when parsed is nil", function()
      assert.equals("connect: refused", util.format_server_error(nil, "connect: refused"))
    end)

    it("falls back to a generic message when both parsed and raw are nil", function()
      assert.equals("Unknown error", util.format_server_error(nil, nil))
    end)

    it("also reads reason as a message fallback", function()
      local msg = util.format_server_error({ reason = "worker unreachable" }, nil)
      assert.equals("worker unreachable", msg)
    end)
  end)
end)
