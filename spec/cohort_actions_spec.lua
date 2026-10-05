-- The cohort action commands: the arguments each MCP tool call needs, and the
-- one refusal that is checked before any of them is sent.
--
-- Every one of these tools takes a `working_directory`, and the tool reads an
-- omitted one as "the cohort of the directory the DAEMON started in" (see
-- cohort_view.status_args). So a command that does not name the directory acts in
-- the wrong repository, silently. That is why the builders below take the cwd and
-- always emit it, never nil: a nil drops the key from the JSON object entirely.
require("spec.helper")
local A = require("sagefs.cohort_actions")

describe("cohort_actions: every action names the repository it acts in", function()
  it("delegates the conductor seat with the agent, the new conductor and the directory", function()
    assert.same({
      agentName = "alice",
      toMember = "bob",
      working_directory = "/repo",
    }, A.delegate_args("alice", "bob", "/repo"))
  end)

  it("vetoes a landing with a reason", function()
    assert.same({
      agentName = "alice",
      landingId = "l-1",
      reason = "the landing drops the retry",
      working_directory = "/repo",
    }, A.veto_args("alice", "l-1", "the landing drops the retry", "/repo"))
  end)

  it("resolves a veto", function()
    assert.same({
      agentName = "alice",
      landingId = "l-1",
      working_directory = "/repo",
    }, A.resolve_args("alice", "l-1", "/repo"))
  end)

  it("withdraws a landing", function()
    assert.same({
      agentName = "alice",
      landingId = "l-1",
      working_directory = "/repo",
    }, A.withdraw_args("alice", "l-1", "/repo"))
  end)

  it("names an empty directory rather than dropping the key, because a nil is read as the daemon's own repo", function()
    local args = A.veto_args("alice", "l-1", "why", nil)
    assert.are.equal("", args.working_directory)
    assert.is_not_nil(args.working_directory)
  end)
end)

describe("cohort_actions: what is refused before a call goes out", function()
  it("refuses an empty reason, and says what the tool wants", function()
    local why = A.check_veto("", "l-1")
    assert.truthy(why ~= nil)
    assert.truthy(why:find("reason", 1, true))
  end)

  it("refuses a reason over the tool's 1000 characters, naming the length it was given", function()
    local long = string.rep("x", 1001)
    local why = A.check_veto(long, "l-1")
    assert.truthy(why ~= nil)
    assert.truthy(why:find("1001", 1, true))
  end)

  it("refuses a missing landing id, because the tool cannot act without one", function()
    assert.truthy(A.check_veto("a real reason", nil) ~= nil)
    assert.truthy(A.check_veto("a real reason", "") ~= nil)
  end)

  it("accepts a reason of exactly the limit, because the tool's bound is inclusive", function()
    assert.is_nil(A.check_veto(string.rep("x", 1000), "l-1"))
  end)

  it("accepts a one character reason", function()
    assert.is_nil(A.check_veto("x", "l-1"))
  end)

  it("refuses a missing agent name on any action, since the tool checks it against the caller", function()
    assert.truthy(A.check_agent(nil, "delegate") ~= nil)
    assert.truthy(A.check_agent("", "veto") ~= nil)
  end)
end)

describe("cohort_actions: the commands it registers", function()
  it("has one per tool, and each names the tool it calls", function()
    local names = A.commands()
    local by_name = {}
    for _, c in ipairs(names) do by_name[c.name] = c end
    assert.truthy(by_name["SageFsCohortDelegate"] ~= nil)
    assert.truthy(by_name["SageFsCohortVeto"] ~= nil)
    assert.truthy(by_name["SageFsCohortResolveVeto"] ~= nil)
    assert.truthy(by_name["SageFsCohortWithdraw"] ~= nil)
    assert.are.equal("delegate_conductor", by_name["SageFsCohortDelegate"].tool)
    assert.are.equal("veto_landing", by_name["SageFsCohortVeto"].tool)
    assert.are.equal("resolve_veto", by_name["SageFsCohortResolveVeto"].tool)
    assert.are.equal("withdraw_landing", by_name["SageFsCohortWithdraw"].tool)
  end)

  it("knows how many arguments each one wants, because the handler checks the count itself", function()
    -- NOT `nargs`: Neovim refuses a numeric nargs above 1 ("Invalid 'nargs': 2"),
    -- which real Neovim caught. The count is checked in the handler so the message
    -- can say WHICH argument is missing.
    local by_name = {}
    for _, c in ipairs(A.commands()) do by_name[c.name] = c end
    assert.are.equal(3, by_name["SageFsCohortVeto"].arity)
    assert.are.equal(2, by_name["SageFsCohortDelegate"].arity)
    assert.are.equal(2, by_name["SageFsCohortResolveVeto"].arity)
    assert.are.equal(2, by_name["SageFsCohortWithdraw"].arity)
    for _, c in ipairs(A.commands()) do
      assert.is_nil(c.nargs, c.name .. " must not carry a numeric nargs")
    end
  end)
end)

