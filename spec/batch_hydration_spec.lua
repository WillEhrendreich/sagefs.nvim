-- The two questions a summary-only batch frame asks, kept pure so neither the SSE dispatcher
-- (IO) nor testing's reducer (state, data -> state) has to answer them.
local hydration = require("sagefs.batch_hydration")

describe("batch_hydration", function()

  describe("needs_entries", function()
    it("asks for the list when the frame carries a session and no entries", function()
      assert.is_true(hydration.needs_entries({ SessionId = "s1", Completion = { Case = "Complete" } }))
    end)

    it("does not ask when the frame already carries the list", function()
      assert.is_false(hydration.needs_entries({ SessionId = "s1", Entries = {} }))
      assert.is_false(hydration.needs_entries({ sessionId = "s1", entries = {} }))
    end)

    it("does not ask when it does not know whose list it would be", function()
      assert.is_false(hydration.needs_entries({ Completion = { Case = "Complete" } }))
      assert.is_false(hydration.needs_entries({ SessionId = "" }))
    end)

    it("does not ask of something that is not a frame", function()
      assert.is_false(hydration.needs_entries(nil))
      assert.is_false(hydration.needs_entries("garbage"))
    end)
  end)

  describe("session_of", function()
    it("reads either spelling", function()
      assert.are.equal("s1", hydration.session_of({ SessionId = "s1" }))
      assert.are.equal("s2", hydration.session_of({ sessionId = "s2" }))
      assert.is_nil(hydration.session_of({ SessionId = "" }))
    end)
  end)

  describe("with_entries", function()
    it("splices the list in and leaves the frame it was given untouched", function()
      local frame = { SessionId = "s1", Generation = 3, Completion = { Case = "Complete" } }
      local entries = { { TestId = "t1" } }
      local enriched = hydration.with_entries(frame, entries)

      assert.are.equal(entries, enriched.Entries)
      assert.are.equal(3, enriched.Generation, "the tally and the verdict ride along with the list")
      assert.are.equal("s1", enriched.SessionId)
      assert.is_nil(frame.Entries, "a hydrator that rewrote its input would be the reason a later render showed the wrong list")
    end)
  end)
end)
