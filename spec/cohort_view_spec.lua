-- sagefs/cohort_view_spec.lua — the cohort panel asks for the RIGHT cohort
--
-- WHY THIS EXISTS: `get_cohort_status` gained a `working_directory` parameter because one
-- daemon now holds one cohort PER REPOSITORY, each with its own conductor seat. A caller
-- that omits it reads the cohort of the directory the DAEMON started in — so a user with
-- two repositories open saw the wrong repository's members, claims and conductor, with
-- nothing on screen to say so. That is a client bug worth making impossible to reintroduce
-- silently, which is what pinning the argument does.
--
-- `refresh` reaches a live buffer and a connected MCP client, so it is not unit-testable;
-- the decision it makes is `status_args`, which is, and that is what these cases pin.

require("spec.helper")
local view = require("sagefs.cohort_view")
local cohort = require("sagefs.cohort")
local fx = require("spec.wire_fixtures")

describe("cohort_view.status_args", function()
  it("names the directory the user is in, so the panel shows that repository's cohort", function()
    local args = view.status_args("/home/will/Work/nehemiah")
    assert.are.equal("/home/will/Work/nehemiah", args.working_directory)
  end)

  it("sends an EMPTY STRING, never nil", function()
    -- A nil is dropped from the JSON object entirely, and the daemon then reads its OWN
    -- cohort — silently. An empty string is what the tool's DefaultParameterValue("")
    -- turns into "the caller named none", which is honest.
    local args = view.status_args(nil)
    assert.is_not_nil(args.working_directory)
    assert.are.equal("", args.working_directory)
  end)

  it("treats an empty cwd the same way, for the same reason", function()
    local args = view.status_args("")
    assert.are.equal("", args.working_directory)
  end)
end)

describe("cohort_view.complete_ids: what an action's tab completion offers", function()
  -- The four cohort actions take a member id or a landing id, and a completion
  -- that offers an id the daemon will refuse is worse than one that offers none:
  -- the person typed it believing the tool had said it was good. So the ids come
  -- from the last status this view actually parsed, and from nothing else.
  local model = cohort.parse_status(fx.read("cohort-status-veto.txt"))

  -- the suite's membership idiom (spec/events_spec.lua): a flag, not a helper that
  -- may not exist in the vim stub
  local function offers(ids, want)
    for _, id in ipairs(ids) do
      if id == want then return true end
    end
    return false
  end

  it("offers the member ids to a command that wants a member", function()
    local ids = view.complete_ids(model, "members")
    assert.are.equal(3, #ids)
    assert.is_true(offers(ids, "cap:00112233445566ff"))
  end)

  it("offers the landing ids to a command that wants a landing", function()
    assert.are.same({ "l-1", "l-2" }, view.complete_ids(model, "landings"))
  end)

  it("offers a VETOED landing like any other, because the veto is a reason to act", function()
    assert.is_true(offers(view.complete_ids(model, "landings"), "l-1"))
  end)

  it("offers nothing before anything has been read, rather than a guess", function()
    assert.are.same({}, view.complete_ids(nil, "members"))
    assert.are.same({}, view.complete_ids(nil, "landings"))
  end)

  it("survives a status with no landings, offering the members it does have", function()
    -- The captured idle status has one member and it is DEPARTED: a departed member
    -- is still a row the user reads, so its id is still offered. What matters here is
    -- that the empty landings section does not produce a nil or an error.
    local empty = cohort.parse_status(fx.read("cohort-status-idle.txt"))
    assert.are.same({}, view.complete_ids(empty, "landings"))
    local members = view.complete_ids(empty, "members")
    assert.are.equal(1, #members)
  end)

  it("survives a model with no members list at all", function()
    assert.are.same({}, view.complete_ids({ landings = {} }, "members"))
    assert.are.same({}, view.complete_ids({ members = {} }, "landings"))
  end)
end)
