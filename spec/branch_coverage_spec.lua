-- spec/branch_coverage_spec.lua — Tests for branch coverage gutter signs
local annotations = require("sagefs.annotations")

describe("format_coverage_sign with BranchCoverage", function()
  -- When BranchCoverage is present, it should override the basic detail sign

  it("shows full coverage sign for FullyCovered branch", function()
    local cov = {
      Line = 10,
      Detail = { Case = "Covered", Fields = { 5, { Case = "AllPassing" } } },
      CoveringTestIds = {},
      BranchCoverage = { FullyCovered = {} },
    }
    local sign, hl = annotations.format_coverage_sign(cov)
    assert.are.equal("▐", sign)
    assert.are.equal("SageFsBranchFull", hl)
  end)

  it("shows partial coverage sign for PartiallyCovered branch", function()
    local cov = {
      Line = 10,
      Detail = { Case = "Covered", Fields = { 5, { Case = "AllPassing" } } },
      CoveringTestIds = {},
      BranchCoverage = { PartiallyCovered = { covered = 2, total = 3 } },
    }
    local sign, hl = annotations.format_coverage_sign(cov)
    assert.are.equal("◐", sign)
    assert.are.equal("SageFsBranchPartial", hl)
  end)

  it("shows uncovered sign for NotCovered branch", function()
    local cov = {
      Line = 10,
      Detail = { Case = "Covered", Fields = { 5, { Case = "AllPassing" } } },
      CoveringTestIds = {},
      BranchCoverage = { NotCovered = {} },
    }
    local sign, hl = annotations.format_coverage_sign(cov)
    assert.are.equal("▌", sign)
    assert.are.equal("SageFsBranchNone", hl)
  end)

  it("falls back to Detail when BranchCoverage is nil", function()
    local cov = {
      Line = 10,
      Detail = { Case = "Covered", Fields = { 5, { Case = "AllPassing" } } },
      CoveringTestIds = {},
      BranchCoverage = nil,
    }
    local sign, hl = annotations.format_coverage_sign(cov)
    -- Should use the old logic: Covered + AllPassing = "▸", "SageFsCovered"
    assert.are.equal("▸", sign)
    assert.are.equal("SageFsCovered", hl)
  end)

  it("falls back to Detail when BranchCoverage is vim.NIL (JSON null)", function()
    local cov = {
      Line = 10,
      Detail = { Case = "Covered", Fields = { 5, { Case = "AllPassing" } } },
      CoveringTestIds = {},
      BranchCoverage = vim.NIL,
    }
    local sign, hl = annotations.format_coverage_sign(cov)
    assert.are.equal("▸", sign)
    assert.are.equal("SageFsCovered", hl)
  end)

  it("branch coverage overrides Detail for SomeFailing health", function()
    local cov = {
      Line = 10,
      Detail = { Case = "Covered", Fields = { 3, { Case = "SomeFailing" } } },
      CoveringTestIds = {},
      BranchCoverage = { FullyCovered = {} },
    }
    local sign, hl = annotations.format_coverage_sign(cov)
    -- Branch = fully covered, but tests failing → still show branch full
    assert.are.equal("▐", sign)
    assert.are.equal("SageFsBranchFull", hl)
  end)
end)

describe("format_branch_eol", function()
  it("returns nil when BranchCoverage is nil", function()
    local cov = { BranchCoverage = nil }
    local text = annotations.format_branch_eol(cov)
    assert.is_nil(text)
  end)

  it("returns nil for FullyCovered", function()
    local cov = { BranchCoverage = { FullyCovered = {} } }
    local text = annotations.format_branch_eol(cov)
    assert.is_nil(text)
  end)

  it("returns n/m for PartiallyCovered", function()
    local cov = { BranchCoverage = { PartiallyCovered = { covered = 2, total = 3 } } }
    local text = annotations.format_branch_eol(cov)
    assert.are.equal("2/3", text)
  end)

  it("returns 0/m for NotCovered", function()
    local cov = { BranchCoverage = { NotCovered = {} } }
    local text = annotations.format_branch_eol(cov)
    assert.is_nil(text) -- no EOL for simple not-covered, just the sign
  end)
end)
