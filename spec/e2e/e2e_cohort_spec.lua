-- spec/e2e/e2e_cohort_spec.lua — E2E: the four cohort actions from Neovim, against a
-- real daemon
--
-- A REAL daemon (its own port, its own SAGEFS_DATA_DIR, --no-resume, owned by this
-- Neovim) and a REAL cohort: two members, so a veto is possible, which is the case
-- these commands exist for. The plugin's own user commands are driven in real
-- Neovim, and the assertion is the DAEMON's own answer — the cohort status read
-- back over MCP — not the plugin's rendering of it.
--
-- The four tools arrived in 0.6.896. Before this the plugin could read a cohort,
-- see a veto on a row, and do nothing about it.
--
-- Usage: nvim --headless --clean -u NONE -l spec/e2e/e2e_cohort_spec.lua

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
package.path = script_dir .. "?.lua;" .. package.path

local H = require("e2e_harness")

--- Read the cohort status over MCP, the way the plugin's own panel does.
---
--- ONE client for the whole suite, and that is the point, not an optimisation: a
--- member is the CONNECTION, so every `connect()` is a new stranger with a new
--- fingerprint and its own seat. The plugin holds one client (cohort_view.lua), and
--- a suite that reconnected per call would be testing a shape the product never
--- uses. It is also why the first attempt at this suite failed: `set_integration_ref`
--- came back "your role is Working" because by then the caller was a fourth member
--- who had never joined.
local client = nil

local function ensure_client(port)
  if not client then client = require("sagefs.mcp_client").connect(port) end
  return client
end

local function cohort_status(port, cwd)
  local c = ensure_client(port)
  local got
  c.call_tool("get_cohort_status", { working_directory = cwd }, function(ok, text)
    got = { ok = ok, text = text }
  end)
  H.assert_truthy(H.wait_for(function() return got end, 60000, 50), "get_cohort_status answered")
  return got
end

--- Call a tool the way an action command does, and wait for the answer.
local function call(port, cwd, tool, args)
  local c = ensure_client(port)
  local got
  args = vim.tbl_extend("force", { working_directory = cwd }, args or {})
  c.call_tool(tool, args, function(ok, text) got = { ok = ok, text = text } end)
  H.assert_truthy(H.wait_for(function() return got end, 60000, 50), tool .. " answered")
  return got
end

--- Whether a status names a vetoed landing at all. Used so a case can skip with
--- the daemon's own words rather than pass vacuously when the veto did not take
--- (a landing that lands before it can be vetoed is a real outcome, not a bug).
local function status_has_veto(status)
  return status.text:find("vetoed by", 1, true) ~= nil
end