describe("cohort_actions.split_args: one split, so the checked string is the sent string", function()
  it("takes the agent first, then the landing id, then the reason as the rest of the line", function()
    local agent, id, reason = A.split_args({ "alice", "l-1", "the", "landing", "drops", "the", "retry" })
    assert.are.equal("alice", agent)
    assert.are.equal("l-1", id)
    assert.are.equal("the landing drops the retry", reason)
  end)

  it("joins the reason with single spaces, so a doubled space does not become two", function()
    -- the handler splits on "%s+" so this cannot arise from a command line, but
    -- the function is also called with a hand-built list, and the bound it feeds
    -- is a CHARACTER count
    local _, _, reason = A.split_args({ "alice", "l-1", "a", "", "b" })
    assert.are.equal("a b", reason)
  end)

  it("gives an empty reason when none was typed, rather than nil", function()
    local agent, id, reason = A.split_args({ "alice", "l-1" })
    assert.are.equal("alice", agent)
    assert.are.equal("l-1", id)
    assert.are.equal("", reason)
  end)

  it("gives empty strings for an empty command, so check_veto's own message is the one that reads", function()
    local agent, id, reason = A.split_args({})
    assert.are.equal("", agent)
    assert.are.equal("", id)
    assert.are.equal("", reason)
  end)

  it("counts the JOINED reason against the tool's 1000 character bound", function()
    -- 600 words is 1200 characters joined, which the tool refuses. Checking one
    -- word would pass it.
    local parts = { "alice", "l-1" }
    for _ = 1, 600 do table.insert(parts, "word") end
    local _, _, reason = A.split_args(parts)
    assert.is_true(#reason > A.REASON_MAX)
    assert.truthy(A.check_veto(reason, "l-1") ~= nil, "the joined reason is what gets refused")
  end)
end)

describe("cohort_actions.check_arity: a short command says which argument is missing", function()
  local U = "SageFsCohortVeto <agent> <landing> <reason>"

  it("accepts exactly the arguments it needs", function()
    assert.is_nil(A.check_arity({ "alice", "l-1", "because" }, 3, U))
  end)

  it("accepts more than it needs, because a veto reason may hold spaces", function()
    assert.is_nil(A.check_arity({ "alice", "l-1", "the landing", "drops", "the retry" }, 3, U))
  end)

  it("names the reason when a veto is given only the agent", function()
    local why = A.check_arity({ "alice" }, 3, U)
    assert.truthy(why ~= nil)
    assert.truthy(why:find("the landing id", 1, true))
    assert.truthy(why:find("the reason", 1, true))
    assert.truthy(why:find(U, 1, true), "it repeats the usage")
  end)

  it("names the count it wanted and the count it got", function()
    local why = A.check_arity({ "alice", "l-1" }, 3, U)
    assert.truthy(why:find("3", 1, true))
    assert.truthy(why:find("2", 1, true))
  end)

  it("is checked before the agent name, so an empty command says what is missing rather than blaming the agent", function()
    -- Otherwise `:SageFsCohortVeto` with nothing at all reports a missing agent,
    -- which is true and useless: three arguments are missing, and that is the
    -- whole message.
    local why = A.check_arity({}, 3, U)
    assert.truthy(why:find("the agent name", 1, true))
  end)
end)
