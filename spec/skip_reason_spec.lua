-- A skipped test says why. The daemon's Expecto executor skips a pending test
-- (ptest) with "pending (ptest)" and, when anything is focused (ftest), every other
-- test with "not focused" (SageFs be781645). The reason rides on the status:
--   Status: {"Case":"Skipped","Fields":["pending (ptest)"]}
-- The plugin kept the case and dropped the reason, so a stray ftest turned every other
-- test into a bare ⊘ with no word about it.
require("spec.helper")
local testing = require("sagefs.testing")

local function entry(id, name, status_case, fields)
  return {
    TestId = id, DisplayName = name, FullName = "M/" .. name,
    Origin = { Case = "SourceMapped", Fields = { "/w/T.fs", 8 } },
    Framework = { Case = "Expecto" }, Category = { Case = "Unit" },
    CurrentPolicy = { Case = "OnEveryChange" },
    Status = { Case = status_case, Fields = fields },
    PreviousStatus = { Case = "Detected" },
    Provenance = { Case = "Evaluated" },
  }
end

local function batch(...)
  return { Entries = { ... }, Completion = { Case = "Complete", Fields = { 3, 3 } } }
end

describe("testing.normalize_entry keeps the skip reason", function()
  it("reads the reason of a PascalCase entry and still unwraps the status to its case", function()
    local n = testing.normalize_entry(entry("t1", "a ptest", "Skipped", { "pending (ptest)" }))
    assert.are.equal("Skipped", n.status)
    assert.are.equal("pending (ptest)", n.skipReason)
  end)

  it("reads the reason of an entry that already has camelCase keys", function()
    local n = testing.normalize_entry({ testId = "t1", status = { Case = "Skipped", Fields = { "not focused" } } })
    assert.are.equal("Skipped", n.status)
    assert.are.equal("not focused", n.skipReason)
  end)

  it("has no reason for a status that is not Skipped, or a Skipped one the daemon left unexplained", function()
    assert.is_nil(testing.normalize_entry(entry("t1", "x", "Passed", { "00:00:00.001" })).skipReason)
    assert.is_nil(testing.normalize_entry(entry("t1", "x", "Skipped", nil)).skipReason)
    assert.is_nil(testing.normalize_entry(entry("t1", "x", "Skipped", { "" })).skipReason)
    assert.is_nil(testing.normalize_entry(entry("t1", "x", "Skipped", { 7 })).skipReason)
  end)
end)

describe("testing state keeps the skip reason per test", function()
  it("stores it from a results batch", function()
    local s = testing.handle_results_batch(testing.new(), batch(
      entry("t1", "a ptest", "Skipped", { "pending (ptest)" }),
      entry("t2", "a plain test", "Passed", { "00:00:00.001" })))
    assert.are.equal("Skipped", s.tests.t1.status)
    assert.are.equal("pending (ptest)", s.tests.t1.skip_reason)
    assert.is_nil(s.tests.t2.skip_reason)
  end)

  it("forgets it when the test runs after all", function()
    local s = testing.handle_results_batch(testing.new(), batch(entry("t1", "a test", "Skipped", { "not focused" })))
    s = testing.handle_results_batch(s, batch(entry("t1", "a test", "Passed", { "00:00:00.001" })))
    assert.are.equal("Passed", s.tests.t1.status)
    assert.is_nil(s.tests.t1.skip_reason)
  end)
end)

describe("a skipped test says why in the lists", function()
  local function state()
    return testing.handle_results_batch(testing.new(), batch(
      entry("t1", "a ptest", "Skipped", { "pending (ptest)" }),
      entry("t2", "a plain test", "Passed", { "00:00:00.001" }),
      entry("t3", "no reason given", "Skipped", nil)))
  end

  it("format_test_list appends the reason", function()
    local lines = testing.format_test_list(state())
    local joined = table.concat(lines, "\n")
    assert.truthy(joined:find("⊘ a ptest (skipped: pending (ptest))", 1, true))
    assert.truthy(joined:find("✓ a plain test", 1, true))
    assert.is_nil(joined:find("✓ a plain test (", 1, true))
  end)

  it("a skipped test with no reason stays a bare ⊘ line", function()
    local lines = testing.format_test_list(state())
    local found
    for _, l in ipairs(lines) do if l:find("no reason given", 1, true) then found = l end end
    assert.are.equal("⊘ no reason given", found)
  end)

  it("format_panel_entries appends the reason and keeps the navigation", function()
    local entries = testing.format_panel_entries(state())
    local found
    for _, e in ipairs(entries) do if e.text:find("a ptest", 1, true) then found = e end end
    assert.are.equal("⊘ a ptest (skipped: pending (ptest))", found.text)
    assert.are.equal("/w/T.fs", found.file)
    assert.are.equal(8, found.line)
  end)

  it("format_scoped_panel_entries appends the reason", function()
    local entries = testing.format_scoped_panel_entries(state(), { kind = "all" })
    local found
    for _, e in ipairs(entries) do if e.text:find("a ptest", 1, true) then found = e end end
    assert.are.equal("⊘ a ptest (skipped: pending (ptest))", found.text)
  end)
end)
