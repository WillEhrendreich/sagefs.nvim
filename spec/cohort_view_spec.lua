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
