-- =============================================================================
-- R10 RED Tests — Panel bug fixes, observability, type hints
-- =============================================================================
-- TDD: All tests written RED first, verified failing, then made GREEN.
-- Panel findings: concurrent eval race, reconnect nuclear wipe, shadow
-- dead code, unbounded glob, timer teardown, stats, type hints.
-- =============================================================================

require("spec.helper")
local model = require("sagefs.model")
local format = require("sagefs.format")

-- ─── Bug #3: Concurrent Eval Protection ─────────────────────────────────────
-- Panel (Muratori): Double-mash <A-CR> fires two HTTP requests for same cell.
-- The model should expose is_running() so callers can guard against this.

describe("model — concurrent eval guard", function()
  it("get_cell_state returns running for in-flight cell", function()
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    local state = model.get_cell_state(m, 1)
    assert.are.equal("running", state.status)
  end)

  it("is_cell_running returns true when cell is running", function()
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    assert.is_true(model.is_cell_running(m, 1))
  end)

  it("is_cell_running returns false for idle cell", function()
    local m = model.new()
    assert.is_false(model.is_cell_running(m, 1))
  end)

  it("is_cell_running returns false after success", function()
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    m = model.set_cell_state(m, 1, "success", "done")
    assert.is_false(model.is_cell_running(m, 1))
  end)
end)

-- ─── Bug #1: Shadow Warnings — end_line in model ────────────────────────────
-- Panel (Muratori): show_shadow_warnings references cell.end_line which
-- doesn't exist. Thread end_line through metadata in set_cell_state.

describe("model — end_line metadata", function()
  it("stores end_line from metadata", function()
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    m = model.set_cell_state(m, 1, "success", "output", {
      duration_ms = 42,
      end_line = 15,
    })
    local cell = model.get_cell_state(m, 1)
    assert.are.equal(15, cell.end_line)
  end)

  it("end_line defaults to nil when not provided", function()
    local m = model.new()
    m = model.set_cell_state(m, 1, "running")
    m = model.set_cell_state(m, 1, "success", "output", { duration_ms = 10 })
    local cell = model.get_cell_state(m, 1)
    assert.is_nil(cell.end_line)
  end)
end)

-- ─── Bug #2: Reconnect — generation counter model ───────────────────────────
-- Panel (Stannard/Miller): reconnect should mark state as unconfirmed with
-- a generation counter, then sweep unconfirmed after timeout.
-- Test the pure model side: mark_reconnecting + sweep_unconfirmed.

describe("model — reconnect generation tracking", function()
  it("stores reconnect_gen on model", function()
    local m = model.new()
    m = model.set_reconnect_gen(m, 1)
    assert.are.equal(1, m.reconnect_gen)
  end)

  it("increments reconnect_gen on successive reconnects", function()
    local m = model.new()
    m = model.set_reconnect_gen(m, 1)
    m = model.set_reconnect_gen(m, 2)
    assert.are.equal(2, m.reconnect_gen)
  end)
end)

-- ─── Stats / Observability ──────────────────────────────────────────────────
-- Panel (Carmack): Track eval count, latency, SSE events, reconnects,
-- render skips. Pure model addition.

describe("model — stats tracking", function()
  it("new model has zeroed stats", function()
    local m = model.new()
    assert.is_not_nil(m.stats)
    assert.are.equal(0, m.stats.eval_count)
    assert.are.equal(0, m.stats.eval_latency_sum_ms)
    assert.are.equal(0, m.stats.sse_events_total)
    assert.are.equal(0, m.stats.reconnect_count)
  end)

  it("record_eval increments count and accumulates latency", function()
    local m = model.new()
    m = model.record_eval(m, 42)
    assert.are.equal(1, m.stats.eval_count)
    assert.are.equal(42, m.stats.eval_latency_sum_ms)
    m = model.record_eval(m, 58)
    assert.are.equal(2, m.stats.eval_count)
    assert.are.equal(100, m.stats.eval_latency_sum_ms)
  end)

  it("record_sse_events increments by batch size", function()
    local m = model.new()
    m = model.record_sse_events(m, 5)
    assert.are.equal(5, m.stats.sse_events_total)
    m = model.record_sse_events(m, 3)
    assert.are.equal(8, m.stats.sse_events_total)
  end)

  it("record_reconnect increments reconnect count", function()
    local m = model.new()
    m = model.record_reconnect(m)
    assert.are.equal(1, m.stats.reconnect_count)
    m = model.record_reconnect(m)
    assert.are.equal(2, m.stats.reconnect_count)
  end)

  it("eval_latency_avg returns average or nil", function()
    local m = model.new()
    assert.is_nil(model.eval_latency_avg(m))
    m = model.record_eval(m, 40)
    m = model.record_eval(m, 60)
    assert.are.equal(50, model.eval_latency_avg(m))
  end)
end)

