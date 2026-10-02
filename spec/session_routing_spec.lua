require("spec.helper")
local sessions = require("sagefs.sessions")

-- Eval routes by working directory. A session belongs to a directory, and a
-- git worktree is its own boundary (SageFs AGENTS.md, "Multi-agent / worktree
-- sessions"): a session at the main checkout is not the session of a worktree
-- nested under it, even though the paths nest textually. The plugin never
-- silently evaluates in another directory's session.

local function sess(id, dir, status, project)
  return {
    id = id,
    name = project or id,
    status = status or "Ready",
    projects = { (project or "App") .. ".fsproj" },
    working_directory = dir,
    eval_count = 0,
  }
end

describe("sagefs.sessions.route", function()
  it("matches the session whose working directory is the project directory", function()
    local r = sessions.route({ sess("a1", "/work/app") }, { file = "/work/app/src/A.fs", cwd = "/work/app", root = "/work/app" })
    assert.are.equal("match", r.kind)
    assert.are.equal("a1", r.session.id)
  end)

  it("matches a session rooted above the file inside the same checkout", function()
    local r = sessions.route({ sess("a1", "/work/app") }, { file = "/work/app/src/deep/A.fs", cwd = "/work/app", root = "/work/app" })
    assert.are.equal("match", r.kind)
  end)

  it("matches a session rooted in a subdirectory that contains the file", function()
    local r = sessions.route({ sess("a1", "/work/app/src") }, { file = "/work/app/src/A.fs", cwd = "/work/app", root = "/work/app" })
    assert.are.equal("match", r.kind)
  end)

  it("says none when the only sessions belong to other directories", function()
    local list = { sess("a1", "/work/other"), sess("b2", "/work/third") }
    local r = sessions.route(list, { file = "/work/app/src/A.fs", cwd = "/work/app", root = "/work/app" })
    assert.are.equal("none", r.kind)
    assert.are.equal(2, #r.others)
    assert.are.equal("/work/app", r.dir)
  end)

  it("says none on a daemon with no sessions at all", function()
    local r = sessions.route({}, { file = "/work/app/A.fs", cwd = "/work/app", root = "/work/app" })
    assert.are.equal("none", r.kind)
    assert.are.equal(0, #r.others)
  end)

  describe("a git worktree is a routing boundary", function()
    local main = "/work/app"
    local wt = "/work/app/.claude/worktrees/agent-x"

    it("does not route a worktree file to the main checkout's session", function()
      local r = sessions.route({ sess("main1", main) }, { file = wt .. "/src/A.fs", cwd = wt, root = wt })
      assert.are.equal("none", r.kind)
    end)

    it("routes a worktree file to the worktree's own session", function()
      local r = sessions.route({ sess("main1", main), sess("wt1", wt) }, { file = wt .. "/src/A.fs", cwd = wt, root = wt })
      assert.are.equal("match", r.kind)
      assert.are.equal("wt1", r.session.id)
    end)

    it("still routes the main checkout's file to the main session", function()
      local r = sessions.route({ sess("main1", main), sess("wt1", wt) }, { file = main .. "/src/A.fs", cwd = main, root = main })
      assert.are.equal("main1", r.session.id)
    end)
  end)

  describe("choosing among several candidates", function()
    it("prefers the deepest working directory", function()
      local r = sessions.route(
        { sess("outer", "/work/app"), sess("inner", "/work/app/src") },
        { file = "/work/app/src/A.fs", cwd = "/work/app", root = "/work/app" })
      assert.are.equal("inner", r.session.id)
    end)

    it("prefers the active session when two share a directory", function()
      local list = { sess("a1", "/work/app"), sess("a2", "/work/app") }
      local r = sessions.route(list, { file = "/work/app/A.fs", cwd = "/work/app", root = "/work/app", active_id = "a2" })
      assert.are.equal("a2", r.session.id)
    end)

    it("prefers the one session that is Ready when two share a directory", function()
      local list = { sess("a1", "/work/app", "WarmingUp"), sess("a2", "/work/app", "Ready") }
      local r = sessions.route(list, { file = "/work/app/A.fs", cwd = "/work/app", root = "/work/app" })
      assert.are.equal("a2", r.session.id)
    end)

    it("calls it ambiguous rather than guessing", function()
      local list = { sess("a1", "/work/app"), sess("a2", "/work/app") }
      local r = sessions.route(list, { file = "/work/app/A.fs", cwd = "/work/app", root = "/work/app" })
      assert.are.equal("ambiguous", r.kind)
      assert.are.equal(2, #r.candidates)
    end)
  end)

  it("never matches a stopped session", function()
    local r = sessions.route({ sess("a1", "/work/app", "Stopped") }, { file = "/work/app/A.fs", cwd = "/work/app", root = "/work/app" })
    assert.are.equal("none", r.kind)
  end)

  it("honours an explicit override to a session in another directory", function()
    local r = sessions.route({ sess("a1", "/work/other") },
      { file = "/work/app/A.fs", cwd = "/work/app", root = "/work/app", override_id = "a1" })
    assert.are.equal("match", r.kind)
    assert.are.equal("a1", r.session.id)
  end)

  it("ignores an override that names a session that is gone", function()
    local r = sessions.route({ sess("a1", "/work/other") },
      { file = "/work/app/A.fs", cwd = "/work/app", root = "/work/app", override_id = "zzz" })
    assert.are.equal("none", r.kind)
  end)

  it("normalises case and separators the way Windows paths need", function()
    local r = sessions.route({ sess("a1", "C:\\Code\\App") }, { file = "c:/code/app/src/A.fs", cwd = "c:/code/app", root = "c:/code/app" })
    assert.are.equal("match", r.kind)
  end)

  it("does not let a sibling with a shared prefix match (app vs app2)", function()
    local r = sessions.route({ sess("a1", "/work/app") }, { file = "/work/app2/A.fs", cwd = "/work/app2", root = "/work/app2" })
    assert.are.equal("none", r.kind)
  end)

  it("falls back to the working directory when the buffer has no file", function()
    local r = sessions.route({ sess("a1", "/work/app") }, { cwd = "/work/app" })
    assert.are.equal("match", r.kind)
  end)

  it("works without a git root (not a checkout): plain containment", function()
    local r = sessions.route({ sess("a1", "/work/app") }, { file = "/work/app/A.fs", cwd = "/work/app" })
    assert.are.equal("match", r.kind)
  end)
end)

describe("sagefs.sessions.overview_lines", function()
  it("says which sessions exist, with id, project, directory and status", function()
    local lines = sessions.overview_lines({
      sess("ab12cd34ef56", "/work/other", "Ready", "DemoEnv"),
      sess("99887766aabb", "/work/third", "WarmingUp", "Api"),
    })
    assert.are.equal(2, #lines)
    assert.is_truthy(lines[1]:find("ab12cd34", 1, true))
    assert.is_truthy(lines[1]:find("DemoEnv", 1, true))
    assert.is_truthy(lines[1]:find("/work/other", 1, true))
    assert.is_truthy(lines[1]:find("Ready", 1, true))
    assert.is_truthy(lines[2]:find("WarmingUp", 1, true))
  end)

  it("caps the list and says how many were left out", function()
    local list = {}
    for i = 1, 9 do list[i] = sess("id" .. i, "/work/d" .. i) end
    local lines = sessions.overview_lines(list, 5)
    assert.are.equal(6, #lines)
    assert.is_truthy(lines[6]:find("4 more", 1, true))
  end)
end)

describe("sagefs.sessions.no_session_message", function()
  it("names the directory, says nothing was sent, and counts the other sessions", function()
    local msg = sessions.no_session_message("/work/app", { sess("a1", "/work/other"), sess("b2", "/work/third") })
    assert.is_truthy(msg:find("/work/app", 1, true))
    assert.is_truthy(msg:find("No active session for this directory", 1, true))
    assert.is_truthy(msg:find("2 other", 1, true))
    assert.is_truthy(msg:find("nothing was sent", 1, true))
  end)

  it("is quiet about other sessions when there are none", function()
    local msg = sessions.no_session_message("/work/app", {})
    assert.is_falsy(msg:find("other", 1, true))
  end)
end)

describe("sagefs.sessions.picker_label", function()
  it("shows the working directory and short id so two sessions of one project can be told apart", function()
    local label = sessions.picker_label(sess("ab12cd34ef56", "/work/wt-one", "Ready", "DemoEnv"))
    assert.is_truthy(label:find("/work/wt-one", 1, true))
    assert.is_truthy(label:find("ab12cd34", 1, true))
    assert.is_truthy(label:find("DemoEnv.fsproj", 1, true))
  end)

  it("gives two sessions of the same project different labels (the picker looks them up by label)", function()
    local a = sessions.picker_label(sess("aaaaaaaa1", "/work/one", "Ready", "DemoEnv"))
    local b = sessions.picker_label(sess("bbbbbbbb2", "/work/two", "Ready", "DemoEnv"))
    assert.are_not.equal(a, b)
  end)

  it("keeps the old line as its prefix, so nothing that read it loses information", function()
    local s = sess("ab12cd34ef56", "/work/wt-one", "Ready", "DemoEnv")
    assert.are.equal(sessions.format_session_line(s), sessions.picker_label(s):sub(1, #sessions.format_session_line(s)))
  end)
end)

-- On a shared daemon, other people's sessions warm up all day. Their
-- warmup_progress events used to drive this editor's message line ("Warming
-- up:" flipping with an empty phase), and the stream of messages produced
-- hit-enter prompts that froze every scheduled callback, including the render
-- of this eval's result.
describe("sagefs.sessions.warmup_event_is_ours", function()
  local active = { id = "mine0001", status = "Ready" }

  it("accepts an event for the active session", function()
    assert.is_true(sessions.warmup_event_is_ours({ sessionId = "mine0001" }, active, false))
  end)

  it("rejects an event for another session", function()
    assert.is_false(sessions.warmup_event_is_ours({ sessionId = "other001" }, active, false))
    assert.is_false(sessions.warmup_event_is_ours({ SessionId = "other001" }, active, true))
  end)

  it("rejects an event with no session id when our session is Ready and we expect nothing", function()
    assert.is_false(sessions.warmup_event_is_ours({ Phase = "creating_fsi" }, active, false))
  end)

  it("accepts an event with no session id while our own session is warming", function()
    assert.is_true(sessions.warmup_event_is_ours({ Phase = "creating_fsi" }, { id = "x", status = "WarmingUp" }, false))
    assert.is_true(sessions.warmup_event_is_ours({ Phase = "creating_fsi" }, { id = "x", status = "Starting" }, false))
  end)

  it("accepts events while we have just created a session and have none active yet", function()
    assert.is_true(sessions.warmup_event_is_ours({ Phase = "creating_fsi" }, nil, true))
    assert.is_true(sessions.warmup_event_is_ours({ sessionId = "new00001" }, nil, true))
  end)

  it("rejects everything when we have no session and expect none", function()
    assert.is_false(sessions.warmup_event_is_ours({ Phase = "creating_fsi" }, nil, false))
    assert.is_false(sessions.warmup_event_is_ours({ sessionId = "new00001" }, nil, false))
  end)
end)

-- A shared daemon has many sessions with long temp-directory paths; the
-- picker lines wrapped over three terminal rows each.
describe("sagefs.sessions.compact_label", function()
  it("fits one terminal row: project file name, short id, status, the tail of the directory", function()
    local s = sess("ab12cd34ef56", "/tmp/claude-1000/-home-will-Work/48b15843-64fb-4a9f-99ff-fab2923ce52f/scratchpad/rv-demoenv", "Ready", "DemoEnv")
    s.projects = { "/tmp/claude-1000/-home-will-Work/48b15843-64fb-4a9f-99ff-fab2923ce52f/scratchpad/rv-demoenv/DemoEnv.Tests/DemoEnv.Tests.fsproj" }
    local label = sessions.compact_label(s, 72)
    assert.is_true(#label <= 72, #label .. ": " .. label)
    assert.is_truthy(label:find("DemoEnv.Tests.fsproj", 1, true))
    assert.is_truthy(label:find("ab12cd34", 1, true))
    assert.is_truthy(label:find("Ready", 1, true))
    assert.is_truthy(label:find("rv-demoenv", 1, true), "the directory's tail is what tells sessions apart")
  end)

  it("keeps a short directory whole", function()
    local label = sessions.compact_label(sess("ab12cd34ef56", "/work/app", "Ready", "App"), 72)
    assert.is_truthy(label:find("/work/app", 1, true))
    assert.is_falsy(label:find("…", 1, true))
  end)

  it("never loses the id even when the width is tiny", function()
    local label = sessions.compact_label(sess("ab12cd34ef56", "/work/app", "Ready", "App"), 10)
    assert.is_truthy(label:find("ab12cd34", 1, true))
  end)
end)
