-- sse_pipeline_spec.lua — End-to-end tests for SSE → testing state → UI
-- Tests the FULL pipeline: raw SSE text → parse → classify → handler → state → format
-- Uses realistic SageFs payloads (PascalCase, F# DU shapes) to catch mismatches

require("spec.helper")
local sse = require("sagefs.sse")
local testing = require("sagefs.testing")
local json = require("dkjson")

-- ─── Realistic SageFs payloads (matches F# types exactly) ──────────────────

-- TestStatusEntry as SageFs serializes it (PascalCase, Origin DU, etc.)
local function make_sagefs_entry(opts)
  return {
    TestId = opts.id or "test-1",
    DisplayName = opts.name or "should work",
    FullName = opts.fullName or "Module.should work",
    Origin = opts.origin or { Case = "SourceMapped", Fields = { "src/Tests.fs", opts.line or 10 } },
    Framework = opts.framework or "Expecto",
    Category = opts.category or "Unit",
    CurrentPolicy = opts.policy or "OnEveryChange",
    Status = opts.status or "Passed",
    PreviousStatus = opts.prevStatus or "Running",
  }
end

-- TestResultsBatchPayload as SageFs serializes it
local function make_sagefs_batch(entries, summary_overrides)
  local total = #entries
  local passed, failed = 0, 0
  for _, e in ipairs(entries) do
    if e.Status == "Passed" then passed = passed + 1 end
    if e.Status == "Failed" then failed = failed + 1 end
  end
  return {
    Generation = { Case = "RunGeneration", Fields = { 1 } },
    Freshness = { Case = "Fresh" },
    Completion = { Case = "Complete" },
    Entries = entries,
    Summary = {
      Total = summary_overrides and summary_overrides.Total or total,
      Passed = summary_overrides and summary_overrides.Passed or passed,
      Failed = summary_overrides and summary_overrides.Failed or failed,
      Stale = summary_overrides and summary_overrides.Stale or 0,
      Running = summary_overrides and summary_overrides.Running or 0,
      Disabled = summary_overrides and summary_overrides.Disabled or 0,
    },
  }
end

-- Build a raw SSE chunk string (as curl would emit)
local function make_sse_chunk(event_type, data_table)
  local data_json = json.encode(data_table)
  return "event: " .. event_type .. "\ndata: " .. data_json .. "\n\n"
end

-- =============================================================================
-- Full pipeline: SSE text → parse → classify → testing state → format_test_list
-- =============================================================================

describe("SSE pipeline: test_results_batch → panel display", function()
  it("populates state.tests from a realistic SageFs batch", function()
    local batch = make_sagefs_batch({
      make_sagefs_entry({ id = "t1", name = "should add", status = "Passed", line = 10 }),
      make_sagefs_entry({ id = "t2", name = "should fail", status = "Failed", line = 20 }),
    })

    local state = testing.new()
    state = testing.handle_results_batch(state, batch)

    assert.are.equal(2, testing.test_count(state))
    assert.is_not_nil(state.tests["t1"])
    assert.is_not_nil(state.tests["t2"])
    assert.are.equal("Passed", state.tests["t1"].status)
    assert.are.equal("Failed", state.tests["t2"].status)
  end)

  it("normalize_entry converts PascalCase TestStatusEntry to camelCase", function()
    local entry = make_sagefs_entry({ id = "t1", name = "pascal test", status = "Passed" })
    local norm = testing.normalize_entry(entry)

    assert.are.equal("t1", norm.testId)
    assert.are.equal("pascal test", norm.displayName)
    assert.are.equal("Passed", norm.status)
    assert.are.equal("OnEveryChange", norm.currentPolicy)
    assert.is_table(norm.origin)
    assert.are.equal("SourceMapped", norm.origin.Case)
  end)

  it("update_test extracts file/line from Origin DU", function()
    local state = testing.new()
    local entry = testing.normalize_entry(
      make_sagefs_entry({ id = "t1", line = 42 })
    )
    testing.update_test(state, entry)

    assert.are.equal("src/Tests.fs", state.tests["t1"].file)
    assert.are.equal(42, state.tests["t1"].line)
  end)

  it("format_test_list shows tests populated from PascalCase batch", function()
    local batch = make_sagefs_batch({
      make_sagefs_entry({ id = "t1", name = "should add", status = "Passed" }),
      make_sagefs_entry({ id = "t2", name = "should subtract", status = "Failed" }),
      make_sagefs_entry({ id = "t3", name = "should multiply", status = "Running" }),
    })

    local state = testing.new()
    state = testing.set_enabled(state, true)
    state = testing.handle_results_batch(state, batch)

    local lines = testing.format_test_list(state)
    assert.is_true(#lines >= 3, "expected at least 3 lines, got " .. #lines)

    -- Check each test appears in the output
    local found = { add = false, subtract = false, multiply = false }
    for _, line in ipairs(lines) do
      if line:find("should add") then found.add = true end
      if line:find("should subtract") then found.subtract = true end
      if line:find("should multiply") then found.multiply = true end
    end
    assert.is_true(found.add, "should add not found in panel")
    assert.is_true(found.subtract, "should subtract not found in panel")
    assert.is_true(found.multiply, "should multiply not found in panel")
  end)

  it("summary is updated from PascalCase batch Summary", function()
    local batch = make_sagefs_batch({
      make_sagefs_entry({ id = "t1", status = "Passed" }),
    }, { Total = 5, Passed = 4, Failed = 1, Stale = 0, Running = 0, Disabled = 0 })

    local state = testing.new()
    state = testing.handle_results_batch(state, batch)

    assert.are.equal(5, state.summary.total)
    assert.are.equal(4, state.summary.passed)
    assert.are.equal(1, state.summary.failed)
  end)

  it("generation/freshness/completion are parsed from F# DU shapes", function()
    local batch = make_sagefs_batch({
      make_sagefs_entry({ id = "t1", status = "Passed" }),
    })

    local state = testing.new()
    state = testing.handle_results_batch(state, batch)

    assert.are.equal(1, state.generation)
    assert.are.equal("Fresh", state.freshness)
    assert.are.equal("Complete", state.completion)
  end)
end)

-- =============================================================================
-- Full pipeline: raw SSE text → parse_chunk → classify → handler
-- =============================================================================

describe("SSE pipeline: raw text → parsed events", function()
  it("parse_chunk extracts typed SSE event from raw curl output", function()
    local batch = make_sagefs_batch({
      make_sagefs_entry({ id = "t1", name = "test one", status = "Passed" }),
    })
    local raw = make_sse_chunk("test_results_batch", batch)

    local events, remainder = sse.parse_chunk(raw)
    assert.are.equal(1, #events)
    assert.are.equal("test_results_batch", events[1].type)
    assert.is_string(events[1].data)
  end)

  it("classify_event maps snake_case typed SSE events correctly", function()
    -- These are the new typed SSE events SageFs sends (not Elm PascalCase)
    local cases = {
      { type = "test_results_batch", expected = "test_results_batch" },
      { type = "test_summary", expected = "test_summary" },
      { type = "test_run_started", expected = "test_run_started" },
      { type = "test_run_completed", expected = "test_run_completed" },
      { type = "tests_discovered", expected = "tests_discovered" },
      { type = "live_testing_toggled", expected = "live_testing_toggled" },
    }
    for _, c in ipairs(cases) do
      local result = sse.classify_event({ type = c.type, data = "{}" })
      assert.is_not_nil(result, "classify_event returned nil for " .. c.type)
      assert.are.equal(c.expected, result.action,
        "wrong action for event type: " .. c.type)
    end
  end)

  it("full SSE text → state: parse + classify + dispatch + handle", function()
    local batch = make_sagefs_batch({
      make_sagefs_entry({ id = "t1", name = "real test", status = "Passed", line = 15 }),
      make_sagefs_entry({ id = "t2", name = "broken test", status = "Failed", line = 30 }),
    })
    local raw = make_sse_chunk("test_results_batch", batch)

    -- Step 1: Parse
    local events, _ = sse.parse_chunk(raw)
    assert.are.equal(1, #events)

    -- Step 2: Classify
    local classified = sse.classify_event(events[1])
    assert.are.equal("test_results_batch", classified.action)

    -- Step 3: Decode JSON data (classify_event returns {action, data=json_string})
    local ok, data = pcall(vim.json.decode, classified.data)
    assert.is_true(ok, "JSON decode failed")

    -- Step 4: Handle
    local state = testing.new()
    state = testing.handle_results_batch(state, data)

    -- Step 5: Verify state
    assert.are.equal(2, testing.test_count(state))
    assert.are.equal("Passed", state.tests["t1"].status)
    assert.are.equal("Failed", state.tests["t2"].status)
    assert.are.equal("src/Tests.fs", state.tests["t1"].file)
    assert.are.equal(15, state.tests["t1"].line)

    -- Step 6: Panel should show both
    state.enabled = true
    local lines = testing.format_test_list(state)
    assert.is_true(#lines >= 2, "panel should show at least 2 tests")
  end)
end)

-- =============================================================================
-- Edge case: empty state → panel display
-- =============================================================================

describe("SSE pipeline: empty/missing data edge cases", function()
  it("format_test_list returns empty list when no tests exist", function()
    local state = testing.new()
    local lines = testing.format_test_list(state)
    assert.is_table(lines)
    assert.are.equal(0, #lines)
  end)

  it("handle_results_batch with nil data does not crash", function()
    local state = testing.new()
    assert.has_no.errors(function()
      state = testing.handle_results_batch(state, nil)
    end)
    assert.are.equal(0, testing.test_count(state))
  end)

  it("handle_results_batch with empty Entries does not crash", function()
    local state = testing.new()
    local batch = make_sagefs_batch({})
    assert.has_no.errors(function()
      state = testing.handle_results_batch(state, batch)
    end)
    assert.are.equal(0, testing.test_count(state))
  end)

  it("handle_test_summary with nil does not crash", function()
    local state = testing.new()
    assert.has_no.errors(function()
      state = testing.handle_test_summary(state, nil)
    end)
  end)

  it("normalize_entry with nil returns nil", function()
    local result = testing.normalize_entry(nil)
    assert.is_nil(result)
  end)

  it("normalize_entry with already-camelCase entry returns unchanged", function()
    local entry = { testId = "t1", displayName = "test", status = "Passed" }
    local result = testing.normalize_entry(entry)
    assert.are.equal("t1", result.testId)
  end)
end)

-- =============================================================================
-- Rapid burst: many batches in sequence (simulates SSE flood after save)
-- =============================================================================

describe("SSE pipeline: rapid burst does not corrupt state", function()
  it("100 sequential batches produce correct final state", function()
    local state = testing.new()
    state = testing.set_enabled(state, true)

    -- Simulate 100 rapid-fire batches (as SageFs sends during test run)
    for i = 1, 100 do
      local status = (i % 2 == 0) and "Passed" or "Running"
      local batch = make_sagefs_batch({
        make_sagefs_entry({ id = "t1", name = "test one", status = status }),
        make_sagefs_entry({ id = "t2", name = "test two", status = status }),
      })
      state = testing.handle_results_batch(state, batch)
    end

    -- After 100 batches, final state is from last batch (even i=100 → Passed)
    assert.are.equal(2, testing.test_count(state))
    assert.are.equal("Passed", state.tests["t1"].status)
    assert.are.equal("Passed", state.tests["t2"].status)
  end)

  it("interleaved run_started + results_batch produces correct lifecycle", function()
    local state = testing.new()
    state = testing.set_enabled(state, true)

    -- Discovery
    testing.update_test(state, {
      testId = "t1", displayName = "test", fullName = "M.test",
      origin = { Case = "SourceMapped", Fields = { "src/Tests.fs", 10 } },
      category = "Unit", currentPolicy = "OnEveryChange", status = "Detected",
    })
    assert.are.equal("Detected", state.tests["t1"].status)

    -- Run started
    state = testing.handle_test_run_started(state, { testIds = { "t1" } })
    assert.are.equal("Running", state.tests["t1"].status)

    -- Results batch
    local batch = make_sagefs_batch({
      make_sagefs_entry({ id = "t1", name = "test", status = "Passed" }),
    })
    state = testing.handle_results_batch(state, batch)
    assert.are.equal("Passed", state.tests["t1"].status)

    -- Panel shows the result
    local lines = testing.format_test_list(state)
    assert.is_true(#lines >= 1)
    local found = false
    for _, l in ipairs(lines) do
      if l:find("test") and l:find("✓") then found = true end
    end
    assert.is_true(found, "panel should show passed test with ✓")
  end)
end)

-- =============================================================================
-- test_summary SSE event (standalone, not inside batch)
-- =============================================================================

describe("SSE pipeline: test_summary typed event", function()
  it("handle_test_summary parses PascalCase summary", function()
    local state = testing.new()
    local summary_data = {
      Total = 42,
      Passed = 40,
      Failed = 2,
      Stale = 0,
      Running = 0,
      Disabled = 0,
    }
    state = testing.handle_test_summary(state, summary_data)

    assert.are.equal(42, state.summary.total)
    assert.are.equal(40, state.summary.passed)
    assert.are.equal(2, state.summary.failed)
    assert.is_false(state.enabled, "summary does not auto-enable")
  end)

  it("handle_test_summary with zero total does not enable", function()
    local state = testing.new()
    state = testing.handle_test_summary(state, {
      Total = 0, Passed = 0, Failed = 0, Stale = 0, Running = 0, Disabled = 0,
    })
    assert.is_false(state.enabled)
  end)

  it("full SSE text → test_summary → state", function()
    local raw = make_sse_chunk("test_summary", {
      Total = 10, Passed = 8, Failed = 2, Stale = 0, Running = 0, Disabled = 0,
    })

    local events, _ = sse.parse_chunk(raw)
    assert.are.equal(1, #events)

    local classified = sse.classify_event(events[1])
    assert.are.equal("test_summary", classified.action)

    local ok, data = pcall(vim.json.decode, classified.data)
    assert.is_true(ok)

    local state = testing.new()
    state = testing.handle_test_summary(state, data)
    assert.are.equal(10, state.summary.total)
    assert.is_false(state.enabled)
  end)
end)

-- =============================================================================
-- Annotations: test signs for gutter
-- =============================================================================

describe("SSE pipeline: annotations from PascalCase batch", function()
  it("annotations_for_file works after PascalCase batch ingest", function()
    local batch = make_sagefs_batch({
      make_sagefs_entry({ id = "t1", name = "test 1", status = "Passed", line = 10 }),
      make_sagefs_entry({ id = "t2", name = "test 2", status = "Failed", line = 20 }),
      make_sagefs_entry({
        id = "t3", name = "other file test", status = "Passed", line = 5,
        origin = { Case = "SourceMapped", Fields = { "src/Other.fs", 5 } },
      }),
    })

    local state = testing.new()
    state = testing.handle_results_batch(state, batch)

    local anns = testing.annotations_for_file(state, "src/Tests.fs")
    assert.are.equal(2, #anns, "should have 2 annotations for Tests.fs")
    -- Sorted by line
    assert.are.equal(10, anns[1].line)
    assert.are.equal(20, anns[2].line)
    assert.are.equal("TestPassed", anns[1].icon)
    assert.are.equal("TestFailed", anns[2].icon)
  end)

  it("to_diagnostics returns failure diagnostics from PascalCase batch", function()
    local batch = make_sagefs_batch({
      make_sagefs_entry({ id = "t1", name = "pass test", status = "Passed", line = 10 }),
      make_sagefs_entry({ id = "t2", name = "fail test", status = "Failed", line = 20 }),
    })

    local state = testing.new()
    state = testing.handle_results_batch(state, batch)

    local diags = testing.to_diagnostics(state, "src/Tests.fs")
    assert.are.equal(1, #diags, "should have 1 diagnostic for the failed test")
    assert.are.equal(19, diags[1].lnum, "lnum should be 0-indexed (line 20 → 19)")
    assert.is_truthy(diags[1].message:find("fail test"))
  end)
end)

-- =============================================================================
-- Multiple SSE events in single chunk (realistic: SageFs sends batches)
-- =============================================================================

describe("SSE pipeline: multiple events in one chunk", function()
  it("parses multiple events from a single SSE chunk", function()
    local batch = make_sagefs_batch({
      make_sagefs_entry({ id = "t1", status = "Passed" }),
    })
    local summary = { Total = 5, Passed = 4, Failed = 1, Stale = 0, Running = 0, Disabled = 0 }

    local raw = make_sse_chunk("test_results_batch", batch)
      .. make_sse_chunk("test_summary", summary)

    local events, _ = sse.parse_chunk(raw)
    assert.are.equal(2, #events)
    assert.are.equal("test_results_batch", events[1].type)
    assert.are.equal("test_summary", events[2].type)
  end)

  it("processes both events through full pipeline", function()
    local batch = make_sagefs_batch({
      make_sagefs_entry({ id = "t1", name = "first", status = "Passed", line = 5 }),
      make_sagefs_entry({ id = "t2", name = "second", status = "Failed", line = 15 }),
    })
    local summary = { Total = 10, Passed = 8, Failed = 2, Stale = 0, Running = 0, Disabled = 0 }

    local raw = make_sse_chunk("test_results_batch", batch)
      .. make_sse_chunk("test_summary", summary)

    local events, _ = sse.parse_chunk(raw)
    local state = testing.new()

    for _, event in ipairs(events) do
      local classified = sse.classify_event(event)
      local ok, data = pcall(vim.json.decode, classified.data)
      if ok then
        if classified.action == "test_results_batch" then
          state = testing.handle_results_batch(state, data)
        elseif classified.action == "test_summary" then
          state = testing.handle_test_summary(state, data)
        end
      end
    end

    assert.are.equal(2, testing.test_count(state))
    assert.are.equal(10, state.summary.total)

    local lines = testing.format_test_list(state)
    assert.is_true(#lines >= 2)
  end)
end)

-- =============================================================================
-- safe_dispatch_batch: handler errors don't crash pipeline
-- =============================================================================

describe("SSE pipeline: safe_dispatch_batch error isolation", function()
  it("bad handler does not prevent other handlers from running", function()
    local good_called = false
    local dt = sse.build_dispatch_table({
      test_results_batch = function() error("intentional explosion") end,
      test_summary = function() good_called = true end,
    })

    local classified = {
      { action = "test_results_batch", data = { data = "{}" } },
      { action = "test_summary", data = { data = "{}" } },
    }

    local errors = sse.safe_dispatch_batch(dt, classified)
    assert.are.equal(1, #errors, "should capture 1 error")
    assert.is_truthy(errors[1].err:find("intentional explosion"))
    assert.is_true(good_called, "test_summary handler should still run")
  end)
end)
