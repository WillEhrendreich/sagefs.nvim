-- =============================================================================
-- R12 RED Tests — Panel R12 review: revolutionary features
-- =============================================================================
-- TDD: All tests written RED first, verified failing, then made GREEN.
-- Panel findings: eval diff, dependency graph, scope map, timeline, notebook.
-- =============================================================================

require("spec.helper")

-- ─── #3: Eval Diff ─────────────────────────────────────────────────────────
describe("diff", function()
  local diff = require("sagefs.diff")

  it("detects changed value in binding", function()
    local d = diff.diff_lines(
      "val x : int = 42",
      "val x : int = 43"
    )
    assert.are.equal(1, #d)
    assert.are.equal("changed", d[1].kind)
    assert.are.equal("val x : int = 42", d[1].old)
    assert.are.equal("val x : int = 43", d[1].new)
  end)

  it("detects added lines", function()
    local d = diff.diff_lines(
      "val x : int = 42",
      'val x : int = 42\nval y : string = "hello"'
    )
    assert.are.equal(2, #d)
    assert.are.equal("unchanged", d[1].kind)
    assert.are.equal("added", d[2].kind)
  end)

  it("handles nil old (first eval)", function()
    local d = diff.diff_lines(nil, "val x : int = 42")
    assert.are.equal(1, #d)
    assert.are.equal("added", d[1].kind)
  end)

  it("produces correct summary", function()
    local d = diff.diff_lines("a\nb\nc", "a\nB\nc\nd")
    local s = diff.diff_summary(d)
    assert.truthy(s:match("1 changed"))
    assert.truthy(s:match("1 added"))
  end)

  it("returns no changes for identical output", function()
    local d = diff.diff_lines("val x : int = 42", "val x : int = 42")
    for _, entry in ipairs(d) do
      assert.are.equal("unchanged", entry.kind)
    end
    assert.are.equal("no changes", diff.diff_summary(d))
  end)

  it("handles nil both sides", function()
    local d = diff.diff_lines(nil, nil)
    assert.are.equal(0, #d)
  end)

  it("handles removed lines", function()
    local d = diff.diff_lines("line1\nline2", "line1")
    assert.are.equal(2, #d)
    assert.are.equal("unchanged", d[1].kind)
    assert.are.equal("removed", d[2].kind)
  end)

  it("format_diff produces colorable entries", function()
    local d = diff.diff_lines("old", "new")
    local f = diff.format_diff(d)
    assert.are.equal(2, #f) -- -old, +new
    assert.truthy(f[1].hl)
    assert.truthy(f[2].hl)
  end)
end)

-- ─── #1: Dependency Graph ──────────────────────────────────────────────────
describe("depgraph", function()
  local dg = require("sagefs.depgraph")

  it("detects that cell 2 consumes binding from cell 1", function()
    local c1 = dg.analyze_cell("let x = 42;;", "val x : int = 42")
    local c2 = dg.analyze_cell("let y = x + 1;;", "val y : int = 43")
    assert.same({"x"}, c1.produces)
    assert.same({}, c1.consumes)
    assert.same({"y"}, c2.produces)
    assert.same({"x"}, c2.consumes)
  end)

  it("builds a DAG with correct edges", function()
    local g = dg.build_graph({
      { id = 1, source = "let x = 42;;",       output = "val x : int = 42" },
      { id = 2, source = "let y = x + 1;;",    output = "val y : int = 43" },
      { id = 3, source = "let z = y * x;;",    output = "val z : int = 86" },
    })
    assert.truthy(#g.edges >= 3)
  end)

  it("computes transitive stale set", function()
    local g = dg.build_graph({
      { id = 1, source = "let x = 42;;",       output = "val x : int = 42" },
      { id = 2, source = "let y = x + 1;;",    output = "val y : int = 43" },
      { id = 3, source = "let z = y * 2;;",    output = "val z : int = 86" },
      { id = 4, source = 'printfn "hi";;',      output = "" },
    })
    local stale = dg.transitive_stale(g, 1)
    assert.same({2, 3}, stale)
  end)

  it("handles no-dependency cells as isolated nodes", function()
    local g = dg.build_graph({
      { id = 1, source = "let x = 42;;", output = "val x : int = 42" },
      { id = 2, source = 'printfn "hello";;', output = "" },
    })
    assert.same({}, dg.transitive_stale(g, 2))
  end)

  it("filters F# keywords from consumes", function()
    local c = dg.analyze_cell("let result = if true then 42 else 0;;", "val result : int = 42")
    -- Should not consume: let, if, true, then, else
    for _, name in ipairs(c.consumes) do
      assert.is_not.equal("let", name)
      assert.is_not.equal("if", name)
      assert.is_not.equal("true", name)
      assert.is_not.equal("then", name)
      assert.is_not.equal("else", name)
    end
  end)
end)

-- ─── #2: Eval Timeline ────────────────────────────────────────────────────
describe("timeline", function()
  local tl = require("sagefs.timeline")

  it("records evals and produces sparkline", function()
    local s = tl.new()
    s = tl.record(s, { cell_id = 1, start_ms = 0,    duration_ms = 50,   status = "success" })
    s = tl.record(s, { cell_id = 2, start_ms = 100,  duration_ms = 200,  status = "success" })
    s = tl.record(s, { cell_id = 1, start_ms = 400,  duration_ms = 1500, status = "error" })
    local spark = tl.sparkline(s, 20)
    assert.is_string(spark)
    assert.truthy(#spark <= 60) -- UTF-8 chars may be multi-byte
  end)

  it("computes p50 and p95", function()
    local s = tl.new()
    for i = 1, 100 do
      s = tl.record(s, { cell_id = 1, start_ms = i * 100, duration_ms = i * 10, status = "success" })
    end
    local p50 = tl.percentile(s, 0.50)
    local p95 = tl.percentile(s, 0.95)
    assert.truthy(p50 < p95)
    assert.truthy(p50 > 0)
  end)

  it("flame chart has correct number of lines", function()
    local s = tl.new()
    s = tl.record(s, { cell_id = 1, start_ms = 0,   duration_ms = 100, status = "success" })
    s = tl.record(s, { cell_id = 2, start_ms = 50,  duration_ms = 200, status = "success" })
    s = tl.record(s, { cell_id = 3, start_ms = 300, duration_ms = 50,  status = "error" })
    local chart = tl.flame_chart(s, 60)
    assert.truthy(#chart >= 3)
  end)

  it("empty timeline produces empty sparkline", function()
    local s = tl.new()
    assert.are.equal("", tl.sparkline(s, 20))
  end)

  it("percentile on empty timeline returns nil", function()
    local s = tl.new()
    assert.is_nil(tl.percentile(s, 0.50))
  end)
end)

-- ─── #4: Notebook Export ───────────────────────────────────────────────────
describe("notebook", function()
  local nb = require("sagefs.notebook")

  it("round-trips export → parse", function()
    local cells = {
      { source = "let x = 42;;", output = "val x : int = 42", duration_ms = 15,
        bindings = {{ name = "x", type_sig = "int" }}, status = "success" },
      { source = "let y = x + 1;;", output = "val y : int = 43", duration_ms = 8,
        bindings = {{ name = "y", type_sig = "int" }}, status = "success" },
    }
    local exported = nb.export_notebook(cells, { project = "MyApp" })
    local parsed, meta = nb.parse_notebook(exported)
    assert.are.equal(2, #parsed)
    assert.are.equal("let x = 42;;", parsed[1].source)
    assert.are.equal("val x : int = 42", parsed[1].output)
    assert.are.equal(15, parsed[1].duration_ms)
    assert.are.equal("MyApp", meta.project)
  end)

  it("produces valid F# (metadata in block comments only)", function()
    local cells = {
      { source = 'printfn "hello";;', output = "hello", status = "success" },
    }
    local exported = nb.export_notebook(cells, {})
    assert.truthy(exported:match("printfn"))
    -- All metadata is in (* *) comments, not // comments
    for line in exported:gmatch("[^\n]+") do
      if line:match("@sagefs") then
        assert.truthy(line:match("^%(%*") or line:match("^%s"),
          "metadata must be inside block comments: " .. line)
      end
    end
  end)

  it("generates summary block with timing", function()
    local cells = {
      { source = "let x = 1;;", duration_ms = 100, status = "success" },
      { source = "let y = 2;;", duration_ms = 200, status = "error" },
    }
    local summary = nb.summary_block(cells)
    assert.truthy(summary:match("2 cells"))
    assert.truthy(summary:match("300ms"))
    assert.truthy(summary:match("1 error"))
  end)

  it("handles cells without output", function()
    local cells = {
      { source = "open System;;", output = nil, status = "success" },
    }
    local exported = nb.export_notebook(cells, {})
    assert.truthy(exported:match("open System"))
    -- Should not crash on nil output
  end)
end)

-- ─── #5: Scope Map ─────────────────────────────────────────────────────────
describe("scope_map", function()
  local sm = require("sagefs.scope_map")

  it("returns correct bindings at a given line", function()
    local map = {
      { name = "x", type_sig = "int", cell_id = 1, cell_start_line = 1, cell_end_line = 3, shadow_count = 0, is_current = true },
      { name = "y", type_sig = "string", cell_id = 2, cell_start_line = 4, cell_end_line = 6, shadow_count = 0, is_current = true },
    }
    local at_line_5 = sm.bindings_at_line(map, 5)
    assert.are.equal(2, #at_line_5) -- both x and y visible
    local at_line_2 = sm.bindings_at_line(map, 2)
    assert.are.equal(1, #at_line_2) -- only x visible
  end)

  it("formats picker items with shadow indicator", function()
    local map = {
      { name = "x", type_sig = "int", cell_id = 1, cell_start_line = 1, cell_end_line = 3, shadow_count = 0, is_current = true },
      { name = "y", type_sig = "string", cell_id = 3, cell_start_line = 7, cell_end_line = 9, shadow_count = 1, is_current = true },
    }
    local items = sm.format_picker_items(map)
    assert.are.equal(2, #items)
    assert.truthy(items[2].label:match("shadow"))
  end)

  it("format_panel produces readable output", function()
    local map = {
      { name = "x", type_sig = "int", cell_id = 1, cell_start_line = 1, cell_end_line = 3, shadow_count = 0, is_current = true },
    }
    local lines = sm.format_panel(map)
    assert.truthy(#lines >= 2)
    assert.truthy(table.concat(lines, "\n"):match("x : int"))
  end)

  it("build_scope_map produces entries from cells and outputs", function()
    local tracker = { bindings = {
      x = { type_sig = "int", count = 1 },
      y = { type_sig = "string", count = 1 },
    }}
    local cells = {
      { id = 1, start_line = 1, end_line = 3, text = "let x = 42;;" },
      { id = 2, start_line = 4, end_line = 6, text = 'let y = "hi";;' },
    }
    local outputs = {
      [1] = "val x : int = 42",
      [2] = 'val y : string = "hi"',
    }
    local map = sm.build_scope_map(tracker, cells, outputs)
    assert.truthy(#map >= 2)
  end)
end)

-- ─── Model: prev_output tracking ──────────────────────────────────────────
describe("model prev_output tracking", function()
  local model = require("sagefs.model")

  it("stores prev_output on re-eval", function()
    local m = model.new()
    m = model.set_cell_state(m, "c1", "running", nil)
    m = model.set_cell_state(m, "c1", "success", "val x : int = 42")
    -- Re-eval same cell
    m = model.set_cell_state(m, "c1", "running", nil)
    m = model.set_cell_state(m, "c1", "success", "val x : int = 43")
    assert.are.equal("val x : int = 42", m.cells.c1.prev_output)
  end)

  it("prev_output is nil on first eval", function()
    local m = model.new()
    m = model.set_cell_state(m, "c1", "running", nil)
    m = model.set_cell_state(m, "c1", "success", "val x : int = 42")
    assert.is_nil(m.cells.c1.prev_output)
  end)
end)