-- ─── Type Hint Extraction (format.lua) ──────────────────────────────────────
-- Panel (Syme/Wlaschin): Parse FSI "val x : int" lines to show type hints.

describe("format — type signature extraction", function()
  it("extracts simple type from val binding", function()
    local sigs = format.extract_type_signatures("val x: int")
    assert.are.equal(1, #sigs)
    assert.are.equal("x", sigs[1].name)
    assert.are.equal("int", sigs[1].type_sig)
  end)

  it("extracts function type", function()
    local sigs = format.extract_type_signatures("val greet: name: string -> string")
    assert.are.equal(1, #sigs)
    assert.are.equal("greet", sigs[1].name)
    assert.are.equal("name: string -> string", sigs[1].type_sig)
  end)

  it("extracts type from 'val x : int = 42'", function()
    local sigs = format.extract_type_signatures("val x: int = 42")
    assert.are.equal(1, #sigs)
    assert.are.equal("x", sigs[1].name)
    assert.are.equal("int", sigs[1].type_sig)
  end)

  it("extracts multiple bindings", function()
    local output = "val x: int = 42\nval y: string = \"hello\""
    local sigs = format.extract_type_signatures(output)
    assert.are.equal(2, #sigs)
    assert.are.equal("x", sigs[1].name)
    assert.are.equal("y", sigs[2].name)
  end)

  it("returns empty for non-binding output", function()
    local sigs = format.extract_type_signatures("Hello, world!")
    assert.are.equal(0, #sigs)
  end)

  it("returns empty for nil", function()
    local sigs = format.extract_type_signatures(nil)
    assert.are.equal(0, #sigs)
  end)

  it("skips mutable and it bindings", function()
    local sigs = format.extract_type_signatures("val mutable x: int\nval it: unit")
    assert.are.equal(0, #sigs)
  end)
end)

-- ─── Bug #4: Unbounded glob exclusion patterns ──────────────────────────────
-- Panel (Primeagen/Fluery): discover_and_create does unbounded **/*.fsproj.
-- Test that exclusion patterns filter correctly (pure function).

describe("format — glob exclusion filtering", function()
  it("filters paths containing node_modules", function()
    local paths = {
      "src/MyApp/MyApp.fsproj",
      "node_modules/SomePkg/SomePkg.fsproj",
      "tests/Tests.fsproj",
    }
    local filtered = format.filter_excluded_paths(paths)
    assert.are.equal(2, #filtered)
    assert.are.equal("src/MyApp/MyApp.fsproj", filtered[1])
    assert.are.equal("tests/Tests.fsproj", filtered[2])
  end)

  it("filters paths containing bin or obj", function()
    local paths = {
      "src/App.fsproj",
      "src/bin/Debug/App.fsproj",
      "src/obj/Release/App.fsproj",
    }
    local filtered = format.filter_excluded_paths(paths)
    assert.are.equal(1, #filtered)
  end)

  it("filters .git and .nuget paths", function()
    local paths = {
      "MyApp.fsproj",
      ".git/hooks/pre-commit.fsproj",
      ".nuget/packages/Foo/Foo.fsproj",
    }
    local filtered = format.filter_excluded_paths(paths)
    assert.are.equal(1, #filtered)
    assert.are.equal("MyApp.fsproj", filtered[1])
  end)

  it("returns empty for all-excluded input", function()
    local paths = {
      "node_modules/A.fsproj",
      "bin/B.fsproj",
    }
    local filtered = format.filter_excluded_paths(paths)
    assert.are.equal(0, #filtered)
  end)

  it("returns empty for empty input", function()
    local filtered = format.filter_excluded_paths({})
    assert.are.equal(0, #filtered)
  end)
end)
