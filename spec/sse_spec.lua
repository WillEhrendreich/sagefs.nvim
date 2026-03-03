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

-- ─── classify_event: snake_case SSE event types from SageFs ──────────────────

describe("sse.classify_event snake_case events", function()
  it("classifies test_results_batch (snake_case from SSE)", function()
    local result = sse.classify_event({ type = "test_results_batch", data = "{}" })
    assert.are.equal("test_results_batch", result.action)
  end)

  it("classifies test_summary (new SSE event type)", function()
    local result = sse.classify_event({ type = "test_summary", data = "{}" })
    assert.are.equal("test_summary", result.action)
  end)

  it("classifies test_run_started (snake_case)", function()
    local result = sse.classify_event({ type = "test_run_started", data = "{}" })
    assert.are.equal("test_run_started", result.action)
  end)

  it("classifies test_run_completed (snake_case)", function()
    local result = sse.classify_event({ type = "test_run_completed", data = "{}" })
    assert.are.equal("test_run_completed", result.action)
  end)

  it("classifies live_testing_enabled (snake_case)", function()
    local result = sse.classify_event({ type = "live_testing_enabled", data = "{}" })
    assert.are.equal("live_testing_enabled", result.action)
  end)

  it("classifies live_testing_disabled (snake_case)", function()
    local result = sse.classify_event({ type = "live_testing_disabled", data = "{}" })
    assert.are.equal("live_testing_disabled", result.action)
  end)

  it("classifies tests_discovered (snake_case)", function()
    local result = sse.classify_event({ type = "tests_discovered", data = "{}" })
    assert.are.equal("tests_discovered", result.action)
  end)

  it("classifies providers_detected (snake_case)", function()
    local result = sse.classify_event({ type = "providers_detected", data = "{}" })
    assert.are.equal("providers_detected", result.action)
  end)

  it("classifies test_cycle_timing_recorded (snake_case)", function()
    local result = sse.classify_event({ type = "test_cycle_timing_recorded", data = "{}" })
    assert.are.equal("test_cycle_timing_recorded", result.action)
  end)

  it("still classifies PascalCase TestResultsBatch", function()
    local result = sse.classify_event({ type = "TestResultsBatch", data = "{}" })
    assert.are.equal("test_results_batch", result.action)
  end)

  it("classifies file_annotations (snake_case from SSE)", function()
    local result = sse.classify_event({ type = "file_annotations", data = "{}" })
    assert.are.equal("file_annotations", result.action)
  end)

  it("classifies FileAnnotationsUpdated (PascalCase)", function()
    local result = sse.classify_event({ type = "FileAnnotationsUpdated", data = "{}" })
    assert.are.equal("file_annotations", result.action)
  end)
end)

-- ─── Full SSE round-trip: parse → classify typed test events ─────────────────

describe("sse parse + classify typed test events", function()
  it("parses and classifies test_summary SSE event", function()
    local chunk = 'event: test_summary\ndata: {"Total":5,"Passed":3,"Failed":1,"Stale":1,"Running":0,"Disabled":0}\n\n'
    local events = sse.parse_chunk(chunk)
    assert.are.equal(1, #events)
    local classified = sse.classify_event(events[1])
    assert.are.equal("test_summary", classified.action)
    assert.truthy(classified.data:find('"Total"'))
  end)

  it("parses and classifies test_results_batch SSE event", function()
    local chunk = 'event: test_results_batch\ndata: {"Entries":[],"Summary":{"Total":0}}\n\n'
    local events = sse.parse_chunk(chunk)
    assert.are.equal(1, #events)
    local classified = sse.classify_event(events[1])
    assert.are.equal("test_results_batch", classified.action)
  end)
end)

-- ─── reconnect_delay: exponential backoff with jitter ─────────────────────────

describe("sse.reconnect_delay", function()
  it("returns ~1000ms for attempt 1 (with ±20% jitter)", function()
    local delay = sse.reconnect_delay(1)
    assert.is_true(delay >= 800 and delay <= 1200,
      "attempt 1 should be ~1000ms ±20%, got " .. delay)
  end)

  it("doubles base for each successive attempt within jitter range", function()
    for attempt = 1, 5 do
      local expected_base = 1000 * (2 ^ (attempt - 1))
      local lo = expected_base * 0.8
      local hi = expected_base * 1.2
      for _ = 1, 20 do
        local delay = sse.reconnect_delay(attempt)
        assert.is_true(delay >= lo and delay <= hi,
          string.format("attempt %d: expected [%d,%d], got %d", attempt, lo, hi, delay))
      end
    end
  end)

  it("caps at 32000ms base (attempt 6+)", function()
    for _ = 1, 20 do
      local delay = sse.reconnect_delay(10)
      assert.is_true(delay >= 25600 and delay <= 38400,
        "capped delay should be ~32000 ±20%, got " .. delay)
    end
  end)

  it("is not fully deterministic (jitter produces variation)", function()
    local delays = {}
    for _ = 1, 10 do
      table.insert(delays, sse.reconnect_delay(3))
    end
    local all_same = true
    for i = 2, #delays do
      if delays[i] ~= delays[1] then all_same = false; break end
    end
    assert.is_false(all_same, "10 calls should produce at least some variation with jitter")
  end)
end)

-- ─── connection_status: attempt → status string ──────────────────────────────

describe("sse.connection_status", function()
  it("returns 'reconnecting' for attempts 1-4", function()
    for attempt = 1, 4 do
      assert.are.equal("reconnecting", sse.connection_status(attempt),
        "attempt " .. attempt .. " should be reconnecting")
    end
  end)

  it("returns 'disconnected' for attempt 5+", function()
    for _, attempt in ipairs({5, 6, 10, 100}) do
      assert.are.equal("disconnected", sse.connection_status(attempt),
        "attempt " .. attempt .. " should be disconnected")
    end
  end)

  it("returns 'connected' for attempt 0", function()
    assert.are.equal("connected", sse.connection_status(0))
  end)
end)

-- ─── session event classification ────────────────────────────────────────────

describe("sse.classify_event session events", function()
  it("classifies session event type", function()
    local result = sse.classify_event({ type = "session", data = '{"type":"warmup_context_snapshot"}' })
    assert.are.equal("session_event", result.action)
  end)

  it("full round-trip: parse + classify session event", function()
    local chunk = 'event: session\ndata: {"type":"hotreload_snapshot","watchedFiles":["a.fs"]}\n\n'
    local events = sse.parse_chunk(chunk)
    assert.are.equal(1, #events)
    local classified = sse.classify_event(events[1])
    assert.are.equal("session_event", classified.action)
    assert.truthy(classified.data:find("hotreload_snapshot"))
  end)

  it("parses warmup_context_snapshot session event", function()
    local chunk = 'event: session\ndata: {"type":"warmup_context_snapshot","context":{"assemblies":["A.dll"]}}\n\n'
    local events = sse.parse_chunk(chunk)
    assert.are.equal(1, #events)
    assert.are.equal("session", events[1].type)
    local data = vim.json.decode(events[1].data)
    assert.are.equal("warmup_context_snapshot", data.type)
    assert.are.equal("A.dll", data.context.assemblies[1])
  end)
end)
