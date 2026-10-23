-- A frame that carries no Entries must still move the state.
--
-- The stream is moving to a summary on the wire with the list behind
-- GET /api/live-testing/entries, so a `test_results_batch` arrives with a tally and a verdict and no
-- entries. `handle_results_batch` used to do all of that work inside `if entries`, so such a frame
-- would be read and thrown away: no summary, no freshness, no completion, and no version bump, which
-- is the thing schedule_render uses to decide a render is worth doing.
--
-- `Generation` is the only field needed to state it: the bump is what the assertion is about, and a
-- payload carrying nothing else is exactly the shape the stream is about to produce.
local testing = require("sagefs.testing")

describe("testing.handle_results_batch [RED] summary-only frame", function()
  it("applies the frame when there are no Entries, because the list is behind a fetch now", function()
    local state = testing.new()
    state = testing.set_enabled(state, true)
    local before = state._version

    state = testing.handle_results_batch(state, {
      SessionId = "s1",
      Generation = 3,
    })

    assert.is_true(
      state._version > before,
      "a frame with no Entries must still bump the render version; a summary-only frame is the shape the stream sends once the list is behind /api/live-testing/entries"
    )
  end)

  it("still applies every entry when the frame does carry them", function()
    local state = testing.new()
    state = testing.set_enabled(state, true)
    local before = state._version

    state = testing.handle_results_batch(state, {
      Generation = 1,
      Entries = {
        { testId = "t1", displayName = "test 1", fullName = "test 1",
          category = "Unit", currentPolicy = "OnEveryChange", status = "Passed" },
      },
    })

    assert.is_true(state._version > before, "an entries frame keeps working exactly as it did")
  end)
end)
