-- Tests for SSE session scoping filter
-- The session_matches function is local to init.lua, so we test it indirectly
-- by testing the exported session_matches helper we'll add to testing.lua

local testing = require("sagefs.testing")

describe("session_matches", function()
  it("accepts data with no SessionId (backward compat)", function()
    local result = testing.session_matches({ Total = 5 }, nil)
    assert.is_true(result)
  end)

  it("accepts data with no SessionId even when active_session exists", function()
    local result = testing.session_matches({ Total = 5 }, { id = "sess-123" })
    assert.is_true(result)
  end)

  it("accepts data when no active_session", function()
    local result = testing.session_matches({ SessionId = "sess-456", Total = 5 }, nil)
    assert.is_true(result)
  end)

  it("accepts data when SessionId matches active_session", function()
    local result = testing.session_matches(
      { SessionId = "sess-123", Total = 5 },
      { id = "sess-123" }
    )
    assert.is_true(result)
  end)

  it("rejects data when SessionId does not match active_session", function()
    local result = testing.session_matches(
      { SessionId = "sess-456", Total = 5 },
      { id = "sess-123" }
    )
    assert.is_false(result)
  end)

  it("rejects nil data", function()
    local result = testing.session_matches(nil, { id = "sess-123" })
    assert.is_false(result)
  end)

  it("accepts when SessionId is empty string and active_session.id is empty", function()
    local result = testing.session_matches(
      { SessionId = "", Total = 5 },
      { id = "" }
    )
    assert.is_true(result)
  end)
end)
