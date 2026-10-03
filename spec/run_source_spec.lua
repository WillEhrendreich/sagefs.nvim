-- Gap 4: a per-run `source` on the test_run_completed SSE payload.
--
-- Today the plugin answers "which build did that run use?" by re-reading the
-- whole session list after every finished run (`refresh_sessions = true` in
-- init.lua's SSE_HANDLER_DEFS), because the run's own event says nothing about
-- the build it ran against. A stale build turning a red test green is exactly
-- the thing a user must not be shown as a pass, and a whole-list GET after every
-- run is a lot of traffic to learn one fact.
--
-- When the daemon sends a run's own source, the plugin reads it from the event
-- and does NOT re-read the list. When it sends nothing, the plugin keeps the
-- old behaviour, because a daemon older than this field is the normal case for
-- anyone who has not updated yet: absence must mean "ask the old way", never an
-- error and never a silent false "this run was fine".
--
-- VERIFIED AGAINST THE DAEMON: this event does not exist. SageFs.Core/SseWriter.fs
-- `allSseEventTypes` is the authoritative registry and carries no test_run_*
-- entry, and no source anywhere in the daemon writes a `test_run_completed`
-- payload. The per-run source the daemon does have is `source` in the run_tests
-- receipt (SageFs.Core/Features/TestRunReceipt.fs:316), which is an MCP reply,
-- not an SSE event. So the field below is a shape the plugin is ready for, not
-- one it has seen. Every degradation case here is therefore live code, not
-- hypothetical: against every daemon released so far the plugin takes the
-- "no source" branch on every finished run.

local testing = require("sagefs.testing")
local source_state = require("sagefs.source_state")

describe("a run's own source says which build that run used", function()
  it("stores a stale verdict the run reported about itself", function()
    local state = testing.new()
    state = testing.handle_test_run_completed(state, {
      SessionId = "src00001",
      Generation = 7,
      source = { state = "Stale", message = "STALE SOURCE: 2 file(s) changed on disk after the build this session runs.",
                 changedFiles = { { path = "/src/Ticker.fs", because = "EditedAfterBuild", detail = "edited after the build" } } },
    })
    local f = source_state.parse(state.run_source)
    assert.is_table(f, "the run's own source is kept on the testing state")
    assert.are.equal("Stale", f.state)
    assert.is_true(source_state.is_stale(f))
    assert.are.equal(1, #f.changed)
    assert.are.equal("/src/Ticker.fs", f.changed[1].path)
  end)

  it("stores an in-sync verdict too, so a green run is not read as unknown", function()
    local state = testing.new()
    state = testing.handle_test_run_completed(state, {
      SessionId = "src00001",
      source = { state = "InSync", filesChecked = 12, message = "Nothing the build was made from has changed." },
    })
    local f = source_state.parse(state.run_source)
    assert.is_table(f)
    assert.are.equal("InSync", f.state)
    assert.is_false(source_state.is_stale(f))
    assert.are.equal(12, f.files_checked)
  end)

  it("records the generation the run was, so a late event cannot overwrite a newer one", function()
    local state = testing.new()
    state.generation = 9
    state = testing.handle_test_run_completed(state, { SessionId = "src00001", Generation = 4, source = { state = "Stale" } })
    assert.are.equal(9, state.generation, "an event from an older generation is not applied")
  end)

  it("applies an event from the current or a newer generation", function()
    local state = testing.new()
    state.generation = 4
    state = testing.handle_test_run_completed(state, { SessionId = "src00001", Generation = 5, source = { state = "Stale" } })
    assert.are.equal(5, state.generation)
    assert.are.equal("Stale", state.run_source.state)
  end)
end)

describe("a DEPRECATED daemon that sends no per-run source degrades quietly", function()
  -- The plugin ships commit by commit against whatever daemon the user last
  -- installed. A daemon with no `source` on the event must leave the run's
  -- verdict unknown (nil), which is the state that still asks the session list.

  it("leaves run_source nil so nothing is claimed about the build", function()
    local state = testing.new()
    state = testing.handle_test_run_completed(state, { SessionId = "src00001", Generation = 1 })
    assert.is_nil(state.run_source, "no source is invented for a daemon that sent none")
  end)

  it("does not treat an absent source as in sync", function()
    local state = testing.new()
    state = testing.handle_test_run_completed(state, { SessionId = "src00001" })
    assert.is_false(source_state.is_stale(source_state.parse(state.run_source)))
    assert.is_nil(source_state.parse(state.run_source))
  end)

  it("ignores a malformed source object rather than failing the run", function()
    local state = testing.new()
    state = testing.handle_test_run_completed(state, { SessionId = "src00001", source = "Stale" })
    assert.is_nil(state.run_source)
    assert.is_true(state.summary ~= nil)
  end)

  it("keeps the last known verdict when a later event carries none", function()
    local state = testing.new()
    state = testing.handle_test_run_completed(state, { SessionId = "src00001", Generation = 1, source = { state = "Stale" } })
    state = testing.handle_test_run_completed(state, { SessionId = "src00001", Generation = 2 })
    assert.is_table(state.run_source, "the last thing known is kept, not erased by silence")
    assert.are.equal("Stale", state.run_source.state)
  end)

  it("still updates the summary when the event has no source", function()
    local state = testing.new()
    state = testing.handle_test_run_completed(state, {
      SessionId = "src00001",
      summary = { total = 5, passed = 4, failed = 1, stale = 0, running = 0 },
    })
    assert.are.equal(5, state.summary.total)
    assert.are.equal(4, state.summary.passed)
  end)
end)

describe("whether a finished run still needs the session list re-read", function()
  -- The stand-in the per-run field replaces. With the field, the list is not read
  -- again; without it, it is, because that is the only way to learn the build.

  it("says yes when the run reported its own source, so the list is not read again", function()
    local state = testing.new()
    state = testing.handle_test_run_completed(state, { SessionId = "src00001", Generation = 1, source = { state = "InSync" } })
    assert.is_true(testing.run_source_is_authoritative(state), "the run already said which build it used, so the list is not the answer")
  end)

  it("says no against a daemon that sends no source", function()
    local state = testing.new()
    state = testing.handle_test_run_completed(state, { SessionId = "src00001", Generation = 1 })
    assert.is_false(testing.run_source_is_authoritative(state), "nothing was said, so the list is still the answer")
  end)
end)