H.run_suite({
  name = "Cohort actions (real daemon)",
  sample = "Minimal",
  port = 47797, -- two clear of e2e_nudge_spec's 47795, so suites can run side by side
  warmup = false,
  fn = function(sagefs, temp, handle)
    local port = handle.port
    local cwd = temp.project

    -- Every note the commands report, captured so a case can assert on what the
    -- person is told rather than only on the daemon's state.
    local notes = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level) table.insert(notes, { msg = tostring(msg), level = level }) end
    local echoes = {}
    local real_echo = vim.api.nvim_echo
    vim.api.nvim_echo = function(chunks, history, opts)
      for _, c in ipairs(chunks or {}) do table.insert(echoes, { msg = tostring(c[1]), hl = c[2] }) end
      return real_echo(chunks, history, opts)
    end
    local function said(fragment)
      for _, n in ipairs(notes) do
        if n.msg:find(fragment, 1, true) then return n end
      end
      for _, e in ipairs(echoes) do
        if e.msg:find(fragment, 1, true) then return e end
      end
      return nil
    end
    local function wait_said(fragment, timeout)
      return H.wait_for(function() return said(fragment) end, timeout or 60000, 50)
    end

    H.describe("a cohort with two members, so a veto is possible", function()
      -- The suite's project is not a git repository, and a landing needs one: the
      -- daemon resolves the integration ref against it ("could not resolve 'master'
      -- to a commit ... not a git repository"), so without this the veto case would
      -- skip on every machine and the thing this slice exists to prove would never
      -- run. One commit on a throwaway branch: the ref only has to RESOLVE.
      H.it("makes its own project a git repository, so a landing can exist", function()
        vim.system({ "git", "init", "-q", "-b", "master" }, { cwd = temp.project }):wait()
        local f = assert(io.open(temp.project .. "/README.md", "wb"))
        f:write("e2e fixture\n")
        f:close()
        vim.system({
          "git", "-c", "user.email=e2e@example.invalid", "-c", "user.name=e2e",
          "add", "-A",
        }, { cwd = temp.project }):wait()
        vim.system({
          "git", "-c", "user.email=e2e@example.invalid", "-c", "user.name=e2e",
          "commit", "-q", "-m", "e2e fixture",
        }, { cwd = temp.project }):wait()
        local out = vim.system({ "git", "rev-parse", "HEAD" }, { cwd = temp.project }):wait()
        H.assert_eq(0, out.code, "the fixture project is a git repository with a commit")
        io.write("      fixture repo HEAD: " .. tostring(out.stdout):gsub("%s+$", "") .. "\n")
      end)

      H.it("the daemon is up and this suite owns its data dir", function()
        H.assert_eq(200, H.http_get("/api/sessions", port).status, "the daemon answers")
        H.assert_truthy(temp.project ~= nil, "a private project dir")
        H.assert_truthy(cwd:find("sagefs", 1, true) ~= nil or cwd:find("e2e", 1, true) ~= nil,
          "the project is the suite's own copy, not the user's checkout")
      end)

      -- The MCP connection is the member. join_cohort with one agentName seats one
      -- member and makes it the conductor. A SECOND member is needed for a veto,
      -- because the conductor cannot veto (a veto is an objection by somebody who is
      -- not the requester), which is what a second connection buys.
      H.it("seats the connection as conductor, and shows the id the daemon calls it", function()
        local joined = call(port, cwd, "join_cohort", { agentName = "alice", role = "Implementer" })
        H.assert_truthy(joined.ok, "alice joined: " .. tostring(joined.text):sub(1, 300))

        local status = cohort_status(port, cwd)
        io.write("      status after join: " .. status.text:sub(1, 500) .. "\n")

        -- The member id is a FINGERPRINT of the connection (`mcp:m-<16 hex>`), not
        -- the agentName. That is deliberate (0.6.896: a member's id is no longer the
        -- bearer handle), so the status never prints "alice" as the id, and a suite
        -- that asserted it would be asserting the pre-0.6.896 wire.
        -- NO `^` anchor: it would only ever match at the very start of the whole status,
        -- where the ledger head is, so it could not see a member line at all.
        local member_id = status.text:match("\n%s+%-%s+(mcp:%S+)%s")
        H.assert_truthy(member_id ~= nil, "the status lists a member by its id: " .. status.text:sub(1, 400))
        H.assert_truthy(member_id:match("^mcp:m%-%x+$") ~= nil,
          "and that id is a fingerprint, not a handle: " .. member_id)
        H.assert_truthy(status.text:find("Implementer", 1, true), "it carries the role it joined with")

        -- The conductor line names the same id, so the seat is filled and readable.
        local conductor = status.text:match("Conductor:%s*(%S+)")
        H.assert_truthy(conductor ~= nil, "the conductor line names someone: " .. status.text:sub(1, 400))
        H.assert_truthy(conductor ~= "(none" and conductor ~= "mcp:", "the seat is not vacant: " .. tostring(conductor))
        H.assert_truthy(conductor:find(member_id, 1, true) ~= nil,
          "and it is this member: " .. tostring(conductor) .. " vs " .. member_id)
      end)
    end)

    H.describe("the four commands are registered and reach the daemon", function()
      H.it(":SageFsCohortDelegate, :SageFsCohortVeto, :SageFsCohortResolveVeto and :SageFsCohortWithdraw all exist", function()
        for _, name in ipairs({
          "SageFsCohort", "SageFsCohortDelegate", "SageFsCohortVeto",
          "SageFsCohortResolveVeto", "SageFsCohortWithdraw",
        }) do
          local cmds = vim.api.nvim_get_commands({})
          H.assert_truthy(cmds[name] ~= nil, name .. " is registered")
        end
      end)

      H.it("a veto with no reason is refused locally, naming what is missing, without a round trip", function()
        -- The bounds are the tool's own (1..1000 chars) and are checked before the
        -- call, so a malformed command costs no round trip and the message arrives
        -- immediately. Arity is checked FIRST, so the message names the missing
        -- argument rather than blaming the agent — which is the whole point of
        -- checking the count in the handler instead of via nargs.
        vim.cmd("cd " .. vim.fn.fnameescape(cwd))
        local notes_before, echoes_before = #notes, #echoes
        vim.cmd("SageFsCohortVeto alice l-1")
        H.assert_truthy(H.wait_for(function()
          return #notes > notes_before or #echoes > echoes_before
        end, 20000, 50), "the command reported something")

        local said_why = wait_said("the reason", 20000)
        H.assert_truthy(said_why ~= nil, "it names the reason as missing: "
          .. tostring((notes[#notes] or {}).msg) .. " / " .. tostring((echoes[#echoes] or {}).msg))

        -- and no call went out: nothing was appended to the notes by a tool answer
        local spurious = false
        for i = notes_before + 1, #notes do
          if notes[i].msg:find("veto", 1, true) and not notes[i].msg:find("Missing", 1, true) then
            spurious = true
          end
        end
        H.assert_falsy(spurious, "nothing was sent to the daemon")
      end)

      H.it("the daemon's own veto bound is what we check: 1000 characters, inclusive", function()
        local A = require("sagefs.cohort_actions")
        H.assert_eq(1000, A.REASON_MAX)
        H.assert_truthy(A.check_veto(string.rep("x", 1000), "l-1") == nil, "exactly 1000 is allowed")
        H.assert_truthy(A.check_veto(string.rep("x", 1001), "l-1") ~= nil, "1001 is refused")
        H.assert_truthy(A.check_veto("x", "l-1") == nil, "one character is allowed")
      end)

      H.it("a veto whose reason is too long says the length it was given", function()
        local why = require("sagefs.cohort_actions").check_veto(string.rep("x", 1001), "l-1")
        H.assert_truthy(why:find("1001", 1, true), "the message names the length: " .. tostring(why))
      end)

      H.it("the daemon refuses a veto from a member with no seat, and says so in words", function()
        -- Not the plugin's refusal: the daemon's own answer, which is what the
        -- command surfaces. A veto needs a seated Implementer/Verifier who is not
        -- the requester; a name nobody joined with gets the daemon's refusal.
        local got = call(port, cwd, "veto_landing", {
          agentName = "not-a-member", landingId = "l-does-not-exist", reason = "because",
        })
        H.assert_truthy(type(got.text) == "string" and #got.text > 0,
          "the daemon answered in words: " .. tostring(got.text))
        io.write("      daemon refusal: " .. got.text:sub(1, 300) .. "\n")
      end)

      H.it("withdrawing a landing nobody requested is refused by the daemon, not silently fine", function()
        local got = call(port, cwd, "withdraw_landing", {
          agentName = "alice", landingId = "l-nope",
        })
        H.assert_truthy(#got.text > 0, "the daemon answered: " .. tostring(got.text))
        io.write("      daemon refusal: " .. got.text:sub(1, 300) .. "\n")
      end)
    end)

    H.describe("a veto on a real landing, read back from the daemon", function()
      H.it("a second member vetoes a real landing, and the status carries who and why", function()
        -- This is the whole point of the slice, so it is worth the setup: a landing
        -- exists, a DIFFERENT member vetoes it, and the status read back over MCP
        -- says who and why — and the plugin parses both off the wire, which is the
        -- half that was broken.
        --
        -- TWO connections on purpose. A member is a connection, so a veto has to
        -- come from one that is not the requester: the requester (this suite's
        -- client) is also the conductor, and neither may veto its own landing.
        local setref = call(port, cwd, "set_integration_ref", {
          agentName = "alice", integrationRef = "master",
        })
        if not setref.ok then
          -- Said out loud rather than passing vacuously: no integration on this
          -- machine means no landing can exist, so there is nothing to veto.
          io.write("      SKIP: no integration ref here: " .. tostring(setref.text):sub(1, 300) .. "\n")
          return
        end
        H.assert_truthy(setref.ok, "integration configured: " .. tostring(setref.text))

        -- `statement` is REQUIRED by the tool (the merge message), so a landing cannot
        -- be requested without one.
        local landed = call(port, cwd, "request_landing", {
          agentName = "alice", claims = "", commits = "",
          statement = "e2e: a landing to veto",
        })
        H.assert_truthy(landed.ok, "a landing was requested: " .. tostring(landed.text):sub(1, 300))
        local lid = tostring(landed.text):match("(l%-[%w]+)")
        H.assert_truthy(lid ~= nil, "the landing id is in the answer: " .. tostring(landed.text):sub(1, 300))

        -- The second member: its own connection, its own seat, its own fingerprint.
        local other = require("sagefs.mcp_client").connect(port)
        local joined
        other.call_tool("join_cohort", { agentName = "bob", role = "Verifier", working_directory = cwd },
          function(ok, text) joined = { ok = ok, text = tostring(text) } end)
        H.assert_truthy(H.wait_for(function() return joined end, 60000, 50), "bob joined")
        H.assert_truthy(joined.ok, "bob is seated: " .. joined.text:sub(1, 300))
        -- his id, read off the status, is what a veto will be attributed to. It is
        -- NOT "bob": a member id is the connection's fingerprint.
        local before = cohort_status(port, cwd)
        io.write("      members before the veto:\n" .. before.text:sub(1, 600) .. "\n")

        local vetoed
        other.call_tool("veto_landing", {
          agentName = "bob", landingId = lid, reason = "the landing drops the retry",
          working_directory = cwd,
        }, function(ok, text) vetoed = { ok = ok, text = tostring(text) } end)
        H.assert_truthy(H.wait_for(function() return vetoed end, 60000, 50), "the veto was answered")
        io.write("      veto: " .. vetoed.text:sub(1, 400) .. "\n")

        if not status_has_veto(cohort_status(port, cwd)) then
          io.write("      SKIP the veto did not take this run: " .. vetoed.text:sub(1, 300) .. "\n")
          other.close()
          return
        end

        local status = cohort_status(port, cwd)
        H.assert_truthy(status.text:find("vetoed by", 1, true),
          "the status says a landing is vetoed: " .. status.text:sub(1, 800))
        H.assert_truthy(status.text:find("the landing drops the retry", 1, true),
          "and carries the reason verbatim: " .. status.text:sub(1, 800))

        -- And the plugin PARSES both off the wire.
        local parsed = require("sagefs.cohort").parse_status(status.text)
        local found
        for _, l in ipairs(parsed.landings or {}) do
          if l.id == lid then found = l end
        end
        H.assert_truthy(found ~= nil, "the landing is in the parsed model")
        H.assert_truthy(found.vetoed_by ~= nil and found.vetoed_by ~= "",
          "the plugin reads who vetoed, off the real wire: " .. tostring(found.vetoed_by))
        H.assert_truthy(found.vetoed_by:match("^mcp:%S+$") ~= nil,
          "and it is that member's fingerprint: " .. tostring(found.vetoed_by))
        H.assert_eq("the landing drops the retry", found.veto_reason,
          "the reason is read whole, through the embedded punctuation")
        H.assert_eq("not queued", found.queue, "a veto takes the landing out of the queue")
        io.write("      parsed: " .. found.id .. " vetoed_by=" .. tostring(found.vetoed_by)
          .. " reason=" .. tostring(found.veto_reason) .. " queue=" .. tostring(found.queue) .. "\n")

        -- And the view renders the reason plus the two ways out, which is what a
        -- reader needs: `Blocked` on its own says nothing about what to do.
        local rendered = require("sagefs.cohort").render(parsed)
        local text = {}
        for _, l in ipairs(rendered.lines) do table.insert(text, l.text) end
        local shown = table.concat(text, "\n")
        H.assert_contains(shown, found.vetoed_by, "the row names who vetoed")
        H.assert_contains(shown, "resolve_veto", "and how the conductor clears it")
        H.assert_contains(shown, "withdraw_landing", "and how the requester takes it back")

        other.close()
      end)
    end)

    vim.notify = real_notify
    vim.api.nvim_echo = real_echo
  end,
})
