-- A closed set is a table of named constants plus a membership test, so a
-- state the daemon names is spelled in exactly one place on this side and a
-- token the daemon invents later is visible instead of silently accepted.
require("spec.helper")
local closed_set = require("sagefs.closed_set")

describe("closed_set.define", function()
  it("exposes each name as a constant equal to its token", function()
    local s = closed_set.define("Light", { "Red", "Green" })
    assert.are.equal("Red", s.Red)
    assert.are.equal("Green", s.Green)
    assert.are.equal("Light", s.name)
  end)

  it("keeps the declaration order in .all", function()
    local s = closed_set.define("Light", { "Red", "Amber", "Green" })
    assert.are.same({ "Red", "Amber", "Green" }, s.all)
  end)

  it("answers membership by token, and refuses a token it was not given", function()
    local s = closed_set.define("Light", { "Red", "Green" })
    assert.is_true(s.has("Red"))
    assert.is_false(s.has("Blue"))
    assert.is_false(s.has(nil))
    assert.is_false(s.has(42))
  end)

  it("lets a name carry a different wire token, with the empty string allowed", function()
    local s = closed_set.define("Mechanism", {
      { "Detour", "detour" },
      { "MetadataDelta", "metadata-delta" },
      { "NoPatch", "" },
    })
    assert.are.equal("detour", s.Detour)
    assert.are.equal("metadata-delta", s.MetadataDelta)
    assert.are.equal("", s.NoPatch)
    assert.is_true(s.has("metadata-delta"))
    assert.is_true(s.has(""))
    assert.is_false(s.has("MetadataDelta"))
  end)

  it("maps a token back to its name so display code can branch on names", function()
    local s = closed_set.define("Mechanism", { { "MetadataDelta", "metadata-delta" } })
    assert.are.equal("MetadataDelta", s.name_of("metadata-delta"))
    assert.is_nil(s.name_of("telepathy"))
  end)

  it("refuses a duplicate name or token at definition time", function()
    assert.has_error(function() closed_set.define("Bad", { "A", "A" }) end)
    assert.has_error(function() closed_set.define("Bad", { { "A", "x" }, { "B", "x" } }) end)
  end)
end)
