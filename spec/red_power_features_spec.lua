-- RED tests for Tier 4: Power Features
-- Type explorer formatting, history search, pipeline statusline, call graph,
-- export to .fsx, user autocmds, and treesitter cell detection.
-- Each test defines the pure-module API contract for a feature that doesn't exist yet.

require("spec.helper")

-- =============================================================================
-- Type Explorer (t4-type-explorer)
-- Pure module: sagefs/type_explorer.lua — DOES NOT EXIST YET
-- =============================================================================

local ok_te, type_explorer = pcall(require, "sagefs.type_explorer")
if not ok_te then type_explorer = {} end

describe("type_explorer.format_assemblies [RED T4]", function()
  it("formats a list of assemblies for picker display", function()
    assert.is_function(type_explorer.format_assemblies)
    local assemblies = {
      { name = "MyProject", path = "bin/Debug/MyProject.dll" },
      { name = "System.Runtime", path = "" },
    }
    local items = type_explorer.format_assemblies(assemblies)
    assert.is_table(items)
    assert.are.equal(2, #items)
    assert.is_string(items[1].label)
  end)
end)

describe("type_explorer.format_namespaces [RED T4]", function()
  it("formats namespaces for picker display", function()
    assert.is_function(type_explorer.format_namespaces)
    local namespaces = { "System.IO", "System.Collections.Generic", "MyApp.Domain" }
    local items = type_explorer.format_namespaces(namespaces)
    assert.is_table(items)
    assert.are.equal(3, #items)
    for _, item in ipairs(items) do
      assert.is_string(item.label)
      assert.is_string(item.namespace)
    end
  end)
end)

describe("type_explorer.format_types [RED T4]", function()
  it("formats types for picker display", function()
    assert.is_function(type_explorer.format_types)
    local types = {
      { name = "String", kind = "class", fullName = "System.String" },
      { name = "Option", kind = "union", fullName = "Microsoft.FSharp.Core.FSharpOption`1" },
    }
    local items = type_explorer.format_types(types)
    assert.is_table(items)
    assert.are.equal(2, #items)
    for _, item in ipairs(items) do
      assert.is_string(item.label)
      assert.is_string(item.fullName)
    end
  end)
end)

describe("type_explorer.format_members [RED T4]", function()
  it("formats type members for floating window display", function()
    assert.is_function(type_explorer.format_members)
    local members = {
      { name = "Length", kind = "property", returnType = "int" },
      { name = "Contains", kind = "method", returnType = "bool", parameters = "string value" },
      { name = ".ctor", kind = "constructor", parameters = "string value" },
    }
    local lines = type_explorer.format_members("System.String", members)
    assert.is_table(lines)
    assert.is_true(#lines >= 3)
    for _, l in ipairs(lines) do assert.is_string(l) end
  end)

  it("groups members by kind (properties, methods, constructors)", function()
    local members = {
      { name = "Length", kind = "property", returnType = "int" },
      { name = "Contains", kind = "method", returnType = "bool" },
      { name = ".ctor", kind = "constructor" },
    }
    local lines = type_explorer.format_members("Test", members)
    -- Should have section headers
    local has_props = false
    local has_methods = false
    for _, l in ipairs(lines) do
      if l:find("[Pp]ropert") then has_props = true end
      if l:find("[Mm]ethod") then has_methods = true end
    end
    assert.is_true(has_props)
    assert.is_true(has_methods)
  end)
end)

-- =============================================================================
-- History Search (t4-history-search)
-- Pure module: sagefs/history.lua — DOES NOT EXIST YET
-- =============================================================================

local ok_h, history = pcall(require, "sagefs.history")
if not ok_h then history = {} end

describe("history.format_events [RED T4]", function()
  it("formats FSI events for picker display", function()
    assert.is_function(history.format_events)
    local events = {
      { timestamp = "2026-02-24T10:00:00Z", source = "user", code = "let x = 42;;", result = "val x: int = 42" },
      { timestamp = "2026-02-24T10:01:00Z", source = "hotreload", code = "#load \"Math.fs\";;", result = "OK" },
    }
    local items = history.format_events(events)
    assert.is_table(items)
    assert.are.equal(2, #items)
    for _, item in ipairs(items) do
      assert.is_string(item.label)
      assert.is_string(item.code)
    end
  end)

  it("truncates long code in labels", function()
    local events = {
      { timestamp = "2026-02-24T10:00:00Z", source = "user",
        code = string.rep("x", 200) .. ";;",
        result = "ok" },
    }
    local items = history.format_events(events)
    assert.is_true(#items[1].label <= 150, "label should be truncated")
  end)
end)

describe("history.format_preview [RED T4]", function()
  it("formats a single event for preview in floating window", function()
    assert.is_function(history.format_preview)
    local event = {
      timestamp = "2026-02-24T10:00:00Z",
      source = "user",
      code = "let x = 42;;",
      result = "val x: int = 42",
    }
    local lines = history.format_preview(event)
    assert.is_table(lines)
    assert.is_true(#lines >= 2)
    -- Should contain the code and result
    local has_code = false
    local has_result = false
    for _, l in ipairs(lines) do
      if l:find("let x = 42") then has_code = true end
      if l:find("val x: int") then has_result = true end
    end
    assert.is_true(has_code)
    assert.is_true(has_result)
  end)
end)

describe("history.parse_events_response [RED T4]", function()
  it("parses the get_recent_fsi_events response", function()
    assert.is_function(history.parse_events_response)
    local json_str = vim.fn.json_encode({
      events = {
        { timestamp = "2026-02-24T10:00:00Z", source = "user", code = "1+1;;", result = "2" },
      },
    })
    local data, err = history.parse_events_response(json_str)
    assert.is_nil(err)
    assert.is_table(data)
    assert.is_table(data.events)
    assert.are.equal(1, #data.events)
  end)

  it("returns error for invalid JSON", function()
    local data, err = history.parse_events_response("not json")
    assert.is_not_nil(err)
  end)
end)

-- =============================================================================
-- Pipeline Statusline (t4-pipeline-statusline)
-- Uses testing.lua functions already tested above — just needs format_pipeline_statusline
-- =============================================================================

local testing = require("sagefs.testing")

describe("testing.format_pipeline_statusline [RED T4]", function()
  it("returns compact pipeline info for statusline", function()
    assert.is_function(testing.format_pipeline_statusline)
    local trace = {
      enabled = true,
      running = true,
      providers = { "Expecto" },
      summary = { total = 10, passed = 8, failed = 2 },
    }
    local line = testing.format_pipeline_statusline(trace)
    assert.is_string(line)
    assert.is_true(#line > 0)
    assert.is_true(#line < 60, "statusline should be compact")
  end)

  it("shows idle when not running", function()
    local trace = {
      enabled = true,
      running = false,
      providers = { "Expecto" },
    }
    local line = testing.format_pipeline_statusline(trace)
    -- Should not show running indicator
    assert.is_falsy(line:find("⏳"))
  end)

  it("returns empty when disabled", function()
    local trace = { enabled = false }
    local line = testing.format_pipeline_statusline(trace)
    assert.are.equal("", line)
  end)
end)

-- =============================================================================
-- Export to .fsx (t4-export-fsx)
-- Pure module: sagefs/export.lua — DOES NOT EXIST YET
-- =============================================================================

local ok_e, export = pcall(require, "sagefs.export")
if not ok_e then export = {} end

describe("export.format_fsx [RED T4]", function()
  it("formats FSI events as a .fsx script", function()
    assert.is_function(export.format_fsx)
    local events = {
      { code = "let x = 42;;", result = "val x: int = 42", source = "user" },
      { code = "let y = x + 1;;", result = "val y: int = 43", source = "user" },
    }
    local fsx = export.format_fsx(events)
    assert.is_string(fsx)
    assert.is_truthy(fsx:find("let x = 42"))
    assert.is_truthy(fsx:find("let y = x %+ 1"))
  end)

  it("includes results as comments", function()
    local events = {
      { code = "1 + 1;;", result = "val it: int = 2", source = "user" },
    }
    local fsx = export.format_fsx(events)
    assert.is_truthy(fsx:find("// val it: int = 2") or fsx:find("%(* val it"))
  end)

  it("skips hotreload events (only user code)", function()
    local events = {
      { code = '#load "Math.fs";;', result = "OK", source = "hotreload" },
      { code = "let x = 1;;", result = "val x: int = 1", source = "user" },
    }
    local fsx = export.format_fsx(events)
    assert.is_falsy(fsx:find("#load"))
    assert.is_truthy(fsx:find("let x = 1"))
  end)

  it("returns empty string for no events", function()
    local fsx = export.format_fsx({})
    assert.are.equal("", fsx)
  end)
end)

-- =============================================================================
-- User Autocmds (t4-user-autocmds)
-- Pure module: sagefs/events.lua — DOES NOT EXIST YET
-- Defines the event names and payload shapes for vim User autocmds
-- =============================================================================

local ok_ev, events = pcall(require, "sagefs.events")
if not ok_ev then events = {} end

describe("events.build_autocmd_data [RED T4]", function()
  it("builds SageFsEvalCompleted event data", function()
    assert.is_function(events.build_autocmd_data)
    local data = events.build_autocmd_data("eval_completed", {
      cell_id = 1, status = "success", output = "val it: int = 42",
    })
    assert.is_table(data)
    assert.are.equal("SageFsEvalCompleted", data.pattern)
    assert.is_table(data.data)
    assert.are.equal(1, data.data.cell_id)
    assert.are.equal("success", data.data.status)
  end)

  it("builds SageFsTestPassed event data", function()
    local data = events.build_autocmd_data("test_passed", {
      testId = "t1", displayName = "should add",
    })
    assert.are.equal("SageFsTestPassed", data.pattern)
    assert.are.equal("t1", data.data.testId)
  end)

  it("builds SageFsTestFailed event data", function()
    local data = events.build_autocmd_data("test_failed", {
      testId = "t2", displayName = "should subtract", output = "expected 4 got 3",
    })
    assert.are.equal("SageFsTestFailed", data.pattern)
    assert.are.equal("should subtract", data.data.displayName)
  end)

  it("builds SageFsConnected event data", function()
    local data = events.build_autocmd_data("connected", { session_id = "s1" })
    assert.are.equal("SageFsConnected", data.pattern)
  end)

  it("builds SageFsDisconnected event data", function()
    local data = events.build_autocmd_data("disconnected", {})
    assert.are.equal("SageFsDisconnected", data.pattern)
  end)

  it("returns nil for unknown event type", function()
    local data = events.build_autocmd_data("bogus", {})
    assert.is_nil(data)
  end)
end)

describe("events.EVENT_NAMES [RED T4]", function()
  it("defines all supported event names", function()
    assert.is_table(events.EVENT_NAMES)
    local expected = {
      "SageFsEvalCompleted",
      "SageFsTestPassed",
      "SageFsTestFailed",
      "SageFsTestRunStarted",
      "SageFsTestRunCompleted",
      "SageFsConnected",
      "SageFsDisconnected",
      "SageFsCoverageUpdated",
      "SageFsHotReloadTriggered",
    }
    for _, name in ipairs(expected) do
      local found = false
      for _, n in ipairs(events.EVENT_NAMES) do
        if n == name then found = true break end
      end
      assert.is_true(found, "missing event: " .. name)
    end
  end)
end)

-- =============================================================================
-- Treesitter Cell Detection (t4-treesitter-cells)
-- Would extend cells.lua with treesitter-based boundary detection
-- This tests the PURE query/parsing logic, not the treesitter integration itself
-- =============================================================================

local cells = require("sagefs.cells")

describe("cells.find_boundaries_treesitter [RED T4]", function()
  it("exists as a function", function()
    assert.is_function(cells.find_boundaries_treesitter)
  end)

  it("finds ;; boundaries from a parse tree", function()
    -- Simulate a treesitter node list (simplified)
    -- In real code this would use vim.treesitter, but the pure function
    -- takes pre-parsed boundary positions
    local boundaries = cells.find_boundaries_treesitter({
      { row = 2, col = 0, text = ";;" },
      { row = 5, col = 0, text = ";;" },
      { row = 9, col = 0, text = ";;" },
    })
    assert.is_table(boundaries)
    assert.are.equal(3, #boundaries)
    assert.are.equal(3, boundaries[1]) -- 1-indexed line
    assert.are.equal(6, boundaries[2])
    assert.are.equal(10, boundaries[3])
  end)

  it("excludes ;; inside strings", function()
    local boundaries = cells.find_boundaries_treesitter({
      { row = 2, col = 0, text = ";;", in_string = false },
      { row = 4, col = 10, text = ";;", in_string = true }, -- inside string literal
      { row = 6, col = 0, text = ";;", in_string = false },
    })
    assert.are.equal(2, #boundaries)
  end)

  it("excludes ;; inside comments", function()
    local boundaries = cells.find_boundaries_treesitter({
      { row = 2, col = 0, text = ";;", in_comment = false },
      { row = 3, col = 5, text = ";;", in_comment = true },
      { row = 5, col = 0, text = ";;", in_comment = false },
    })
    assert.are.equal(2, #boundaries)
  end)

  it("returns empty for no boundaries", function()
    local boundaries = cells.find_boundaries_treesitter({})
    assert.are.equal(0, #boundaries)
  end)
end)
