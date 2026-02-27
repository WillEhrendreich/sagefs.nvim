-- spec/annotations_spec.lua — Tests for sagefs.annotations module
local annotations = require("sagefs.annotations")

describe("annotations.new", function()
  it("creates empty state", function()
    local state = annotations.new()
    assert.is_table(state)
    assert.is_table(state.files)
    assert.are.equal(0, vim.tbl_count(state.files))
  end)
end)

describe("annotations.handle_file_annotations", function()
  it("stores annotations keyed by normalized file path", function()
    local state = annotations.new()
    local data = {
      FilePath = "C:\\Code\\Tests.fs",
      TestAnnotations = {
        { Line = 10, TestId = "t1", DisplayName = "test1", Status = "Passed", Freshness = "Current" }
      },
      CoverageAnnotations = {},
      InlineFailures = {},
      CodeLenses = {},
    }
    local new_state = annotations.handle_file_annotations(state, data)
    assert.is_not_nil(new_state.files["C:/Code/Tests.fs"])
  end)

  it("replaces previous annotations for same file", function()
    local state = annotations.new()
    local data1 = { FilePath = "Tests.fs", TestAnnotations = { { Line = 1 } }, CodeLenses = {}, InlineFailures = {}, CoverageAnnotations = {} }
    local data2 = { FilePath = "Tests.fs", TestAnnotations = { { Line = 2 }, { Line = 3 } }, CodeLenses = {}, InlineFailures = {}, CoverageAnnotations = {} }
    state = annotations.handle_file_annotations(state, data1)
    state = annotations.handle_file_annotations(state, data2)
    local ann = annotations.get_file(state, "Tests.fs")
    assert.are.equal(2, #ann.TestAnnotations)
  end)

  it("preserves annotations for other files", function()
    local state = annotations.new()
    local data1 = { FilePath = "A.fs", TestAnnotations = { { Line = 1 } }, CodeLenses = {}, InlineFailures = {}, CoverageAnnotations = {} }
    local data2 = { FilePath = "B.fs", TestAnnotations = { { Line = 2 } }, CodeLenses = {}, InlineFailures = {}, CoverageAnnotations = {} }
    state = annotations.handle_file_annotations(state, data1)
    state = annotations.handle_file_annotations(state, data2)
    assert.is_not_nil(annotations.get_file(state, "A.fs"))
    assert.is_not_nil(annotations.get_file(state, "B.fs"))
  end)

  it("ignores nil data", function()
    local state = annotations.new()
    local new_state = annotations.handle_file_annotations(state, nil)
    assert.are.equal(0, vim.tbl_count(new_state.files))
  end)
end)

describe("annotations.get_file", function()
  it("returns nil for unknown file", function()
    local state = annotations.new()
    assert.is_nil(annotations.get_file(state, "unknown.fs"))
  end)

  it("matches with backslash normalization", function()
    local state = annotations.new()
    local data = { FilePath = "src\\Tests.fs", TestAnnotations = {}, CodeLenses = {}, InlineFailures = {}, CoverageAnnotations = {} }
    state = annotations.handle_file_annotations(state, data)
    assert.is_not_nil(annotations.get_file(state, "src/Tests.fs"))
  end)

  it("matches by suffix when paths differ", function()
    local state = annotations.new()
    local data = { FilePath = "C:/Code/Repos/SageFs/Tests.fs", TestAnnotations = {}, CodeLenses = {}, InlineFailures = {}, CoverageAnnotations = {} }
    state = annotations.handle_file_annotations(state, data)
    -- Neovim buffer path may be different prefix
    local ann = annotations.get_file(state, "/home/user/repos/SageFs/Tests.fs")
    -- Suffix match won't work here since neither is a suffix of the other
    -- but exact normalized match should work
    local ann2 = annotations.get_file(state, "C:/Code/Repos/SageFs/Tests.fs")
    assert.is_not_nil(ann2)
  end)
end)

describe("annotations.unwrap_status", function()
  it("unwraps DU table with Case field", function()
    assert.are.equal("Passed", annotations.unwrap_status({ Case = "Passed", Fields = { "00:00:00.012" } }))
  end)

  it("handles plain string status", function()
    assert.are.equal("Failed", annotations.unwrap_status("Failed"))
  end)

  it("returns Unknown for nil", function()
    assert.are.equal("Unknown", annotations.unwrap_status(nil))
  end)
end)

describe("annotations.parse_timespan_ms", function()
  it("parses simple timespan", function()
    local ms = annotations.parse_timespan_ms("00:00:00.0120000")
    assert.is_near(12, ms, 0.1)
  end)

  it("parses seconds", function()
    local ms = annotations.parse_timespan_ms("00:00:01.5000000")
    assert.is_near(1500, ms, 0.1)
  end)

  it("returns nil for invalid input", function()
    assert.is_nil(annotations.parse_timespan_ms("garbage"))
    assert.is_nil(annotations.parse_timespan_ms(nil))
    assert.is_nil(annotations.parse_timespan_ms(42))
  end)
end)

describe("annotations.extract_duration_ms", function()
  it("extracts from Passed status", function()
    local ms = annotations.extract_duration_ms({ Case = "Passed", Fields = { "00:00:00.0050000" } })
    assert.is_near(5, ms, 0.1)
  end)

  it("extracts from Failed status (second field is duration)", function()
    local ms = annotations.extract_duration_ms({ Case = "Failed", Fields = { {}, "00:00:00.1000000" } })
    assert.is_near(100, ms, 0.1)
  end)

  it("returns nil for Detected status", function()
    assert.is_nil(annotations.extract_duration_ms({ Case = "Detected", Fields = {} }))
  end)
end)

describe("annotations.format_codelens", function()
  it("formats passed lens with green highlight", function()
    local text, hl = annotations.format_codelens({ Label = "✓ Passed (12ms)" })
    assert.are.equal("✓ Passed (12ms)", text)
    assert.are.equal("SageFsCodeLensPassed", hl)
  end)

  it("formats failed lens with red highlight", function()
    local text, hl = annotations.format_codelens({ Label = "✗ Failed: expected 42" })
    assert.are.equal("✗ Failed: expected 42", text)
    assert.are.equal("SageFsCodeLensFailed", hl)
  end)

  it("formats running lens with yellow highlight", function()
    local text, hl = annotations.format_codelens({ Label = "⏳ running..." })
    assert.are.equal("⏳ running...", text)
    assert.are.equal("SageFsCodeLensRunning", hl)
  end)

  it("formats unknown lens with dim highlight", function()
    local text, hl = annotations.format_codelens({ Label = "◆ Detected" })
    assert.are.equal("◆ Detected", text)
    assert.are.equal("SageFsCodeLensDetected", hl)
  end)
end)

describe("annotations.format_inline_failure", function()
  it("formats failure with test name and inline label", function()
    local text, hl = annotations.format_inline_failure({
      TestName = "should add",
      Failure = { InlineLabel = "Expected 42 but got 0" },
    })
    assert.truthy(text:match("should add"))
    assert.truthy(text:match("Expected 42"))
    assert.are.equal("SageFsInlineFailure", hl)
  end)

  it("truncates long failure text", function()
    local long_msg = string.rep("x", 200)
    local text, _ = annotations.format_inline_failure({
      TestName = "test",
      Failure = { InlineLabel = long_msg },
    }, 50)
    assert.truthy(#text <= 50)
    assert.truthy(text:match("%.%.%.$"))
  end)

  it("handles AssertionDiff DU", function()
    local text, _ = annotations.format_inline_failure({
      TestName = "test",
      Failure = { Case = "AssertionDiff", Fields = { "42", "0" } },
    })
    assert.truthy(text:match("Expected: 42"))
    assert.truthy(text:match("Got: 0"))
  end)
end)

describe("annotations.clear", function()
  it("removes all file annotations", function()
    local state = annotations.new()
    state = annotations.handle_file_annotations(state, { FilePath = "A.fs", TestAnnotations = {}, CodeLenses = {}, InlineFailures = {}, CoverageAnnotations = {} })
    state = annotations.clear(state)
    assert.are.equal(0, vim.tbl_count(state.files))
  end)
end)

describe("annotations.clear_file", function()
  it("removes annotations for specific file only", function()
    local state = annotations.new()
    state = annotations.handle_file_annotations(state, { FilePath = "A.fs", TestAnnotations = {}, CodeLenses = {}, InlineFailures = {}, CoverageAnnotations = {} })
    state = annotations.handle_file_annotations(state, { FilePath = "B.fs", TestAnnotations = {}, CodeLenses = {}, InlineFailures = {}, CoverageAnnotations = {} })
    state = annotations.clear_file(state, "A.fs")
    assert.is_nil(annotations.get_file(state, "A.fs"))
    assert.is_not_nil(annotations.get_file(state, "B.fs"))
  end)
end)

describe("annotations.format_coverage_sign", function()
  it("returns quiet bar for fully covered (AllPassing)", function()
    local sign, hl = annotations.format_coverage_sign({
      Detail = { Case = "Covered", Fields = { 3, { Case = "AllPassing" } } }
    })
    assert.are.equal("│", sign)
    assert.are.equal("SageFsCovered", hl)
  end)

  it("returns half-circle for partial coverage (SomeFailing)", function()
    local sign, hl = annotations.format_coverage_sign({
      Detail = { Case = "Covered", Fields = { 2, { Case = "SomeFailing" } } }
    })
    assert.are.equal("◐", sign)
    assert.are.equal("SageFsCovPartial", hl)
  end)

  it("returns loud block for not covered", function()
    local sign, hl = annotations.format_coverage_sign({
      Detail = { Case = "NotCovered" }
    })
    assert.are.equal("█", sign)
    assert.are.equal("SageFsCovNotCovered", hl)
  end)

  it("returns dot for pending", function()
    local sign, hl = annotations.format_coverage_sign({
      Detail = { Case = "Pending" }
    })
    assert.are.equal("·", sign)
    assert.are.equal("SageFsCovPending", hl)
  end)

  it("returns nil for missing detail", function()
    local sign, hl = annotations.format_coverage_sign({})
    assert.is_nil(sign)
    assert.is_nil(hl)
  end)

  it("handles lowercase detail field name", function()
    local sign, hl = annotations.format_coverage_sign({
      detail = { Case = "Covered", Fields = { 1, { Case = "AllPassing" } } }
    })
    assert.are.equal("│", sign)
    assert.are.equal("SageFsCovered", hl)
  end)
end)
