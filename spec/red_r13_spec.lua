-- RED tests for Round 13: Mind-blowing features
-- 1. depgraph_viz — in-buffer dependency arrows
-- 2. time_travel — scrub through cell output history
-- 3. type_flow  — cross-cell type flow tracing

describe("R13: depgraph_viz", function()
  local viz = require("sagefs.depgraph_viz")
  local depgraph = require("sagefs.depgraph")

  local cells_data = {
    { id = 1, source = "let x = 42;;", output = "val x: int = 42" },
    { id = 2, source = "let y = x + 1;;", output = "val y: int = 43" },
    { id = 3, source = "let z = y * x;;", output = "val z: int = 1806" },
  }
  local cells_layout = {
    [1] = { start_line = 1, end_line = 2 },
    [2] = { start_line = 4, end_line = 5 },
    [3] = { start_line = 7, end_line = 8 },
  }

  it("computes arrows from graph edges + layout", function()
    local graph = depgraph.build_graph(cells_data)
    local arrows = viz.compute_arrows(graph, cells_layout)
    assert.is_table(arrows)
    assert.is_true(#arrows >= 2) -- at least 1→2 and 1→3
    local arrow = arrows[1]
    assert.is_number(arrow.from_cell)
    assert.is_number(arrow.to_cell)
    assert.is_number(arrow.from_line)
    assert.is_number(arrow.to_line)
    assert.is_table(arrow.binding_names)
  end)

  it("formats sign marks for dependency indicators", function()
    local graph = depgraph.build_graph(cells_data)
    local arrows = viz.compute_arrows(graph, cells_layout)
    local signs = viz.format_sign_marks(arrows, cells_layout)
    assert.is_table(signs)
    assert.is_true(#signs > 0)
    local s = signs[1]
    assert.is_number(s.line)
    assert.is_string(s.text)
    assert.is_string(s.hl)
  end)

  it("formats inline arrows as virtual text", function()
    local graph = depgraph.build_graph(cells_data)
    local arrows = viz.compute_arrows(graph, cells_layout)
    local inlines = viz.format_inline_annotations(arrows)
    assert.is_table(inlines)
    assert.is_true(#inlines > 0)
    local a = inlines[1]
    assert.is_number(a.line)
    assert.is_string(a.text)
    assert.is_string(a.hl)
  end)

  it("computes stale cascade visualization", function()
    local graph = depgraph.build_graph(cells_data)
    local cascade = viz.format_stale_cascade(graph, 1, cells_layout)
    assert.is_table(cascade)
    -- cell 1 change should cascade to 2 and 3
    assert.is_true(#cascade >= 2)
    local c = cascade[1]
    assert.is_number(c.cell_id)
    assert.is_number(c.line)
    assert.is_string(c.label)
  end)

  it("handles isolated cells (no deps)", function()
    local isolated = {
      { id = 1, source = "let a = 1;;", output = "val a: int = 1" },
      { id = 2, source = "let b = 2;;", output = "val b: int = 2" },
    }
    local layout = {
      [1] = { start_line = 1, end_line = 1 },
      [2] = { start_line = 3, end_line = 3 },
    }
    local graph = depgraph.build_graph(isolated)
    local arrows = viz.compute_arrows(graph, layout)
    assert.are.equal(0, #arrows)
    local signs = viz.format_sign_marks(arrows, layout)
    assert.are.equal(0, #signs)
  end)

  it("formats panel summary", function()
    local graph = depgraph.build_graph(cells_data)
    local arrows = viz.compute_arrows(graph, cells_layout)
    local lines = viz.format_panel(arrows, cells_layout)
    assert.is_table(lines)
    assert.is_true(#lines > 0)
    -- should mention cell IDs and bindings
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("cell"))
  end)
end)

describe("R13: time_travel", function()
  local tt = require("sagefs.time_travel")

  it("creates empty state", function()
    local state = tt.new()
    assert.is_table(state)
    assert.are.equal(0, tt.history_count(state, 1))
  end)

  it("records eval outputs into history", function()
    local state = tt.new()
    tt.record(state, 1, "val x: int = 42", { duration_ms = 15, timestamp_ms = 1000 })
    tt.record(state, 1, "val x: int = 43", { duration_ms = 12, timestamp_ms = 2000 })
    assert.are.equal(2, tt.history_count(state, 1))
  end)

  it("navigates backward through history", function()
    local state = tt.new()
    tt.record(state, 1, "first", { duration_ms = 10, timestamp_ms = 1000 })
    tt.record(state, 1, "second", { duration_ms = 20, timestamp_ms = 2000 })
    tt.record(state, 1, "third", { duration_ms = 30, timestamp_ms = 3000 })

    -- Current should be latest
    local nav = tt.current(state, 1)
    assert.are.equal("third", nav.output)
    assert.are.equal(3, nav.index)
    assert.are.equal(3, nav.total)

    -- Navigate back one step
    local prev = tt.navigate(state, 1, -1)
    assert.are.equal("second", prev.output)
    assert.are.equal(2, prev.index)

    -- Navigate back another step
    local oldest = tt.navigate(state, 1, -2)
    assert.are.equal("first", oldest.output)
    assert.are.equal(1, oldest.index)
  end)

  it("clamps navigation at boundaries", function()
    local state = tt.new()
    tt.record(state, 1, "only", { duration_ms = 5, timestamp_ms = 100 })

    local nav = tt.navigate(state, 1, -10)
    assert.are.equal("only", nav.output)
    assert.are.equal(1, nav.index)

    local nav2 = tt.navigate(state, 1, 10)
    assert.are.equal("only", nav2.output)
    assert.are.equal(1, nav2.index)
  end)

  it("returns nil nav for unknown cell", function()
    local state = tt.new()
    local nav = tt.current(state, 99)
    assert.is_nil(nav)
  end)

  it("respects max_history limit", function()
    local state = tt.new(3) -- keep last 3
    for i = 1, 5 do
      tt.record(state, 1, "output_" .. i, { duration_ms = i, timestamp_ms = i * 1000 })
    end
    assert.are.equal(3, tt.history_count(state, 1))
    local nav = tt.navigate(state, 1, -2) -- oldest kept
    assert.are.equal("output_3", nav.output)
  end)

  it("formats navigation status line", function()
    local state = tt.new()
    tt.record(state, 1, "a", { duration_ms = 50, timestamp_ms = 1000 })
    tt.record(state, 1, "b", { duration_ms = 120, timestamp_ms = 2000 })
    local nav = tt.current(state, 1)
    local status = tt.format_nav_status(nav)
    assert.is_string(status)
    assert.truthy(status:find("2/2"))
    assert.truthy(status:find("120"))
  end)

  it("diffs history entry with current", function()
    local diff = require("sagefs.diff")
    local state = tt.new()
    tt.record(state, 1, "val x: int = 1", { duration_ms = 10, timestamp_ms = 1000 })
    tt.record(state, 1, "val x: int = 2", { duration_ms = 10, timestamp_ms = 2000 })
    local d = tt.diff_with_current(state, 1, 1) -- diff entry 1 vs current
    assert.is_table(d)
    assert.is_true(#d > 0)
    assert.are.equal("changed", d[1].kind)
  end)

  it("tracks per-cell history independently", function()
    local state = tt.new()
    tt.record(state, 1, "a1", { duration_ms = 10, timestamp_ms = 1000 })
    tt.record(state, 2, "b1", { duration_ms = 20, timestamp_ms = 1500 })
    tt.record(state, 1, "a2", { duration_ms = 15, timestamp_ms = 2000 })
    assert.are.equal(2, tt.history_count(state, 1))
    assert.are.equal(1, tt.history_count(state, 2))
  end)
end)

describe("R13: type_flow", function()
  local tf = require("sagefs.type_flow")
  local depgraph = require("sagefs.depgraph")

  local cells_data = {
    { id = 1, source = "let x = 42;;", output = "val x: int = 42" },
    { id = 2, source = "let y = x + 1;;", output = "val y: int = 43" },
    { id = 3, source = "let z = y * 2;;", output = "val z: int = 86" },
  }
  local cell_outputs = {
    [1] = "val x: int = 42",
    [2] = "val y: int = 43",
    [3] = "val z: int = 86",
  }

  it("traces a binding through the graph", function()
    local graph = depgraph.build_graph(cells_data)
    local flow = tf.trace_binding("x", graph, cell_outputs)
    assert.is_table(flow)
    assert.are.equal(1, flow.origin.cell_id)
    assert.are.equal("int", flow.origin.type_sig)
    assert.is_true(#flow.consumers >= 1)
  end)

  it("returns nil for unknown binding", function()
    local graph = depgraph.build_graph(cells_data)
    local flow = tf.trace_binding("nonexistent", graph, cell_outputs)
    assert.is_nil(flow)
  end)

  it("computes all flows", function()
    local graph = depgraph.build_graph(cells_data)
    local flows = tf.all_flows(graph, cell_outputs)
    assert.is_table(flows)
    assert.is_true(#flows >= 2) -- x and y at least
  end)

  it("formats flow annotations for virtual text", function()
    local graph = depgraph.build_graph(cells_data)
    local flows = tf.all_flows(graph, cell_outputs)
    local cells_layout = {
      [1] = { start_line = 1, end_line = 2 },
      [2] = { start_line = 4, end_line = 5 },
      [3] = { start_line = 7, end_line = 8 },
    }
    local annotations = tf.format_flow_annotations(flows, cells_layout)
    assert.is_table(annotations)
    assert.is_true(#annotations > 0)
    local a = annotations[1]
    assert.is_number(a.line)
    assert.is_string(a.text)
    assert.is_string(a.hl)
  end)

  it("formats flow path as human-readable string", function()
    local graph = depgraph.build_graph(cells_data)
    local flow = tf.trace_binding("x", graph, cell_outputs)
    local path = tf.format_flow_path(flow)
    assert.is_string(path)
    assert.truthy(path:find("x"))
    assert.truthy(path:find("int"))
    assert.truthy(path:find("cell 1"))
  end)

  it("handles self-contained cell (no consumers)", function()
    local isolated = {
      { id = 1, source = "let q = 1;;", output = "val q: int = 1" },
    }
    local outputs = { [1] = "val q: int = 1" }
    local graph = depgraph.build_graph(isolated)
    local flow = tf.trace_binding("q", graph, outputs)
    assert.is_table(flow)
    assert.are.equal(0, #flow.consumers)
  end)
end)
