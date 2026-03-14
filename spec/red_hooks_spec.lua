-- =============================================================================
-- Tests — Server-pushed feature hooks (EvalDiff, CellDependencies,
-- BindingScopeMap, EvalTimeline)
-- =============================================================================
-- SageFs pushes pre-computed feature data over SSE. These tests define
-- the contract sagefs.nvim needs to consume them: classify, dispatch,
-- and fire User autocmds.
--
-- Server SSE event types (from SseWriter.fs):
--   eval_diff, cell_dependencies, binding_scope_map, eval_timeline
-- =============================================================================

require("spec.helper")
local sse = require("sagefs.sse")
local events = require("sagefs.events")

-- ─── SSE Classification: new hook event types ────────────────────────────────

describe("sse.classify_event server hooks", function()
  it("classifies eval_diff event", function()
    local result = sse.classify_event({ type = "eval_diff", data = "{}" })
    assert.are.equal("eval_diff", result.action)
  end)

  it("classifies cell_dependencies event", function()
    local result = sse.classify_event({ type = "cell_dependencies", data = "{}" })
    assert.are.equal("cell_dependencies", result.action)
  end)

  it("classifies binding_scope_map event", function()
    local result = sse.classify_event({ type = "binding_scope_map", data = "{}" })
    assert.are.equal("binding_scope_map", result.action)
  end)

  it("classifies eval_timeline event", function()
    local result = sse.classify_event({ type = "eval_timeline", data = "{}" })
    assert.are.equal("eval_timeline", result.action)
  end)
end)

-- ─── Full round-trip: parse SSE → classify hook events ───────────────────────

describe("sse parse + classify hook events", function()
  it("round-trips eval_diff SSE event", function()
    local chunk = 'event: eval_diff\ndata: {"added":2,"removed":1,"modified":0,"unchanged":0,"lines":[]}\n\n'
    local parsed = sse.parse_chunk(chunk)
    assert.are.equal(1, #parsed)
    local classified = sse.classify_event(parsed[1])
    assert.are.equal("eval_diff", classified.action)
    assert.truthy(classified.data:find('"added"'))
  end)

  it("round-trips cell_dependencies SSE event", function()
    local chunk = 'event: cell_dependencies\ndata: {"nodes":[{"id":0,"produces":["x"],"consumes":[]}],"edges":[]}\n\n'
    local parsed = sse.parse_chunk(chunk)
    assert.are.equal(1, #parsed)
    local classified = sse.classify_event(parsed[1])
    assert.are.equal("cell_dependencies", classified.action)
    assert.truthy(classified.data:find('"nodes"'))
  end)

  it("round-trips binding_scope_map SSE event", function()
    local chunk = 'event: binding_scope_map\ndata: {"bindings":[{"name":"x","typeSig":"int","cellIndex":0}],"activeCount":1,"shadowedCount":0}\n\n'
    local parsed = sse.parse_chunk(chunk)
    assert.are.equal(1, #parsed)
    local classified = sse.classify_event(parsed[1])
    assert.are.equal("binding_scope_map", classified.action)
    assert.truthy(classified.data:find('"bindings"'))
  end)

  it("round-trips eval_timeline SSE event", function()
    local chunk = 'event: eval_timeline\ndata: {"count":5,"p50Ms":120,"p95Ms":300,"p99Ms":450,"meanMs":180,"sparkline":"▁▂▃"}\n\n'
    local parsed = sse.parse_chunk(chunk)
    assert.are.equal(1, #parsed)
    local classified = sse.classify_event(parsed[1])
    assert.are.equal("eval_timeline", classified.action)
    assert.truthy(classified.data:find('"p50Ms"'))
  end)
end)

-- ─── Dispatch: hook events reach handlers ────────────────────────────────────

describe("sse dispatch hook events", function()
  it("dispatches eval_diff to handler", function()
    local received = nil
    local dt = sse.build_dispatch_table({
      eval_diff = function(data) received = data end,
    })
    sse.dispatch(dt, { action = "eval_diff", data = '{"added":1}' })
    assert.are.equal('{"added":1}', received)
  end)

  it("dispatches cell_dependencies to handler", function()
    local received = nil
    local dt = sse.build_dispatch_table({
      cell_dependencies = function(data) received = data end,
    })
    sse.dispatch(dt, { action = "cell_dependencies", data = '{"nodes":[],"edges":[]}' })
    assert.are.equal('{"nodes":[],"edges":[]}', received)
  end)

  it("dispatches binding_scope_map to handler", function()
    local received = nil
    local dt = sse.build_dispatch_table({
      binding_scope_map = function(data) received = data end,
    })
    sse.dispatch(dt, { action = "binding_scope_map", data = '{"bindings":[]}' })
    assert.are.equal('{"bindings":[]}', received)
  end)

  it("dispatches eval_timeline to handler", function()
    local received = nil
    local dt = sse.build_dispatch_table({
      eval_timeline = function(data) received = data end,
    })
    sse.dispatch(dt, { action = "eval_timeline", data = '{"count":0}' })
    assert.are.equal('{"count":0}', received)
  end)

  it("safe_dispatch_batch handles all 4 hooks in one batch", function()
    local log = {}
    local dt = sse.build_dispatch_table({
      eval_diff = function() log[#log + 1] = "eval_diff" end,
      cell_dependencies = function() log[#log + 1] = "cell_dependencies" end,
      binding_scope_map = function() log[#log + 1] = "binding_scope_map" end,
      eval_timeline = function() log[#log + 1] = "eval_timeline" end,
    })
    local batch = {
      { action = "eval_diff", data = "{}" },
      { action = "cell_dependencies", data = "{}" },
      { action = "binding_scope_map", data = "{}" },
      { action = "eval_timeline", data = "{}" },
    }
    local errors = sse.safe_dispatch_batch(dt, batch)
    assert.are.equal(0, #errors)
    assert.are.equal(4, #log)
  end)
end)

-- ─── Events module: autocmd names and mappings for hooks ─────────────────────

describe("events hook autocmd mappings", function()
  it("maps eval_diff to SageFsEvalDiff", function()
    local result = events.build_autocmd_data("eval_diff", { added = 1 })
    assert.is_table(result)
    assert.are.equal("SageFsEvalDiff", result.pattern)
    assert.are.equal(1, result.data.added)
  end)

  it("maps cell_dependencies to SageFsCellDependencies", function()
    local result = events.build_autocmd_data("cell_dependencies", {})
    assert.is_table(result)
    assert.are.equal("SageFsCellDependencies", result.pattern)
  end)

  it("maps binding_scope_map to SageFsBindingScopeMap", function()
    local result = events.build_autocmd_data("binding_scope_map", {})
    assert.is_table(result)
    assert.are.equal("SageFsBindingScopeMap", result.pattern)
  end)

  it("maps eval_timeline to SageFsEvalTimeline", function()
    local result = events.build_autocmd_data("eval_timeline", {})
    assert.is_table(result)
    assert.are.equal("SageFsEvalTimeline", result.pattern)
  end)

  it("EVENT_NAMES includes all 4 hook events", function()
    local expected = {
      "SageFsEvalDiff",
      "SageFsCellDependencies",
      "SageFsBindingScopeMap",
      "SageFsEvalTimeline",
    }
    for _, name in ipairs(expected) do
      local found = false
      for _, en in ipairs(events.EVENT_NAMES) do
        if en == name then found = true; break end
      end
      assert.is_true(found, name .. " should be in EVENT_NAMES")
    end
  end)

  it("EVENT_NAMES count reflects the supported autocmd catalog", function()
    assert.are.equal(36, #events.EVENT_NAMES)
  end)
end)
