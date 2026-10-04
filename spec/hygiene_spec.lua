-- :SageFsHygiene: what agents and orchestrators left behind on this machine, and
-- the dry-run plan of what could be reclaimed.
--
-- The reply comes from the daemon's `get_workspace_hygiene` MCP tool, which has
-- no REST route, so it is read the way :SageFsCohort reads `get_cohort_status`.
-- Two halves are covered here and both matter:
--
--   * the reply that IS a hygiene plan: what is safe to reclaim, what needs a
--     look first, what is in use and why it was left alone.
--   * the reply that is NOT one. The plugin reaches users commit by commit
--     against whatever daemon they last installed, and a daemon too old to have
--     the tool answers with an error, an unknown-tool message, or something
--     unrelated. That half degrades quietly: plain words in a scratch buffer,
--     never a thrown error and never an empty window.
--
-- Reclaiming is NOT here. `tidy_workspace` needs a plan id and confirm=true; a
-- keystroke in an editor is not that decision, so the command says what would
-- reclaim what and stops. The window and the registration are checked in a real
-- Neovim by spec/nvim_harness.lua; this file covers the words and the flow.
require("spec.helper")
local H = require("sagefs.hygiene")
local V = require("sagefs.hygiene_view")

-- ─── The reply a current daemon sends (WorkspaceHygieneRender.renderPlan) ──────

local PLAN = table.concat({
  "Workspace hygiene (dry run, plan 7f3c1a2b)",
  "3 leftover(s) found. 2 safe to reclaim (12.0 KiB), 1 need a look (4.0 KiB).",
  "",
  "Safe to reclaim (2)",
  " agent worktree x2, 8.0 KiB",
  "  .worktrees/claude-9f2  8.0 KiB, 3d 4h old. merged by rebase, so it is safe to reclaim",
  "  .worktrees/copilot-11ab  4.0 KiB, 1d 2h old. only build output differs, so it is safe to reclaim",
  "",
  "Has uncommitted work (1)",
  " agent branch x1, 4.0 KiB",
  "  feature-x  4.0 KiB, 1d 1h old. unmerged commits, so it is never touched",
  "    to keep it: git push origin feature-x",
  "",
  "In use or too young (1)",
  " agent worktree x1, 2.0 KiB",
  "  .worktrees/other-zz  2.0 KiB, 5m old. a session works in it",
  "",
  "To reclaim the 2 safe item(s): tidy_workspace with confirm=true and plan=7f3c1a2b. Anything marked needs-a-look is never touched by tidy.",
}, "\n")

local ABSENT = table.concat({
  "Error: the server does not have that tool.",
  "  The plugin is newer than this daemon.",
}, "\n")

local function fake_client(reply)
  local client = { calls = {} }
  function client.call_tool(name, args, cb)
    table.insert(client.calls, { name = name, args = args })
    cb(reply.ok, reply.text)
  end
  return client
end

local function fake_ui()
  local u = { writes = {}, notes = {}, ref = function() return "/home/will/Work/sagefs.nvim" end }
  u.write = function(lines) table.insert(u.writes, lines) end
  u.notify = function(msg, level) table.insert(u.notes, { msg = msg, level = level }) end
  return u
end

