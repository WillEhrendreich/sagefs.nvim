-- Event index tests — O(1) reverse lookup from events to sections

describe("event_index", function()
  local event_index = require("sagefs.dashboard.event_index")

  local sections = {
    { id = "health", events = { "connected", "disconnected", "warmup_progress" } },
    { id = "tests", events = { "test_summary", "test_state" } },
    { id = "session", events = { "connected", "session_faulted" } },
    { id = "output", events = { "eval_result" } },
    { id = "help", events = {} },
  }

  local idx

  before_each(function()
    idx = event_index.build(sections)
  end)

  -- ─── Build ──────────────────────────────────────────────────────────────

  it("builds an index from sections", function()
    assert.is_table(idx)
  end)

  it("maps shared events to multiple sections", function()
    local result = event_index.lookup(idx, "connected")
    assert.equals(2, #result)
    -- Both health and session listen to connected
    local ids = {}
    for _, id in ipairs(result) do ids[id] = true end
    assert.is_true(ids["health"])
    assert.is_true(ids["session"])
  end)

  it("maps unique events to single section", function()
    local result = event_index.lookup(idx, "test_summary")
    assert.equals(1, #result)
    assert.equals("tests", result[1])
  end)

  it("returns empty for unknown events", function()
    local result = event_index.lookup(idx, "unknown_event_xyz")
    assert.are.same({}, result)
  end)

  it("sections with no events produce no index entries", function()
    -- "help" has empty events — should not appear in any lookup
    for evt, _ in pairs(idx) do
      for _, sid in ipairs(idx[evt]) do
        assert.is_not.equals("help", sid)
      end
    end
  end)

  -- ─── to_set ─────────────────────────────────────────────────────────────

  it("to_set converts list to O(1) membership table", function()
    local ids = event_index.lookup(idx, "connected")
    local set = event_index.to_set(ids)
    assert.is_true(set["health"])
    assert.is_true(set["session"])
    assert.is_nil(set["tests"])
  end)

  it("to_set of empty list gives empty table", function()
    local set = event_index.to_set({})
    assert.are.same({}, set)
  end)

  -- ─── known_events ───────────────────────────────────────────────────────

  it("known_events returns sorted list of all event types", function()
    local events = event_index.known_events(idx)
    assert.is_true(#events > 0)
    -- Should be sorted
    for i = 2, #events do
      assert.is_true(events[i] >= events[i - 1])
    end
    -- Should include known events
    local eset = {}
    for _, e in ipairs(events) do eset[e] = true end
    assert.is_true(eset["connected"])
    assert.is_true(eset["test_summary"])
    assert.is_true(eset["eval_result"])
  end)

  -- ─── Property: every section event appears in the index ─────────────────

  it("every declared event maps back to its section", function()
    for _, s in ipairs(sections) do
      for _, evt in ipairs(s.events) do
        local ids = event_index.lookup(idx, evt)
        local found = false
        for _, id in ipairs(ids) do
          if id == s.id then found = true; break end
        end
        assert.is_true(found,
          string.format("section '%s' should be reachable via event '%s'", s.id, evt))
      end
    end
  end)

  -- ─── Edge: empty sections list ──────────────────────────────────────────

  it("build with empty sections list gives empty index", function()
    local empty_idx = event_index.build({})
    assert.are.same({}, event_index.known_events(empty_idx))
  end)
end)
