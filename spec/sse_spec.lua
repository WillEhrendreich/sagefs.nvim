-- =============================================================================
-- SSE Parser Tests — sagefs/sse.lua
-- =============================================================================
-- Expert panel:
--
-- **Gillilan**: SSE is the backbone. Get the parser right — partial chunks,
--   reconnection, event types. This is the read side of CQRS.
--
-- **Seemann**: SSE parsing is a pure function: string → Event list.
--   The reconnection policy is a separate concern. Test them independently.
--
-- **Muratori**: The SSE spec is trivial. Don't over-abstract it. The parser
--   is ~20 lines. The tests should be exhaustive on the MESSAGE FORMAT, not
--   on framework ceremony.
-- =============================================================================

local sse = require("sagefs.sse")

-- ─── parse_sse_chunk: parse raw SSE text into events ─────────────────────────

describe("sse.parse_chunk", function()
  it("parses a complete event", function()
    local chunk = "event: state\ndata: {\"key\":\"value\"}\n\n"
    local events, remainder = sse.parse_chunk(chunk)
    assert.are.equal(1, #events)
    assert.are.equal("state", events[1].type)
    assert.are.equal('{"key":"value"}', events[1].data)
  end)

  it("returns remainder for incomplete event", function()
    local chunk = "event: state\ndata: {\"key\":"
    local events, remainder = sse.parse_chunk(chunk)
    assert.are.equal(0, #events)
    assert.are.equal(chunk, remainder)
  end)

  it("handles multiple events in one chunk", function()
    local chunk = "event: state\ndata: {\"a\":1}\n\nevent: state\ndata: {\"b\":2}\n\n"
    local events, remainder = sse.parse_chunk(chunk)
    assert.are.equal(2, #events)
    assert.are.equal('{"a":1}', events[1].data)
    assert.are.equal('{"b":2}', events[2].data)
  end)

  it("handles event with no data", function()
    local chunk = "event: ping\n\n"
    local events, remainder = sse.parse_chunk(chunk)
    assert.are.equal(1, #events)
    assert.are.equal("ping", events[1].type)
    assert.is_nil(events[1].data)
  end)

  it("handles data with no event type", function()
    local chunk = "data: {\"key\":\"value\"}\n\n"
    local events, remainder = sse.parse_chunk(chunk)
    assert.are.equal(1, #events)
    assert.is_nil(events[1].type)
    assert.are.equal('{"key":"value"}', events[1].data)
  end)

  it("handles multi-line data fields", function()
    local chunk = "event: state\ndata: line1\ndata: line2\n\n"
    local events, remainder = sse.parse_chunk(chunk)
    assert.are.equal(1, #events)
    assert.are.equal("line1\nline2", events[1].data)
  end)

  it("ignores comment lines (starting with :)", function()
    local chunk = ": keepalive\nevent: state\ndata: {}\n\n"
    local events, remainder = sse.parse_chunk(chunk)
    assert.are.equal(1, #events)
    assert.are.equal("state", events[1].type)
  end)

  it("handles empty chunk", function()
    local events, remainder = sse.parse_chunk("")
    assert.are.equal(0, #events)
    assert.are.equal("", remainder)
  end)

  it("accumulates across calls (streaming simulation)", function()
    -- First chunk: partial event
    local events1, rem1 = sse.parse_chunk("event: state\n")
    assert.are.equal(0, #events1)

    -- Second chunk: completes the event
    local events2, rem2 = sse.parse_chunk(rem1 .. "data: {\"x\":1}\n\n")
    assert.are.equal(1, #events2)
    assert.are.equal("state", events2[1].type)
    assert.are.equal('{"x":1}', events2[1].data)
  end)

  it("strips trailing \\r from lines (Windows CRLF)", function()
    local chunk = "event: state\r\ndata: {}\r\n\r\n"
    local events, _ = sse.parse_chunk(chunk)
    assert.are.equal(1, #events)
    assert.are.equal("state", events[1].type)
  end)

  it("handles empty data field (data:)", function()
    local chunk = "event: ping\ndata:\n\n"
    local events, _ = sse.parse_chunk(chunk)
    assert.are.equal(1, #events)
    assert.are.equal("ping", events[1].type)
    assert.are.equal("", events[1].data)
  end)
end)

-- ─── Property tests: SSE parsing invariants ──────────────────────────────────

describe("sse.parse_chunk [property]", function()
  it("complete events + remainder reconstructs original (10 trials)", function()
    -- Any chunk ending with \n\n should produce at least one event
    -- and empty remainder
    for i = 1, 10 do
      local event_type = "type" .. i
      local data = "payload" .. i
      local chunk = "event: " .. event_type .. "\ndata: " .. data .. "\n\n"
      local events, remainder = sse.parse_chunk(chunk)
      assert.are.equal(1, #events,
        "should parse exactly 1 event for trial " .. i)
      assert.are.equal(event_type, events[1].type)
      assert.are.equal(data, events[1].data)
      assert.are.equal("", remainder)
    end
  end)

  it("incomplete chunk produces 0 events and full remainder", function()
    for i = 1, 10 do
      -- No \n\n terminator
      local chunk = "event: test" .. i .. "\ndata: value" .. i .. "\n"
      local events, remainder = sse.parse_chunk(chunk)
      assert.are.equal(0, #events,
        "incomplete chunk should produce 0 events, trial " .. i)
      assert.are.equal(chunk, remainder)
    end
  end)

  it("streaming accumulation: split any complete event at random point", function()
    math.randomseed(42)
    for _ = 1, 20 do
      local chunk = "event: state\ndata: hello\n\n"
      -- Split at a random point
      local split_at = math.random(1, #chunk - 1)
      local part1 = chunk:sub(1, split_at)
      local part2 = chunk:sub(split_at + 1)

      local events1, rem1 = sse.parse_chunk(part1)
      local events2, rem2 = sse.parse_chunk(rem1 .. part2)

      -- Total events across both calls should be exactly 1
      local total = #events1 + #events2
      assert.are.equal(1, total,
        "split at " .. split_at .. " produced " .. total .. " events")
    end
  end)

  it("N events in one chunk yields N parsed events", function()
    for n = 1, 5 do
      local parts = {}
      for i = 1, n do
        table.insert(parts, "event: e" .. i .. "\ndata: d" .. i .. "\n\n")
      end
      local chunk = table.concat(parts)
      local events, remainder = sse.parse_chunk(chunk)
      assert.are.equal(n, #events,
        "expected " .. n .. " events from " .. n .. "-event chunk")
      assert.are.equal("", remainder)
    end
  end)
end)

-- ─── safe_dispatch_batch: error isolation ────────────────────────────────────

describe("sse.safe_dispatch_batch", function()
  it("continues processing after a handler throws", function()
    local log = {}
    local dt = sse.build_dispatch_table({
      good = function() table.insert(log, "good") end,
      bad = function() error("handler crash") end,
      also_good = function() table.insert(log, "also_good") end,
    })
    local events = {
      { action = "good" },
      { action = "bad" },
      { action = "also_good" },
    }
    local errors = sse.safe_dispatch_batch(dt, events)
    assert.are.equal(2, #log, "both good handlers should run")
    assert.are.equal("good", log[1])
    assert.are.equal("also_good", log[2])
    assert.are.equal(1, #errors, "one error should be captured")
  end)

  it("returns empty error list when all handlers succeed", function()
    local count = 0
    local dt = sse.build_dispatch_table({
      a = function() count = count + 1 end,
      b = function() count = count + 1 end,
    })
    local errors = sse.safe_dispatch_batch(dt, {
      { action = "a" },
      { action = "b" },
    })
    assert.are.equal(2, count)
    assert.are.equal(0, #errors)
  end)

  it("skips events with no matching handler without error", function()
    local called = false
    local dt = sse.build_dispatch_table({
      known = function() called = true end,
    })
    local errors = sse.safe_dispatch_batch(dt, {
      { action = "unknown_action" },
      { action = "known" },
    })
    assert.is_true(called)
    assert.are.equal(0, #errors)
  end)

  it("handles nil events gracefully", function()
    local dt = sse.build_dispatch_table({})
    local errors = sse.safe_dispatch_batch(dt, { nil, { action = "x" } })
    assert.are.equal(0, #errors)
  end)
end)