local function last_window(u)
  return table.concat(u.writes[#u.writes], "\n")
end

--- The absent_message lines as one string, so a phrase can be looked for.
local function absent_words(reply)
  return table.concat(H.absent_message(reply), "\n")
end

-- ─── Parsing the reply that is a plan ─────────────────────────────────────────

describe("hygiene.parse", function()
  it("reads the plan id and the counts off the first two lines", function()
    local m = assert(H.parse(PLAN))
    assert.are.equal("7f3c1a2b", m.plan_id)
    assert.are.equal(3, m.total)
    assert.are.equal(2, m.safe_count)
    assert.are.equal("12.0 KiB", m.safe_bytes)
    assert.are.equal(1, m.review_count)
    assert.are.equal("4.0 KiB", m.review_bytes)
    assert.is_true(m.present)
  end)

  it("groups every section under its own heading, with the entries that follow", function()
    local m = assert(H.parse(PLAN))
    local names = {}
    for _, s in ipairs(m.sections) do names[#names + 1] = s.name end
    assert.are.same({ "Safe to reclaim", "Has uncommitted work", "In use or too young" }, names)
    assert.are.same({ 2, 1, 1 }, { m.sections[1].count, m.sections[2].count, m.sections[3].count })
    assert.are.same({ 2, 1, 1 }, { #m.sections[1].items, #m.sections[2].items, #m.sections[3].items })
  end)

  it("reads the group line: what kind of leftover, how many, and their size", function()
    local m = assert(H.parse(PLAN))
    assert.are.equal("agent worktree", m.sections[1].kind)
    assert.are.equal(2, m.sections[1].group_count)
    assert.are.equal("8.0 KiB", m.sections[1].group_bytes)
  end)

  it("reads an entry: the thing, and why the daemon left it", function()
    local m = assert(H.parse(PLAN))
    local first = m.sections[1].items[1]
    assert.are.equal(".worktrees/claude-9f2", first.text)
    assert.is_nil(first.keep)
    -- The reason is what the daemon SAID about the thing, not the whole entry line: the
    -- size and age are already parsed out of it, so repeating them here would assert that
    -- the parser failed to strip them. The fixture line is
    --   "  .worktrees/claude-9f2  8.0 KiB, 3d 4h old. merged by rebase, so it is safe to reclaim"
    -- and `reason` is what follows "old. ".
    assert.truthy(first.reason:find("merged by rebase, so it is safe to reclaim", 1, true), first.reason)
    assert.is_nil(first.reason:find("8.0 KiB", 1, true), "the size belongs to the entry, not the reason")
    assert.truthy(m.sections[3].items[1].reason:find("a session works in it", 1, true))
  end)

  it("keeps the command that saves an item that needs a look", function()
    local m = assert(H.parse(PLAN))
    assert.are.equal("git push origin feature-x", m.sections[2].items[1].keep)
  end)

  it("reads the ...and N more line of a truncated group", function()
    local m = assert(H.parse(PLAN))
    assert.is_nil(m.sections[1].more)
    -- The daemon cuts a kind at its display limit and says how many it hid.
    local truncated = table.concat({
      "Workspace hygiene (dry run, plan 7f3c1a2b)",
      "9 leftover(s) found. 9 safe to reclaim (12.0 KiB), 0 need a look (0 B).",
      "",
      "Safe to reclaim (9)",
      " agent worktree x9, 12.0 KiB",
      "  .worktrees/claude-9f2  8.0 KiB, 3d 4h old. merged by rebase, so it is safe to reclaim",
      "  ...and 8 more",
    }, "\n")
    local t = assert(H.parse(truncated))
    assert.are.equal(9, t.sections[1].count)
    assert.are.equal(9, t.sections[1].group_count)
    assert.are.equal(1, #t.sections[1].items, "only the shown ones are items")
    assert.are.equal(8, t.sections[1].more)
  end)

  it("reads a plan with nothing to reclaim", function()
    local m = assert(H.parse(table.concat({
      "Workspace hygiene (dry run, plan abc123)",
      "0 leftover(s) found. 0 safe to reclaim (0 B), 0 need a look (0 B).",
      "",
      "Nothing is safe to reclaim right now.",
    }, "\n")))
    assert.are.equal("abc123", m.plan_id)
    assert.are.equal(0, m.total)
    assert.are.equal(0, m.safe_count)
    assert.are.same({}, m.sections)
  end)
end)

-- ─── The absent case: a reply that is not a plan ──────────────────────────────

describe("hygiene.parse on a reply that is not a plan", function()
  it("says so in plain text instead of erroring, keeping what the daemon said", function()
    local model, reply = H.parse(ABSENT)
    assert.is_nil(model)
    assert.are.equal(ABSENT, reply, "the reply itself comes back, not an error string")
    local words = absent_words(reply)
    assert.truthy(words:find("the server does not have that tool", 1, true))
    assert.truthy(words:find("newer than the daemon", 1, true))
  end)

  it("never claims a plan id it was not given", function()
    local _, err = H.parse(ABSENT)
    assert.is_nil(H.parse(err))
    assert.is_nil(H.summary_line(err):find("7f3c1a2b", 1, true))
  end)

  it("a refusal naming the tool is absent too, not a failure", function()
    local model, reply = H.parse("Error: tidy_workspace runs only what get_workspace_hygiene showed you.")
    assert.is_nil(model)
    assert.are.equal("Error: tidy_workspace runs only what get_workspace_hygiene showed you.", reply)
    assert.truthy(absent_words(reply):find("newer than the daemon", 1, true))
  end)

  it("an empty, blank or unrelated reply is absent, not a crash", function()
    for _, bad in ipairs({ "", "   ", "no tool here", "{}", "plan" }) do
      local model, reply = H.parse(bad)
      assert.is_nil(model, bad)
      assert.are.equal(bad, reply, bad)
      assert.are.equal("table", type(H.absent_message(reply)), bad)
    end
  end)

  it("a nil reply is absent, not a crash", function()
    local model, reply = H.parse(nil)
    assert.is_nil(model)
    assert.is_nil(reply)
    assert.are.equal("table", type(H.absent_message(nil)))
    assert.are.equal("string", type(H.summary_line(nil)))
  end)
end)

-- ─── Rendering: the plan as it is shown ───────────────────────────────────────

describe("hygiene.render", function()
  local function rendered(text) return table.concat(H.render(text).lines, "\n") end

  it("leads with what the daemon said, so the plan reads as the plan", function()
    local out = rendered(PLAN)
    assert.truthy(out:find("Workspace hygiene (dry run, plan 7f3c1a2b)", 1, true))
    assert.truthy(out:find("3 leftover(s) found. 2 safe to reclaim (12.0 KiB), 1 need a look (4.0 KiB).", 1, true))
  end)

  it("shows every item, the group total, and the command that saves it", function()
    local out = rendered(PLAN)
    assert.truthy(out:find("agent worktree x2, 8.0 KiB", 1, true))
    assert.truthy(out:find(".worktrees/claude-9f2", 1, true))
    assert.truthy(out:find("other-zz", 1, true))
    assert.truthy(out:find("to keep it: git push origin feature-x", 1, true))
  end)

  it("puts the section count in front of the heading, never stranded in brackets", function()
    local out = rendered(PLAN)
    assert.truthy(out:find("2 Safe to reclaim", 1, true))
    assert.is_nil(out:find("(2)", 1, true))
  end)

  it("keeps the sentence that says how to reclaim", function()
    assert.truthy(rendered(PLAN):find("To reclaim the 2 safe item(s)", 1, true))
  end)

  it("says plainly that the view reclaimed nothing", function()
    local out = rendered(PLAN)
    assert.truthy(out:find("read-only", 1, true))
    assert.truthy(out:find("It reclaimed nothing", 1, true))
  end)

  it("never offers a reclaim the daemon did not describe", function()
    local out = rendered(table.concat({
      "Workspace hygiene (dry run, plan abc123)",
      "0 leftover(s) found. 0 safe to reclaim (0 B), 0 need a look (0 B).",
      "",
      "Nothing is safe to reclaim right now.",
    }, "\n"))
    assert.is_nil(out:find("confirm=true", 1, true))
    assert.is_nil(out:find("It reclaimed nothing", 1, true))
    assert.truthy(out:find("Nothing is safe to reclaim", 1, true))
  end)

  it("keeps the whole reply when it is not a plan, so a word from the daemon is never dropped", function()
    local out = rendered(ABSENT)
    assert.truthy(out:find("the server does not have that tool", 1, true))
    assert.truthy(out:find("The plugin is newer than this daemon.", 1, true))
    assert.truthy(out:find("get_workspace_hygiene", 1, true))
  end)

  it("an absent reply says plainly that this daemon is older, and does not error", function()
    local out = rendered("Error: unknown tool: get_workspace_hygiene")
    assert.truthy(out:find("get_workspace_hygiene", 1, true))
    assert.truthy(out:find("newer than the daemon", 1, true))
    assert.is_nil(out:find("stack traceback", 1, true))
  end)

  it("keeps the shape of the reply: headings and entries stay on their own lines", function()
    local lines = H.render(PLAN).lines
    assert.are.equal("Workspace hygiene (dry run, plan 7f3c1a2b)", lines[1])
    assert.are.equal("3 leftover(s) found. 2 safe to reclaim (12.0 KiB), 1 need a look (4.0 KiB).", lines[2])
    assert.are.equal("2 Safe to reclaim", lines[4])
    assert.are.equal(" agent worktree x2, 8.0 KiB", lines[5])
    assert.are.equal("  .worktrees/claude-9f2  8.0 KiB, 3d 4h old. merged by rebase, so it is safe to reclaim", lines[6])
    assert.are.equal("1 Has uncommitted work", lines[9])
    for _, l in ipairs(lines) do assert.are.equal("string", type(l)) end
  end)
end)

describe("hygiene.summary_line", function()
  it("is the number that matters, for a notification", function()
    assert.are.equal("2 safe to reclaim (12.0 KiB)", H.summary_line(PLAN))
  end)

  it("says so when there is nothing to reclaim", function()
    assert.are.equal("nothing is safe to reclaim right now", H.summary_line(table.concat({
      "Workspace hygiene (dry run, plan a1)",
      "0 leftover(s) found. 0 safe to reclaim (0 B), 0 need a look (0 B).",
    }, "\n")))
  end)

  it("names the missing tool when the daemon has none", function()
    assert.are.equal("this daemon has no get_workspace_hygiene", H.summary_line(nil))
  end)
end)

-- ─── Which repository the plan is about ───────────────────────────────────────

describe("hygiene.working_directory", function()
  it("is the directory the editor is in, so the plan is about this repository", function()
    assert.are.equal("/home/will/Work/sagefs.nvim", H.working_directory(function() return "/home/will/Work/sagefs.nvim" end))
  end)

  it("is empty when there is nowhere to look, so the daemon is asked rather than told", function()
    assert.are.equal("", H.working_directory(function() return "" end))
    assert.are.equal("", H.working_directory(function() return nil end))
  end)

  it("never raises, whatever the editor's getcwd does", function()
    assert.are.equal("", H.working_directory(function() error("no cwd") end))
  end)
end)

-- ─── The flow: one MCP tools/call, no transport of our own ────────────────────

describe("hygiene_view.refresh", function()
  it("calls get_workspace_hygiene once, with the directory the editor is in", function()
    local client, u = fake_client({ ok = true, text = PLAN }), fake_ui()
    u.cwd = function() return "/home/will/Work/sagefs.nvim" end
    V.refresh({ client = client, ui = u })
    assert.are.equal(1, #client.calls)
    assert.are.equal("get_workspace_hygiene", client.calls[1].name)
    assert.are.same({ working_directory = "/home/will/Work/sagefs.nvim" }, client.calls[1].args)
  end)

  it("shows what the daemon said, and nothing else is called", function()
    local client, u = fake_client({ ok = true, text = PLAN }), fake_ui()
    V.refresh({ client = client, ui = u })
    assert.are.equal(1, #u.writes)
    assert.truthy(last_window(u):find("7f3c1a2b", 1, true))
    assert.are.equal(1, #client.calls)
    assert.are.equal(1, #u.notes, "one line of news, not a paragraph")
    assert.truthy(u.notes[1].msg:find("2 safe to reclaim", 1, true))
  end)

  it("never calls tidy_workspace: the command is read-only", function()
    local client, u = fake_client({ ok = true, text = PLAN }), fake_ui()
    V.refresh({ client = client, ui = u })
    assert.are.equal(1, #client.calls)
    for _, call in ipairs(client.calls) do
      assert.is_nil(call.name:find("tidy", 1, true), "the command must not reclaim")
    end
  end)

  it("a daemon that refuses the call shows its words and does not raise", function()
    local client, u = fake_client({ ok = false, text = "Error: unknown tool: get_workspace_hygiene" }), fake_ui()
    local ok, err = pcall(V.refresh, { client = client, ui = u })
    assert.is_truthy(ok, tostring(err))
    assert.are.equal(1, #u.writes)
    local out = last_window(u)
    assert.truthy(out:find("unknown tool", 1, true))
    assert.truthy(out:find("newer than the daemon", 1, true))
  end)

  it("a daemon that is not there at all says so, and does not raise", function()
    local client, u = fake_client({ ok = false, text = "connection refused" }), fake_ui()
    local ok, err = pcall(V.refresh, { client = client, ui = u })
    assert.is_truthy(ok, tostring(err))
    assert.are.equal(1, #u.writes)
    assert.truthy(last_window(u):find("connection refused", 1, true))
  end)

  it("an empty reply is shown as the absent case, not as an empty window", function()
    local client, u = fake_client({ ok = true, text = "" }), fake_ui()
    V.refresh({ client = client, ui = u })
    local out = last_window(u)
    assert.is_true(#out > 0)
    assert.truthy(out:find("get_workspace_hygiene", 1, true))
  end)
end)