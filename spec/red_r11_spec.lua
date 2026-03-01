-- =============================================================================
-- R11 RED Tests — Panel R11 review: bug fixes, features, utilities
-- =============================================================================
-- TDD: All tests written RED first, verified failing, then made GREEN.
-- Panel findings: record_eval nil guard, type sig dedup, SSE validation,
-- reconnect stat fix, async_all utility, stats dashboard, playground, health.
-- =============================================================================

require("spec.helper")
local model = require("sagefs.model")
local format = require("sagefs.format")
local util = require("sagefs.util")

-- ─── Bug: record_eval nil guard ────────────────────────────────────────────
describe("model.record_eval nil guard", function()
  it("handles nil latency without crashing", function()
    local m = model.new()
    -- Should not error — nil latency treated as 0
    local ok, err = pcall(model.record_eval, m, nil)
    assert.is_true(ok, "record_eval should not crash on nil: " .. tostring(err))
    assert.are.equal(1, m.stats.eval_count)
    assert.are.equal(0, m.stats.eval_latency_sum_ms)
  end)
end)

-- ─── Bug: extract_type_signatures is duplicate of parse_bindings ───────────
describe("format type sig dedup", function()
  it("extract_type_signatures returns same results as parse_bindings", function()
    local output = "val x : int\nval greet : name: string -> string"
    local sigs = format.extract_type_signatures(output)
    local bindings = format.parse_bindings(output)
    assert.are.equal(#bindings, #sigs)
    for i, b in ipairs(bindings) do
      assert.are.equal(b.name, sigs[i].name)
      assert.are.equal(b.type_sig, sigs[i].type_sig)
    end
  end)

  it("extract_type_signatures IS parse_bindings (same function)", function()
    -- After dedup, they should be the same function reference
    assert.are.equal(format.parse_bindings, format.extract_type_signatures)
  end)
end)

-- ─── SSE_HANDLER_DEFS validation ──────────────────────────────────────────
-- This test can't directly test init.lua's SSE_HANDLER_DEFS (they're local),
-- but we test the validation FUNCTION that build_handlers should use.
describe("SSE handler def validation", function()
  it("rejects target without fn", function()
    local defs = { { action = "bad", target = "testing" } }
    local ok, err = pcall(format.validate_handler_defs, defs)
    assert.is_false(ok)
    assert.truthy(tostring(err):match("target without fn"))
  end)

  it("rejects fn without target", function()
    local defs = { { action = "bad", fn = "handle_something" } }
    local ok, err = pcall(format.validate_handler_defs, defs)
    assert.is_false(ok)
    assert.truthy(tostring(err):match("fn without target"))
  end)

  it("rejects entry with no fn and no event", function()
    local defs = { { action = "bad" } }
    local ok, err = pcall(format.validate_handler_defs, defs)
    assert.is_false(ok)
    assert.truthy(tostring(err):match("no fn and no event"))
  end)

  it("accepts valid state-update def", function()
    local defs = { { action = "ok", fn = "handle_ok", target = "testing" } }
    assert.has_no.errors(function() format.validate_handler_defs(defs) end)
  end)

  it("accepts valid event-only def", function()
    local defs = { { action = "ok", event = "some_event" } }
    assert.has_no.errors(function() format.validate_handler_defs(defs) end)
  end)

  it("accepts valid state-update-with-event def", function()
    local defs = {
      { action = "ok", fn = "handle_ok", target = "testing", event = "ok_event" },
    }
    assert.has_no.errors(function() format.validate_handler_defs(defs) end)
  end)
end)

-- ─── Bug: reconnect stat counts initial connect ───────────────────────────
describe("model reconnect stat fix", function()
  it("new model starts with reconnect_count 0", function()
    local m = model.new()
    assert.are.equal(0, m.stats.reconnect_count)
  end)

  it("record_reconnect increments", function()
    local m = model.new()
    model.record_reconnect(m)
    assert.are.equal(1, m.stats.reconnect_count)
  end)

  -- The fix: initial connect should NOT count as a reconnect.
  -- This tests model behavior; init.lua integration tested separately.
  it("is_first_connect returns true when reconnect_gen is 0", function()
    local m = model.new()
    assert.is_true(model.is_first_connect(m))
  end)

  it("is_first_connect returns false after gen incremented", function()
    local m = model.new()
    model.set_reconnect_gen(m, 1)
    assert.is_false(model.is_first_connect(m))
  end)
end)

-- ─── async_all utility ───────────────────────────────────────────────────
describe("util.async_all", function()
  it("calls on_done with empty results for empty tasks", function()
    local called = false
    local got_results
    util.async_all({}, function(results)
      called = true
      got_results = results
    end)
    assert.is_true(called)
    assert.are.same({}, got_results)
  end)

  it("collects results from single task", function()
    local got_results
    util.async_all({
      function(done) done("hello") end,
    }, function(results)
      got_results = results
    end)
    assert.are.same({ "hello" }, got_results)
  end)

  it("collects results from multiple tasks in order", function()
    local callbacks = {}
    local got_results
    util.async_all({
      function(done) table.insert(callbacks, done) end,
      function(done) table.insert(callbacks, done) end,
      function(done) table.insert(callbacks, done) end,
    }, function(results)
      got_results = results
    end)
    -- Complete in reverse order — results should still be ordered
    callbacks[3]("c")
    callbacks[1]("a")
    assert.is_nil(got_results) -- not done yet
    callbacks[2]("b")
    assert.are.same({ "a", "b", "c" }, got_results)
  end)

  it("calls on_done exactly once", function()
    local call_count = 0
    util.async_all({
      function(done) done("a") end,
      function(done) done("b") end,
    }, function(_)
      call_count = call_count + 1
    end)
    assert.are.equal(1, call_count)
  end)

  -- Property: results length matches tasks length
  it("result count matches task count", function()
    for n = 1, 10 do
      local tasks = {}
      for i = 1, n do
        table.insert(tasks, function(done) done(i) end)
      end
      local got
      util.async_all(tasks, function(r) got = r end)
      assert.are.equal(n, #got, "expected " .. n .. " results")
    end
  end)
end)

-- ─── model.cell_count ─────────────────────────────────────────────────────
describe("model.cell_count", function()
  it("returns 0 for new model", function()
    local m = model.new()
    assert.are.equal(0, model.cell_count(m))
  end)

  it("returns count of tracked cells", function()
    local m = model.new()
    model.set_cell_state(m, "c1", "running", nil)
    model.set_cell_state(m, "c1", "success", "out1")
    model.set_cell_state(m, "c2", "running", nil)
    model.set_cell_state(m, "c3", "running", nil)
    model.set_cell_state(m, "c3", "error", "err")
    assert.are.equal(3, model.cell_count(m))
  end)
end)

-- ─── format.format_stats_lines ────────────────────────────────────────────
describe("format.format_stats_lines", function()
  it("returns a non-empty table of strings", function()
    local m = model.new()
    local lines = format.format_stats_lines(m)
    assert.is_table(lines)
    assert.is_true(#lines > 0)
  end)

  it("includes eval count", function()
    local m = model.new()
    model.record_eval(m, 100)
    model.record_eval(m, 200)
    local lines = format.format_stats_lines(m)
    local text = table.concat(lines, "\n")
    assert.truthy(text:match("2"), "should show eval count 2")
  end)

  it("includes avg latency", function()
    local m = model.new()
    model.record_eval(m, 100)
    model.record_eval(m, 300)
    local lines = format.format_stats_lines(m)
    local text = table.concat(lines, "\n")
    assert.truthy(text:match("200"), "should show avg latency 200ms")
  end)
end)

-- ─── Type hint placement (pure) ───────────────────────────────────────────
describe("format.type_hint_placements", function()
  it("matches let bindings to parsed type signatures", function()
    local buffer_lines = {
      "let x = 42;;",
      "",
      "let greet name =",
      '  sprintf "Hi %s" name;;',
    }
    local bindings = {
      { name = "x", type_sig = "int" },
      { name = "greet", type_sig = "name: string -> string" },
    }
    local placements = format.type_hint_placements(buffer_lines, 1, 4, bindings)
    assert.are.equal(2, #placements)
    assert.are.equal(1, placements[1].line)
    assert.are.equal(": int", placements[1].text)
    assert.are.equal(3, placements[2].line)
    assert.are.equal(": name: string -> string", placements[2].text)
  end)

  it("returns empty when no let bindings found", function()
    local buffer_lines = { 'printfn "hello";;' }
    local bindings = {}
    local placements = format.type_hint_placements(buffer_lines, 1, 1, bindings)
    assert.are.equal(0, #placements)
  end)

  it("handles let with pattern matching (no match)", function()
    local buffer_lines = { "let (a, b) = (1, 2);;" }
    local bindings = {
      { name = "a", type_sig = "int" },
      { name = "b", type_sig = "int" },
    }
    local placements = format.type_hint_placements(buffer_lines, 1, 1, bindings)
    assert.are.equal(0, #placements)
  end)

  it("only scans within the given line range", function()
    local buffer_lines = {
      "let outside = 1;;",
      "let inside = 2;;",
      "let after = 3;;",
    }
    local bindings = {
      { name = "outside", type_sig = "int" },
      { name = "inside", type_sig = "int" },
      { name = "after", type_sig = "int" },
    }
    local placements = format.type_hint_placements(buffer_lines, 2, 2, bindings)
    assert.are.equal(1, #placements)
    assert.are.equal(2, placements[1].line)
    assert.are.equal(": int", placements[1].text)
  end)
end)
