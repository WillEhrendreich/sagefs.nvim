-- spec/result_provenance_spec.lua — a test row must say when its verdict did not
-- come from this build
--
-- The daemon stamps every test status entry with a Provenance (an F# DU:
-- Compiled | Evaluated | VerifiedByBuild | BuildDisagrees <why>). On the wire it
-- is {"Case":"BuildDisagrees","Fields":[{"Case":"BuildFailed","Fields":["..."]}]}.
--
-- A row whose provenance says the real build disagreed is a GREEN row that no
-- build ever confirmed, which is the one kind of green that misleads. Only that
-- case earns a mark: Evaluated is the normal state of a live session and marking
-- every row would train the eye to ignore the mark.

local testing = require("sagefs.testing")

--- The wire shape a daemon sends for each provenance, exactly as
--- SageFs.Tests/JsonCoreFilesTests.fs writes it.
local function du(case, fields)
  local d = { Case = case }
  if fields then d.Fields = fields end
  return d
end

local function entry(test_id, status, provenance)
  return {
    testId = test_id,
    displayName = test_id,
    status = status,
    provenance = provenance,
  }
end

describe("a test row's provenance is carried, not inferred", function()
  it("keeps the daemon's case name and the why that came with it", function()
    local state = testing.new()
    testing.handle_results_batch(state, {
      entries = {
        entry("t1", "Passed", du("BuildDisagrees", { du("BuildFailed", { "FS0001: no such value" }) })),
      },
      summary = { total = 1, passed = 1, failed = 0, stale = 0, running = 0 },
    })
    assert.are.equal("BuildDisagrees", state.tests["t1"].provenance)
    assert.are.equal("BuildFailed", state.tests["t1"].provenanceReason)
  end)

  it("reads the PascalCase spelling the daemon's other payload uses too", function()
    local state = testing.new()
    testing.handle_results_batch(state, {
      Entries = {
        { TestId = "t1", DisplayName = "t1", Status = du("Passed"), Provenance = du("BuildDisagrees") },
      },
    })
    assert.are.equal("BuildDisagrees", state.tests["t1"].provenance)
  end)

  it("reads the snake_case spelling too, because a JSON round trip can produce it", function()
    local state = testing.new()
    testing.handle_results_batch(state, {
      entries = { entry("t1", "Passed", "build_disagrees") },
    })
    assert.are.equal("build_disagrees", state.tests["t1"].provenance)
  end)

  it("leaves the provenance absent for a daemon that sends none", function()
    local state = testing.new()
    testing.handle_results_batch(state, {
      entries = { entry("t1", "Passed", nil) },
    })
    assert.is_nil(state.tests["t1"].provenance)
  end)
end)

describe("which provenance deserves a mark", function()
  it("marks BuildDisagrees and nothing else", function()
    -- The whole point: exactly ONE of the four cases earns a mark.
    assert.is_true(testing.marked_provenance("BuildDisagrees"))
    assert.is_false(testing.marked_provenance("Evaluated"))
    assert.is_false(testing.marked_provenance("Compiled"))
    assert.is_false(testing.marked_provenance("VerifiedByBuild"))
    assert.is_false(testing.marked_provenance(nil))
    assert.is_false(testing.marked_provenance("banana"))
    assert.is_false(testing.marked_provenance(42))
  end)

  it("marks the wire value spelling too, so a JSON round trip cannot hide it", function()
    -- "build_disagrees" is what ResultProvenance.toWireValue produces. A row
    -- that lost its case name in transit is still a row the build disagreed with;
    -- quietly unmarking it is exactly the misleading-green bug this exists for.
    assert.is_true(testing.marked_provenance("build_disagrees"))
  end)
end)

describe("the mark shows where the status is coloured", function()
  it("turns a BuildDisagrees green row into a marked one", function()
    local plain = testing.gutter_sign("Passed")
    local marked = testing.gutter_sign("Passed", "BuildDisagrees")
    assert.are_not.equals(plain.text, marked.text)
    assert.are_not.equals(plain.hl, marked.hl)
  end)

  it("leaves an Evaluated row exactly as a plain green row", function()
    local plain = testing.gutter_sign("Passed")
    local evaluated = testing.gutter_sign("Passed", "Evaluated")
    assert.are.equal(plain.text, evaluated.text)
    assert.are.equal(plain.hl, evaluated.hl)
  end)

  it("keeps the mark loud on a Failed row too", function()
    local plain = testing.gutter_sign("Failed")
    local marked = testing.gutter_sign("Failed", "BuildDisagrees")
    assert.are_not.equals(plain.hl, marked.hl)
  end)

  it("still says pass or fail in words when the row is marked", function()
    -- The mark must not swallow the status: a user who cannot see the colour
    -- still has to know the row passed.
    local marked = testing.gutter_sign("Passed", "BuildDisagrees")
    assert.is_truthy(marked.status)
    assert.are.equal("Passed", marked.status)
  end)
end)