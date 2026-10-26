-- Tests: what POST /api/completions says about the SIZE of the member set and
-- about being unable to list, and how the type explorer shows it.
--
-- WHY: the daemon used to cut every reply at 50 and say nothing, so a 64-member
-- namespace looked complete at 50, and an empty list meant both "nothing there"
-- and "nobody could look". The reply now carries `total` + `totalKind` and, when
-- it could not look, `unavailable` + `reason`. Every spec that feeds a reply
-- WITHOUT these fields pins that an older daemon renders exactly as before.
require("spec.helper")
local completions = require("sagefs.completions")
local te = require("sagefs.type_explorer")

local function reply(extra)
  local data = {
    completions = {
      { label = "File", kind = "Class", insertText = "File" },
      { label = "Path", kind = "Class", insertText = "Path" },
      { label = "Combine", kind = "Method", insertText = "Combine" },
    },
  }
  for k, v in pairs(extra or {}) do data[k] = v end
  return data
end

describe("completions.listing_of", function()
  it("reads total and totalKind off a reply", function()
    local l = completions.listing_of(reply({ total = 212, totalKind = "exact" }))
    assert.are.equal(212, l.total)
    assert.are.equal("exact", l.total_kind)
    assert.are.equal(3, #l.completions)
  end)

  it("reads atLeast as its own kind", function()
    local l = completions.listing_of(reply({ total = 2000, totalKind = "atLeast" }))
    assert.are.equal("atLeast", l.total_kind)
  end)

  it("reads unavailable and reason", function()
    local l = completions.listing_of({
      completions = {}, count = 0,
      unavailable = "SessionNotActive", reason = "the session is not active",
    })
    assert.are.same({ word = "SessionNotActive", reason = "the session is not active" }, l.unavailable)
  end)

  it("states no size and no unavailability for an older daemon's reply", function()
    local l = completions.listing_of(reply())
    assert.is_nil(l.total)
    assert.is_nil(l.total_kind)
    assert.is_nil(l.unavailable)
    assert.are.equal(3, #l.completions)
  end)

  it("ignores a totalKind it does not know, because a size it cannot read is not a claim", function()
    local l = completions.listing_of(reply({ total = 9, totalKind = "roughly" }))
    assert.is_nil(l.total_kind)
    assert.is_nil(completions.size_line(l))
  end)

  it("ignores a total that is not a number", function()
    local l = completions.listing_of(reply({ total = "many", totalKind = "exact" }))
    assert.is_nil(l.total)
  end)

  it("gives an empty listing for nil or a reply with no completions field", function()
    assert.are.same({}, completions.listing_of(nil).completions)
    assert.are.same({}, completions.listing_of({ other = 1 }).completions)
  end)
end)

describe("completions.size_line", function()
  it("says Showing N of M when an exact total exceeds the items", function()
    local l = completions.listing_of(reply({ total = 64, totalKind = "exact" }))
    assert.are.equal("Showing 3 of 64", completions.size_line(l))
  end)

  it("says at least when the total is a floor", function()
    local l = completions.listing_of(reply({ total = 2000, totalKind = "atLeast" }))
    assert.are.equal("Showing 3 of at least 2000", completions.size_line(l))
  end)

  it("says nothing when an exact total equals what is shown", function()
    local l = completions.listing_of(reply({ total = 3, totalKind = "exact" }))
    assert.is_nil(completions.size_line(l))
  end)

  it("says nothing for an older daemon's reply", function()
    assert.is_nil(completions.size_line(completions.listing_of(reply())))
  end)
end)

describe("completions.unavailable_line", function()
  it("carries the daemon's reason", function()
    local l = completions.listing_of({
      completions = {}, unavailable = "HostLost", reason = "the session's F# host is gone",
    })
    assert.are.equal("Could not list members: the session's F# host is gone", completions.unavailable_line(l))
  end)

  it("still says it could not list when the reason is missing", function()
    local l = completions.listing_of({ completions = {}, unavailable = "HostLost" })
    assert.are.equal("Could not list members: HostLost", completions.unavailable_line(l))
  end)

  it("is nil for a reply that could list, empty or not", function()
    assert.is_nil(completions.unavailable_line(completions.listing_of({ completions = {} })))
    assert.is_nil(completions.unavailable_line(completions.listing_of(reply())))
  end)
end)

describe("requests", function()
  it("the popup asks for no limit, so the daemon's short default stays what it wants", function()
    local body = completions.build_request_body("let x = List.", 13, "/work")
    assert.is_nil(body.limit)
  end)

  it("the explorer asks for a limit", function()
    local body = te.build_request_body("System.IO")
    assert.are.equal("System.IO.", body.code)
    assert.are.equal(#"System.IO.", body.cursor_position)
    assert.are.equal(te.ROWS_REQUESTED, body.limit)
    assert.is_true(te.ROWS_REQUESTED > 50)
    assert.is_true(te.ROWS_REQUESTED <= 2000)
  end)
end)

describe("type_explorer.format_completions with a listing", function()
  local items = reply().completions

  it("appends a Showing N of M row that is not a member", function()
    local l = completions.listing_of(reply({ total = 64, totalKind = "exact" }))
    local rows = te.format_completions(items, l)
    local last = rows[#rows]
    assert.are.equal("Showing 3 of 64", last.label)
    assert.is_false(last.drillable)
    assert.is_true(last.note)
    assert.are.equal(4, #rows)
  end)

  it("says at least for a floor", function()
    local l = completions.listing_of(reply({ total = 2000, totalKind = "atLeast" }))
    local rows = te.format_completions(items, l)
    assert.are.equal("Showing 3 of at least 2000", rows[#rows].label)
  end)

  it("renders an older daemon's reply exactly as before", function()
    local l = completions.listing_of(reply())
    assert.are.same(te.format_completions(items), te.format_completions(items, l))
    assert.are.equal(3, #te.format_completions(items, l))
  end)
end)

describe("type_explorer.format_members_panel with a listing", function()
  local items = reply().completions

  it("puts the Showing N of M line under the header", function()
    local l = completions.listing_of(reply({ total = 64, totalKind = "exact" }))
    local lines = te.format_members_panel("System.IO", items, l)
    assert.truthy(lines[1]:find("System.IO", 1, true))
    assert.are.equal("Showing 3 of 64", lines[3])
  end)

  it("says at least for a floor", function()
    local l = completions.listing_of(reply({ total = 2000, totalKind = "atLeast" }))
    local lines = te.format_members_panel("System", items, l)
    assert.truthy(table.concat(lines, "\n"):find("Showing 3 of at least 2000", 1, true))
  end)

  it("shows the reason, and no empty list, when the daemon could not look", function()
    local l = completions.listing_of({
      completions = {}, unavailable = "SessionNotActive", reason = "the session is not active",
    })
    local text = table.concat(te.format_members_panel("System.IO", {}, l), "\n")
    assert.truthy(text:find("Could not list members: the session is not active", 1, true))
  end)

  it("renders an older daemon's reply exactly as before", function()
    local l = completions.listing_of(reply())
    assert.are.same(te.format_members_panel("System.IO", items), te.format_members_panel("System.IO", items, l))
  end)
end)

describe("type_explorer drillable kinds", function()
  -- The daemon's McpMemberKinds.rungOf calls these Drillable; everything else is a leaf.
  local drillable = { "Namespace", "Module", "Class", "Struct", "Interface", "Enum", "Union", "Type" }
  local leaves = { "Constant", "Delegate", "EnumMember", "Event", "Exception", "Field", "Method",
    "OverriddenMethod", "Property", "Typedef", "Variable", "ExtensionMethod", "TypeParameter",
    "Keyword", "Folder", "File" }

  it("marks exactly the daemon's drillable kinds", function()
    for _, k in ipairs(drillable) do
      assert.is_true(te.format_completions({ { label = "x", kind = k } })[1].drillable, k)
    end
    for _, k in ipairs(leaves) do
      assert.is_false(te.format_completions({ { label = "x", kind = k } })[1].drillable, k)
    end
  end)
end)
