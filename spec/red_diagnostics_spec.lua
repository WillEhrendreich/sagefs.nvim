-- RED tests for t0-consolidate-diag: Diagnostics consolidation
-- init.lua has a duplicate inline diagnostics parser (lines 647-689) that should
-- use sse.parse_chunk + diagnostics.lua functions instead.
-- These tests verify the diagnostics.lua module handles all cases the inline parser does.

require("spec.helper")
local diagnostics = require("sagefs.diagnostics")

-- =============================================================================
-- Parse SSE diagnostics payload into structured diagnostics
-- =============================================================================

describe("diagnostics.parse_sse_payload [RED]", function()
  it("parses a DiagnosticsUpdated SSE data payload", function()
    assert.is_function(diagnostics.parse_sse_payload)
    local json_str = vim.fn.json_encode({
      diagnostics = {
        {
          file = "src/Math.fs",
          startLine = 10, startColumn = 5,
          endLine = 10, endColumn = 15,
          message = "Type mismatch",
          severity = "error",
        },
        {
          file = "src/Math.fs",
          startLine = 20, startColumn = 1,
          endLine = 20, endColumn = 10,
          message = "Unused variable",
          severity = "warning",
        },
      },
    })
    local diags, err = diagnostics.parse_sse_payload(json_str)
    assert.is_nil(err)
    assert.is_table(diags)
    assert.are.equal(2, #diags)
  end)

  it("returns error for invalid JSON", function()
    local diags, err = diagnostics.parse_sse_payload("not json")
    assert.is_not_nil(err)
  end)

  it("returns empty list for empty diagnostics", function()
    local json_str = vim.fn.json_encode({ diagnostics = {} })
    local diags, err = diagnostics.parse_sse_payload(json_str)
    assert.is_nil(err)
    assert.are.equal(0, #diags)
  end)

  it("returns error for nil input", function()
    local diags, err = diagnostics.parse_sse_payload(nil)
    assert.is_not_nil(err)
  end)

  it("returns error for empty string", function()
    local diags, err = diagnostics.parse_sse_payload("")
    assert.is_not_nil(err)
  end)
end)

-- =============================================================================
-- Batch convert to vim.diagnostic format
-- =============================================================================

describe("diagnostics.to_vim_diagnostics [RED]", function()
  it("converts a list of raw diagnostics to vim format", function()
    assert.is_function(diagnostics.to_vim_diagnostics)
    local raw = {
      { file = "a.fs", startLine = 5, startColumn = 3, endLine = 5, endColumn = 10, message = "err", severity = "error" },
      { file = "a.fs", startLine = 8, startColumn = 1, endLine = 8, endColumn = 5, message = "warn", severity = "warning" },
    }
    local vim_diags = diagnostics.to_vim_diagnostics(raw)
    assert.is_table(vim_diags)
    assert.are.equal(2, #vim_diags)
    -- Verify 0-indexed
    assert.are.equal(4, vim_diags[1].lnum) -- startLine 5 → 0-indexed 4
    assert.are.equal(2, vim_diags[1].col)  -- startColumn 3 → 0-indexed 2
    assert.are.equal(1, vim_diags[1].severity) -- error = 1
  end)

  it("handles empty list", function()
    local vim_diags = diagnostics.to_vim_diagnostics({})
    assert.are.equal(0, #vim_diags)
  end)
end)

-- =============================================================================
-- Full cycle: SSE data → grouped vim diagnostics per file
-- =============================================================================

describe("diagnostics.process_sse_event [RED]", function()
  it("parses SSE data and returns file-grouped vim diagnostics", function()
    assert.is_function(diagnostics.process_sse_event)
    local json_str = vim.fn.json_encode({
      diagnostics = {
        { file = "a.fs", startLine = 1, startColumn = 1, endLine = 1, endColumn = 5, message = "e1", severity = "error" },
        { file = "b.fs", startLine = 2, startColumn = 1, endLine = 2, endColumn = 5, message = "e2", severity = "warning" },
        { file = "a.fs", startLine = 3, startColumn = 1, endLine = 3, endColumn = 5, message = "e3", severity = "info" },
      },
    })
    local groups, err = diagnostics.process_sse_event(json_str)
    assert.is_nil(err)
    assert.is_table(groups)
    assert.is_table(groups["a.fs"])
    assert.is_table(groups["b.fs"])
    assert.are.equal(2, #groups["a.fs"])
    assert.are.equal(1, #groups["b.fs"])
    -- Each entry should be vim.diagnostic-compatible
    assert.is_number(groups["a.fs"][1].lnum)
    assert.is_number(groups["a.fs"][1].severity)
  end)

  it("returns error for invalid input", function()
    local groups, err = diagnostics.process_sse_event("garbage")
    assert.is_not_nil(err)
  end)
end)
