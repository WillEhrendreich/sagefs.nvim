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

  -- After a reconnect the stream can replay several summary-only batch frames, each firing its own
  -- fetch, and the answers land in any order. The one that landed last decided the generation,
  -- freshness and completion the panel showed, even when it belonged to an older frame. A frame that
  -- owes a fetch takes a ticket for its session; only the newest ticket's answer may be applied.
  describe("ticket gate", function()
    it("lets a frame's own answer through when no newer frame has asked since", function()
      local gate = hydration.new_gate()
      local ticket = hydration.take_ticket(gate, "s1")
      assert.is_true(hydration.is_current(gate, "s1", ticket))
    end)

    it("drops an older frame's answer once a newer frame has asked", function()
      local gate = hydration.new_gate()
      local first = hydration.take_ticket(gate, "s1")
      local second = hydration.take_ticket(gate, "s1")
      assert.is_false(hydration.is_current(gate, "s1", first), "the second ask supersedes the first")
      assert.is_true(hydration.is_current(gate, "s1", second))
    end)

    it("keeps one session's asks apart from another's", function()
      local gate = hydration.new_gate()
      local mine = hydration.take_ticket(gate, "s1")
      hydration.take_ticket(gate, "s2")
      assert.is_true(hydration.is_current(gate, "s1", mine))
    end)

    it("does not count a ticket for a session that never asked", function()
      assert.is_false(hydration.is_current(hydration.new_gate(), "s1", 1))
    end)

    it("hands out tickets that only grow", function()
      local gate = hydration.new_gate()
      local a = hydration.take_ticket(gate, "s1")
      local b = hydration.take_ticket(gate, "s1")
      assert.is_true(b > a)
    end)
  end)
end)
