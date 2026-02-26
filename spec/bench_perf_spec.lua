-- =============================================================================
-- Performance Benchmarks — Measure actual impact of optimizations
-- =============================================================================
-- These benchmarks use realistic data sizes (500-2000 tests across 50 files)
-- to measure the before/after impact of each optimization. Each benchmark
-- compares the old approach vs the new approach with wall-clock timing.
-- =============================================================================

local testing = require("sagefs.testing")
local annotations = require("sagefs.annotations")
local coverage = require("sagefs.coverage")

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function make_origin(file, line)
  return { Case = "SourceMapped", Fields = { file, line } }
end

--- Create a realistic testing state with N tests across F files
local function make_large_state(num_tests, num_files)
  local s = testing.new()
  local statuses = { "Passed", "Failed", "Stale", "Running", "Detected" }
  for i = 1, num_tests do
    local file_idx = ((i - 1) % num_files) + 1
    local file = "/src/file_" .. file_idx .. ".fs"
    local status = statuses[((i - 1) % #statuses) + 1]
    s = testing.update_test(s, {
      testId = "test_" .. i,
      displayName = "Test number " .. i,
      origin = make_origin(file, i),
      status = status,
    })
  end
  return s
end

--- Benchmark a function: run it N times, return total and per-call time in microseconds
local function bench(name, iterations, fn)
  -- Warm up
  for _ = 1, math.min(10, iterations) do fn() end

  local clock = os.clock
  local start = clock()
  for _ = 1, iterations do
    fn()
  end
  local elapsed = clock() - start
  local per_call_us = (elapsed / iterations) * 1e6
  local total_ms = elapsed * 1000
  return {
    name = name,
    iterations = iterations,
    total_ms = total_ms,
    per_call_us = per_call_us,
  }
end

--- Print benchmark result
local function report(result)
  return string.format("  %-50s %8.1f µs/call  (%d iters, %.1f ms total)",
    result.name, result.per_call_us, result.iterations, result.total_ms)
end

-- ─── Benchmark: filter_by_file — O(n) full scan vs O(k) file index ──────────

describe("BENCH: filter_by_file", function()
  it("O(k) file index vs O(n) full scan with 1000 tests / 50 files", function()
    local s = make_large_state(1000, 50)
    local target_file = "/src/file_25.fs"
    local iters = 5000

    -- New approach: uses _file_index (O(k) where k = tests in file ≈ 20)
    local new_result = bench("filter_by_file [NEW: _file_index O(k)]", iters, function()
      testing.filter_by_file(s, target_file)
    end)

    -- Old approach: linear scan all tests (simulate by temporarily clearing index)
    local saved_index = s._file_index
    s._file_index = nil
    -- Old filter_by_file would iterate all 1000 tests
    local old_result = bench("filter_by_file [OLD: full scan O(n)]", iters, function()
      local results = {}
      for id, test in pairs(s.tests) do
        if test.file == target_file then
          local entry = {}
          for k, v in pairs(test) do entry[k] = v end
          entry.testId = id
          table.insert(results, entry)
        end
      end
    end)
    s._file_index = saved_index

    local speedup = old_result.per_call_us / new_result.per_call_us

    print("\n" .. string.rep("─", 80))
    print("  filter_by_file — 1000 tests across 50 files, querying 1 file (~20 tests)")
    print(string.rep("─", 80))
    print(report(old_result))
    print(report(new_result))
    print(string.format("  >> Speedup: %.1fx", speedup))
    print(string.rep("─", 80))

    -- The indexed version should be faster
    assert.is_true(speedup > 1.0,
      string.format("Expected speedup > 1.0x, got %.1fx", speedup))
  end)
end)

-- ─── Benchmark: to_diagnostics — O(n) full scan vs O(k) file index ──────────

describe("BENCH: to_diagnostics", function()
  it("O(k) file index vs O(n) full scan with 1000 tests / 50 files", function()
    local s = make_large_state(1000, 50)
    local target_file = "/src/file_25.fs"
    -- Make some tests in that file Failed so diagnostics appear
    for id in pairs(s._file_index[target_file] or {}) do
      s.tests[id].status = "Failed"
      s.tests[id].output = "Expected true but got false"
    end
    local iters = 5000

    local new_result = bench("to_diagnostics [NEW: _file_index O(k)]", iters, function()
      testing.to_diagnostics(s, target_file)
    end)

    -- Old approach: linear scan
    local saved_index = s._file_index
    s._file_index = nil
    local old_result = bench("to_diagnostics [OLD: full scan O(n)]", iters, function()
      local diags = {}
      for _, test in pairs(s.tests) do
        if test.status == "Failed" and test.file == target_file then
          table.insert(diags, {
            lnum = (test.line or 1) - 1,
            col = 0,
            severity = 1,
            message = test.displayName or "test failed",
            source = "sagefs_tests",
          })
        end
      end
    end)
    s._file_index = saved_index

    local speedup = old_result.per_call_us / new_result.per_call_us

    print("\n" .. string.rep("─", 80))
    print("  to_diagnostics — 1000 tests across 50 files, querying 1 file (~20 tests)")
    print(string.rep("─", 80))
    print(report(old_result))
    print(report(new_result))
    print(string.format("  >> Speedup: %.1fx", speedup))
    print(string.rep("─", 80))

    assert.is_true(speedup > 1.0,
      string.format("Expected speedup > 1.0x, got %.1fx", speedup))
  end)
end)

-- ─── Benchmark: annotations_for_file — O(n) vs O(k) ─────────────────────────

describe("BENCH: annotations_for_file", function()
  it("O(k) file index vs O(n) full scan with 1000 tests / 50 files", function()
    local s = make_large_state(1000, 50)
    local target_file = "/src/file_25.fs"
    local iters = 5000

    local new_result = bench("annotations_for_file [NEW: _file_index O(k)]", iters, function()
      testing.annotations_for_file(s, target_file)
    end)

    -- Old approach: linear scan
    local old_result = bench("annotations_for_file [OLD: full scan O(n)]", iters, function()
      local anns = {}
      for _, test in pairs(s.tests) do
        if test.file == target_file then
          table.insert(anns, {
            line = test.line or 1,
            icon = "TestPassed",
            tooltip = string.format("%s: %s", test.status or "Unknown", test.displayName or ""),
          })
        end
      end
      table.sort(anns, function(a, b) return a.line < b.line end)
    end)

    local speedup = old_result.per_call_us / new_result.per_call_us

    print("\n" .. string.rep("─", 80))
    print("  annotations_for_file — 1000 tests across 50 files")
    print(string.rep("─", 80))
    print(report(old_result))
    print(report(new_result))
    print(string.format("  >> Speedup: %.1fx", speedup))
    print(string.rep("─", 80))

    assert.is_true(speedup > 1.0,
      string.format("Expected speedup > 1.0x, got %.1fx", speedup))
  end)
end)

-- ─── Benchmark: version check (render skip) ─────────────────────────────────

describe("BENCH: version-based render skip", function()
  it("measures cost of version check vs full render-cycle work", function()
    local s = make_large_state(500, 25)
    local target_file = "/src/file_12.fs"
    local iters = 5000

    -- Simulate render skip check (the fast path — nothing changed)
    local last_v = s._version
    local skip_result = bench("version check [skip: nothing changed]", iters, function()
      if s._version == last_v then
        return true -- Skip!
      end
      return false
    end)

    -- Simulate what a full render does: filter + diagnostics + summary
    local render_result = bench("full render cycle [filter+diags+summary]", iters, function()
      testing.filter_by_file(s, target_file)
      testing.to_diagnostics(s, target_file)
      testing.compute_summary(s)
    end)

    local ratio = render_result.per_call_us / math.max(skip_result.per_call_us, 0.001)

    print("\n" .. string.rep("─", 80))
    print("  Version skip vs full render cycle — 500 tests, 25 files")
    print(string.rep("─", 80))
    print(report(skip_result))
    print(report(render_result))
    print(string.format("  >> Render avoidance ratio: %.0fx (each skipped render saves %.1f µs)",
      ratio, render_result.per_call_us))
    print(string.rep("─", 80))

    -- Full render cycle should be meaningfully more expensive than version check
    assert.is_true(render_result.per_call_us > skip_result.per_call_us,
      "Full render should be more expensive than version check")
  end)
end)

-- ─── Benchmark: table reuse vs allocation ────────────────────────────────────

describe("BENCH: table reuse (Nu cached-collections)", function()
  it("measures reuse-and-wipe vs allocate-new for freshness_by_line", function()
    local iters = 50000
    local num_entries = 50

    -- New: reuse table, wipe with loop
    local cached = {}
    local reuse_result = bench("freshness_by_line [NEW: reuse + wipe]", iters, function()
      for k in pairs(cached) do cached[k] = nil end
      for i = 1, num_entries do
        cached[i] = "Passed"
      end
    end)

    -- Old: allocate new table each time
    local alloc_result = bench("freshness_by_line [OLD: allocate {}]", iters, function()
      local t = {}
      for i = 1, num_entries do
        t[i] = "Passed"
      end
    end)

    local ratio = alloc_result.per_call_us / reuse_result.per_call_us

    print("\n" .. string.rep("─", 80))
    print("  Table reuse vs allocation — 50 entries per render")
    print(string.rep("─", 80))
    print(report(alloc_result))
    print(report(reuse_result))
    print(string.format("  >> Ratio: %.2fx", ratio))
    print(string.rep("─", 80))

    -- Table reuse should be at least comparable (may be marginal in LuaJIT)
    -- The real win is GC pressure reduction, not raw speed
    assert.is_true(ratio > 0.5,
      "Table reuse should not be significantly slower than allocation")
  end)
end)

-- ─── Benchmark: update_test with file index maintenance ──────────────────────

describe("BENCH: update_test overhead", function()
  it("measures file index maintenance cost per update", function()
    local iters = 10000

    -- With file index (current implementation)
    local with_index = bench("update_test [with _file_index]", iters, function()
      local s = testing.new()
      for i = 1, 20 do
        testing.update_test(s, {
          testId = "t" .. i,
          displayName = "test " .. i,
          origin = make_origin("/src/file.fs", i),
          status = "Passed",
        })
      end
    end)

    print("\n" .. string.rep("─", 80))
    print("  update_test overhead — 20 updates per batch")
    print(string.rep("─", 80))
    print(report(with_index))
    print(string.format("  >> Per-update: %.1f µs (index maintenance included)",
      with_index.per_call_us / 20))
    print(string.rep("─", 80))

    -- Each update should be fast (<50µs)
    assert.is_true(with_index.per_call_us / 20 < 50,
      "Per-update cost should be under 50µs")
  end)
end)

-- ─── Benchmark: handle_results_batch (realistic SSE event) ──────────────────

describe("BENCH: handle_results_batch", function()
  it("measures batch processing time for 500-result SSE event", function()
    local num_results = 500
    local iters = 500

    -- Pre-discover tests
    local s = make_large_state(num_results, 25)

    -- Build a batch payload
    local entries = {}
    for i = 1, num_results do
      table.insert(entries, {
        TestId = "test_" .. i,
        DisplayName = "Test " .. i,
        Status = { Case = i % 5 == 0 and "Failed" or "Passed", Fields = { "00:00:00.012" } },
        Origin = { Case = "SourceMapped", Fields = { "/src/file_" .. (((i-1) % 25) + 1) .. ".fs", i } },
      })
    end
    local batch = {
      Entries = entries,
      Summary = { Total = 500, Passed = 400, Failed = 100, Stale = 0, Running = 0, Disabled = 0 },
      Generation = 42,
    }

    local result = bench("handle_results_batch [500 results]", iters, function()
      -- Reset state to avoid accumulating
      s._version = 0
      testing.handle_results_batch(s, batch)
    end)

    print("\n" .. string.rep("─", 80))
    print("  handle_results_batch — 500 test results in one SSE event")
    print(string.rep("─", 80))
    print(report(result))
    print(string.format("  >> Per-result: %.1f µs", result.per_call_us / num_results))
    print(string.rep("─", 80))

    -- Batch of 500 should process in under 5ms
    assert.is_true(result.per_call_us < 5000,
      string.format("500-result batch should be under 5ms, got %.0f µs", result.per_call_us))
  end)
end)

-- ─── Scale test: filter_by_file at different test counts ─────────────────────

describe("BENCH: scaling", function()
  it("shows filter_by_file scales with tests-per-file, not total tests", function()
    -- Key insight: with fixed file count, more total tests = more per file.
    -- True O(k) test: keep target file's test count constant, vary OTHER files' tests.
    local target_file = "/src/target.fs"
    local tests_in_target = 20
    local iters = 2000

    print("\n" .. string.rep("─", 80))
    print("  filter_by_file scaling — target file always has 20 tests")
    print(string.rep("─", 80))

    local times = {}
    for _, extra in ipairs({ 0, 500, 1000, 2000 }) do
      local s = testing.new()
      -- Add fixed tests to target file
      for i = 1, tests_in_target do
        s = testing.update_test(s, {
          testId = "target_" .. i,
          displayName = "Target test " .. i,
          origin = make_origin(target_file, i),
          status = "Passed",
        })
      end
      -- Add extra tests to OTHER files
      for i = 1, extra do
        s = testing.update_test(s, {
          testId = "other_" .. i,
          displayName = "Other test " .. i,
          origin = make_origin("/src/other_" .. (i % 50) .. ".fs", i),
          status = "Passed",
        })
      end
      local total = tests_in_target + extra
      local r = bench(string.format("  %d total tests (target=20)", total), iters, function()
        testing.filter_by_file(s, target_file)
      end)
      table.insert(times, r.per_call_us)
      print(report(r))
    end
    print(string.rep("─", 80))

    -- With file index, adding tests to OTHER files should NOT slow down
    -- querying the target file. Ratio of 2020-test to 20-test should be ~1.0x
    local ratio = times[#times] / times[1]
    print(string.format("  >> Scaling factor (20→2020 total tests, same 20 in target): %.2fx", ratio))
    print("     (ideal: 1.0x — query time depends on target file only)")
    assert.is_true(ratio < 3.0,
      string.format("Expected near-constant scaling, got %.1fx", ratio))
  end)
end)
