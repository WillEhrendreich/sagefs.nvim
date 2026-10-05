-- Cohort and trunk: parse the get_cohort_status text and render it. A member id
-- is a one-way fingerprint now (`mcp:m-<16 hex>`) or a minted run (`cap:<hex>`),
-- and both are shown in full; an older daemon's `mcp:<session id>` is still a
-- bearer handle, so that form is still kept out of the buffer. Texts are the
-- real idle status the dev daemon sent (an older daemon, so its ids are the
-- old form), the Trunk-section text written from the formatter
-- (spec/wire_fixtures.lua explains why that one is not captured), and a status
-- written from the new daemon's formatter for the new id forms.
require("spec.helper")
local C = require("sagefs.cohort")
local fx = require("spec.wire_fixtures")

local function line_texts(rendered)
  local out = {}
  for _, l in ipairs(rendered.lines) do table.insert(out, l.text) end
  return out
end

describe("cohort.parse_status: the real idle status", function()
  local model = C.parse_status(fx.read("cohort-status-idle.txt"))

  it("reads the ledger head and the conductor", function()
    assert.are.equal(13853, model.version)
    assert.are.equal("mcp:AAAAAAAAAAAAAAAAAAAAAA", model.conductor)
  end)

  it("reads a departed member with its seat and since", function()
    assert.are.equal(1, model.members_total)
    local m = model.members[1]
    assert.are.equal("mcp:AAAAAAAAAAAAAAAAAAAAAA", m.id)
    assert.are.equal("Observer", m.role)
    assert.are.equal("departed", m.seat)
    assert.are.equal("2026-09-18 22:44:29Z", m.since)
  end)

  it("reads no claims, no landings, and an unconfigured integration", function()
    assert.are.equal(0, model.claims_total)
    assert.are.same({}, model.claims)
    assert.are.equal(0, model.landings_total)
    assert.are.equal("09e824af17c04b884be4132353111a44801975d1", model.integration_head)
    assert.are.equal("NotConfigured", model.integration_session.kind)
    assert.is_nil(model.trunk)
  end)
end)

describe("cohort.parse_status: members, claims, landings and the trunk", function()
  local model = C.parse_status(fx.read("cohort-status-trunk.txt"))

  it("reads present and departed members", function()
    assert.are.equal(2, #model.members)
    assert.are.equal("present", model.members[1].seat)
    assert.are.equal("Implementer", model.members[1].role)
    assert.are.equal("Verifier", model.members[2].role)
  end)

  it("reads a claim, naming only the case of its state", function()
    local c = model.claims[1]
    assert.are.equal("c-1", c.id)
    assert.are.equal('File "src/Web/Program.fs"', c.scope)
    assert.are.equal("mcp:BBBBBBBBBBBBBBBBBBBBBB", c.held_by)
    assert.are.equal(3, c.fence)
    assert.are.equal("Held", c.state)
  end)

  it("reads each landing with its state case, queue position, statement and commits", function()
    assert.are.equal(4, model.landings_total)
    local l1, l2, l3, l4 = model.landings[1], model.landings[2], model.landings[3], model.landings[4]
    assert.are.equal("l-1", l1.id)
    assert.are.equal("Landed", l1.state)
    assert.are.equal("not queued", l1.queue)
    assert.are.equal("greeting reads from config", l1.statement)
    assert.are.same({ "a1b2c3d" }, l1.commits)
    assert.are.same({ "e4f5a6b", "0c1d2e3" }, l2.commits)
    assert.are.equal("Rebasing", l3.state)
    assert.are.equal("front of queue", l3.queue)
    assert.are.equal("Verifying", l4.state)
    assert.are.equal("position 1 in queue", l4.queue)
    assert.are.equal('say "hi" twice', l4.statement)
  end)

  it("reads the started integration session", function()
    assert.are.equal("Started", model.integration_session.kind)
    assert.are.equal("7f3a9c21", model.integration_session.id)
  end)

  it("reads the Trunk section: the checkout and one entry per landing", function()
    assert.are.equal("/home/will/.local/share/sagefs/cohort-trunk", model.trunk.checkout)
    assert.are.equal(4, model.trunk.count)
    assert.are.equal(4, #model.trunk.landings)
    assert.are.equal("l-1", model.trunk.landings[1].id)
  end)

  it("reads an integration session that failed to start, with the reason", function()
    local m = C.parse_status("Cohort ledger head: v1\nConductor: x\nMembers (0):\nClaims (0):\nIntegration head: abc\nLandings: (none)\nIntegration session: FAILED to start — the build failed\n")
    assert.are.equal("Failed", m.integration_session.kind)
    assert.are.equal("the build failed", m.integration_session.reason)
  end)

  it("reads the overflow lines the daemon prints instead of hiding rows", function()
    local m = C.parse_status("Cohort ledger head: v1\nConductor: x\nMembers (9):\n  - mcp:A [Observer] present\n  +8 more members (8 departed)\nClaims (0):\nIntegration head: abc\nLandings: (none)\nIntegration session: pending\n")
    assert.are.equal(9, m.members_total)
    assert.are.equal(1, #m.members)
    assert.are.equal("+8 more members (8 departed)", m.overflow[1])
    assert.are.equal("Pending", m.integration_session.kind)
  end)

  it("returns nil for text that is not a cohort status at all", function()
    assert.is_nil(C.parse_status(""))
    assert.is_nil(C.parse_status(nil))
    assert.is_nil(C.parse_status("Error: no cohort owner"))
  end)
end)

describe("cohort.parse_trunk_verdict: every verdict the trunk can give", function()
  local header = "Cohort ledger head: v1\nConductor: x\nMembers (0):\nClaims (0):\nIntegration head: abc\nLandings: (none)\nIntegration session: 7f3a9c21 (started)\n"
  local verdicts = C.parse_status(header .. fx.read("cohort-status-trunk-verdicts.txt")).trunk

  local function v(n) return verdicts.landings[n].verdict end

  it("reads all eight lines", function()
    assert.are.equal(8, #verdicts.landings)
  end)

  it("no session works in the trunk checkout", function()
    assert.are.equal("NoTrunkSession", v(1).kind)
  end)

  it("the trunk checkout did not move, with git's reason", function()
    assert.are.equal("NotMoved", v(2).kind)
    assert.are.equal("git refused: dirty tree", v(2).reason)
  end)

  it("a trunk session with no running app", function()
    assert.are.equal("Followed", v(3).kind)
    assert.are.equal("aa11", v(3).deliveries[1].session)
    assert.are.equal("NoApp", v(3).deliveries[1].kind)
  end)

  it("per-file save pipeline outcomes, with the case token, the mechanism and the closed-set check", function()
    local files = v(4).deliveries[1].files
    assert.are.equal("Program.fs", files[1].file)
    assert.are.equal("Patched", files[1].case)
    assert.are.equal("metadata-delta", files[1].mechanism)
    assert.is_true(files[1].known)
    assert.are.equal("Handlers.fs", files[2].file)
    assert.are.equal("NeverEntered", files[2].case)
    assert.are.equal("detour", files[2].mechanism)
  end)

  it("a restart with its named cause", function()
    local f = v(5).deliveries[1].files[1]
    assert.are.equal("RestartRequired", f.case)
    assert.are.equal("FieldsChanged", f.cause.case)
    assert.are.equal("the fields of Shape changed, which changes the layout of every object of it", f.cause.message)
    assert.are.equal("", f.mechanism)
  end)

  it("a worker that did not answer", function()
    assert.are.equal("Unreachable", v(6).deliveries[1].kind)
    assert.are.equal("connection refused", v(6).deliveries[1].reason)
  end)

  it("several sessions on one line", function()
    local d = v(7).deliveries
    assert.are.equal(2, #d)
    assert.are.equal("aa11", d[1].session)
    assert.are.equal("NoEffect", d[1].files[1].case)
    assert.are.equal("bb22", d[2].session)
    assert.are.equal("Unavailable", d[2].kind)
    assert.are.equal("stopped", d[2].reason)
  end)

  it("files that need a rebuild or are not watched", function()
    local files = v(8).deliveries[1].files
    assert.are.equal("NeedsRebuild", files[1].kind)
    assert.are.equal("project file changed", files[1].reason)
    assert.are.equal("NotWatched", files[2].kind)
    assert.are.equal("Other.fs", files[2].file)
  end)

  it("in flight and queued landings", function()
    local m = C.parse_status(fx.read("cohort-status-trunk.txt"))
    assert.are.equal("Followed", m.trunk.landings[1].verdict.kind)
    assert.are.equal("Following", m.trunk.landings[3].verdict.kind)
    assert.are.equal("waiting on session 5d2e8b10", m.trunk.landings[3].verdict.detail)
    assert.are.equal("Queued", m.trunk.landings[4].verdict.kind)
  end)

  it("a verdict it does not know is Unrecognized and keeps its text", function()
    local m = C.parse_status("Cohort ledger head: v1\nConductor: x\nMembers (0):\nClaims (0):\nIntegration head: abc\nLandings: (none)\nIntegration session: pending\nTrunk: checkout=/t landings (1):\n  trunk l-9: something new the daemon says\n")
    assert.are.equal("Unrecognized", m.trunk.landings[1].verdict.kind)
    assert.are.equal("something new the daemon says", m.trunk.landings[1].verdict.text)
  end)
end)

-- Written from SageFs.Core/Features/CohortStatusText.fs and the member id
-- formats of the capability-token work (docs/mcp-tools.md, member tokens): a
-- connection is `mcp:m-<16 hex>`, a minted run is `cap:<16 hex>`.
local NEW_STATUS = table.concat({
  "Cohort ledger head: v20",
  "Conductor: mcp:m-0123456789abcdef",
  "Members (3):",
  "  - mcp:m-0123456789abcdef [Implementer] present",
  "  - cap:fedcba9876543210 [Observer] present",
  "  - cap:00112233445566ff [Implementer] departed 2026-10-02 09:00:00Z",
  "Claims (1):",
  '  - c-1 File "src/Foo/a.fs" held-by=cap:00112233445566ff fence=2 state=Held (Mcp "x")',
  "Integration head: 09e824af17c04b884be4132353111a44801975d1",
  "Landings (1):",
  '  - l-1 requester=cap:00112233445566ff state=Verifying "a" position 1 in queue statement="hi" commits=[1a2b3c4]',
  "Integration session: pending",
  "",
}, "\n")

describe("cohort.mask_member: ids are fingerprints now, so they are shown whole", function()
  it("shows a connection fingerprint in full", function()
    assert.are.equal("mcp:m-0123456789abcdef", C.mask_member("mcp:m-0123456789abcdef"))
  end)

  it("shows a minted run's id in full", function()
    assert.are.equal("cap:fedcba9876543210", C.mask_member("cap:fedcba9876543210"))
  end)

  it("leaves a short or non-handle id alone", function()
    assert.are.equal("alice", C.mask_member("alice"))
    assert.are.equal("mcp:abc", C.mask_member("mcp:abc"))
    assert.are.equal("", C.mask_member(nil))
  end)

  it("still hides an older daemon's id, which is the connection's bearer handle", function()
    assert.are.equal("mcp:tJj5NF…", C.mask_member("mcp:tJj5NFu4OCqmI2WIWkiBFA"))
  end)
end)

describe("cohort.parse_status: the member kinds", function()
  local model = C.parse_status(NEW_STATUS)

  it("reads a connection fingerprint, a minted run and a departed minted run", function()
    assert.are.equal(3, #model.members)
    assert.are.equal("mcp:m-0123456789abcdef", model.members[1].id)
    assert.are.equal("Implementer", model.members[1].role)
    assert.are.equal("cap:fedcba9876543210", model.members[2].id)
    assert.are.equal("Observer", model.members[2].role)
    assert.are.equal("present", model.members[2].seat)
    assert.are.equal("departed", model.members[3].seat)
    assert.are.equal("2026-10-02 09:00:00Z", model.members[3].since)
  end)

  it("names the kind of each id: connection, capability, and the older form", function()
    assert.are.equal("connection", model.members[1].kind)
    assert.are.equal("capability", model.members[2].kind)
    assert.are.equal("capability", model.members[3].kind)
    local old = C.parse_status(fx.read("cohort-status-idle.txt"))
    assert.are.equal("legacy", old.members[1].kind)
  end)

  it("gives the kind of an id it has never seen as other, without failing", function()
    local m = C.parse_status("Cohort ledger head: v1\nConductor: x\nMembers (1):\n  - agent-7 [Observer] present\nClaims (0):\nIntegration head: abc\nLandings: (none)\nIntegration session: pending\n")
    assert.are.equal("agent-7", m.members[1].id)
    assert.are.equal("other", m.members[1].kind)
  end)

  it("reads a claim held by, and a landing requested by, a minted run", function()
    assert.are.equal("cap:00112233445566ff", model.claims[1].held_by)
    assert.are.equal("cap:00112233445566ff", model.landings[1].requester)
  end)
end)

describe("cohort.render: the new id forms", function()
  local text = table.concat(line_texts(C.render(C.parse_status(NEW_STATUS))), "\n")

  it("shows connection fingerprints and minted ids whole, as conductor, member, holder and requester", function()
    assert.truthy(text:find("Conductor: mcp:m-0123456789abcdef", 1, true))
    assert.truthy(text:find("cap:fedcba9876543210  Observer  present", 1, true))
    assert.truthy(text:find("held by cap:00112233445566ff", 1, true))
    assert.is_nil(text:find("…", 1, true))
  end)

  it("marks a minted run, so it is told from a connection", function()
    local minted, plain = 0, 0
    for _, line in ipairs(line_texts(C.render(C.parse_status(NEW_STATUS)))) do
      if line:find("cap:fedcba9876543210", 1, true) and line:find("minted run", 1, true) then minted = minted + 1 end
      if line:find("mcp:m-0123456789abcdef  Implementer", 1, true) and line:find("minted", 1, true) then plain = plain + 1 end
    end
    assert.are.equal(1, minted)
    assert.are.equal(0, plain)
  end)
end)

describe("cohort.render", function()
  it("shows the trunk lines in the same words the reload display uses, and never the full member handle", function()
    local rendered = C.render(C.parse_status(fx.read("cohort-status-trunk.txt")))
    local text = table.concat(line_texts(rendered), "\n")
    assert.truthy(text:find("Trunk", 1, true))
    assert.truthy(text:find("trunk l-1: session 5d2e8b10: Program.fs applied, new body has not run yet (via metadata delta)", 1, true))
    assert.truthy(text:find("trunk l-2: session 5d2e8b10: Shape.fs restarted: TypeShapeChanged, the shape of type Shape changed", 1, true))
    assert.truthy(text:find("trunk l-3: following (waiting on session 5d2e8b10)", 1, true))
    assert.truthy(text:find("trunk l-4: queued behind the landing in flight", 1, true))
    assert.is_nil(text:find("BBBBBBBBBBBBBBBBBBBBBB", 1, true))
    assert.is_nil(text:find("CCCCCCCCCCCCCCCCCCCCCC", 1, true))
    assert.truthy(text:find("mcp:BBBBBB…", 1, true))
  end)

  it("shows members, claims and the landing queue", function()
    local text = table.concat(line_texts(C.render(C.parse_status(fx.read("cohort-status-trunk.txt")))), "\n")
    assert.truthy(text:find("Members (2)", 1, true))
    assert.truthy(text:find("departed 2026-10-02 08:11:09Z", 1, true))
    assert.truthy(text:find("Claims (1)", 1, true))
    assert.truthy(text:find('File "src/Web/Program.fs"', 1, true))
    assert.truthy(text:find("fence 3", 1, true))
    assert.truthy(text:find("Landings (4)", 1, true))
    assert.truthy(text:find("l-4  Verifying  position 1 in queue", 1, true))
    assert.truthy(text:find("greeting reads from config", 1, true))
    assert.truthy(text:find("Integration session: 7f3a9c21 (started)", 1, true))
  end)

  it("says plainly when the cohort has no integration and no landings", function()
    local text = table.concat(line_texts(C.render(C.parse_status(fx.read("cohort-status-idle.txt")))), "\n")
    assert.truthy(text:find("no integration configured", 1, true))
    assert.truthy(text:find("Landings: none", 1, true))
    assert.is_nil(text:find("Trunk", 1, true))
    assert.is_nil(text:find("AAAAAAAAAAAAAAAAAAAAAA", 1, true))
  end)

  it("colours each trunk line by the severity of what it says", function()
    local rendered = C.render(C.parse_status(fx.read("cohort-status-trunk.txt")))
    local hl_for = {}
    for i, l in ipairs(rendered.lines) do hl_for[l.text] = l.hl end
    local found = {}
    for _, l in ipairs(rendered.lines) do
      if l.text:find("trunk l-1:", 1, true) then found.pending = l.hl end
      if l.text:find("trunk l-2:", 1, true) then found.restart = l.hl end
    end
    assert.are.equal("SageFsReloadPending", found.pending)
    assert.are.equal("SageFsReloadWarn", found.restart)
  end)

  it("renders a placeholder for a missing model", function()
    local text = table.concat(line_texts(C.render(nil)), "\n")
    assert.truthy(text:find("no cohort status", 1, true))
  end)
end)

describe("cohort.parse_status: a vetoed landing", function()
  local model = C.parse_status(fx.read("cohort-status-veto.txt"))

  it("reads who vetoed and the reason they gave, off the landing's state", function()
    assert.are.equal(2, model.landings_total)
    local vetoed = model.landings[1]
    assert.are.equal("l-1", vetoed.id)
    assert.are.equal("cap:fedcba9876543210", vetoed.requester)
    assert.are.equal("cap:00112233445566ff", vetoed.vetoed_by)
    assert.are.equal("the landing drops the retry", vetoed.veto_reason)
  end)

  it("reads a veto's queue position as not queued, so the state and the queue agree", function()
    -- The veto takes the landing OUT of the queue, which is what `not queued` says.
    -- Parsed after the state, or the state's own words swallow the queue suffix.
    assert.are.equal("not queued", model.landings[1].queue)
    assert.are.equal("Blocked", model.landings[1].state)
  end)

  it("leaves an unvetoed landing with no veto on it", function()
    local queued = model.landings[2]
    assert.are.equal("l-2", queued.id)
    assert.are.equal("Queued", queued.state)
    assert.are.equal("front of queue", queued.queue)
    assert.is_nil(queued.vetoed_by)
    assert.is_nil(queued.veto_reason)
  end)

  it("reads a veto reason that contains quotes and colons, because it is the tail of the state", function()
    local text = table.concat({
      'Cohort ledger head: v1',
      'Members (1):',
      '  - cap:aaaa [Implementer] present',
      'Landings (1):',
      '  - l-9 requester=cap:aaaa state=Blocked(vetoed by cap:bbbb: "it says "no" twice: twice") awaiting the conductor: resolve_veto clears it, withdraw_landing takes it back not queued statement="s" commits=[aa]',
    }, "\n")
    local vetoed = C.parse_status(text).landings[1]
    assert.are.equal("cap:bbbb", vetoed.vetoed_by)
    assert.are.equal('it says "no" twice: twice', vetoed.veto_reason)
  end)

  it("shows the veto and both ways out on the landing's row", function()
    local text = table.concat(line_texts(C.render(model)), "\n")
    assert.truthy(text:find("vetoed by cap:00112233445566ff", 1, true))
    assert.truthy(text:find('"the landing drops the retry"', 1, true))
    assert.truthy(text:find("resolve_veto", 1, true))
    assert.truthy(text:find("withdraw_landing", 1, true))
  end)

  it("marks a vetoed landing apart from a queued one: a warn-coloured line under the row, and only under a vetoed row", function()
    local rendered = C.render(model)
    local veto_line, queued_has_veto = nil, false
    for _, l in ipairs(rendered.lines) do
      if l.text:find("vetoed by ", 1, true) then
        veto_line = l
        -- which row is it under: the one before it in the list
        for i, prev in ipairs(rendered.lines) do
          if prev == l then
            local above = rendered.lines[i - 1]
            queued_has_veto = above.text:find("l-2 ", 1, true) ~= nil
          end
        end
      end
    end
    assert.is_not_nil(veto_line)
    assert.are.equal("SageFsReloadWarn", veto_line.hl)
    assert.is_false(queued_has_veto)
  end)
end)

describe("cohort events from the SSE stream", function()
  local events = require("sagefs.events")
  local sse = require("sagefs.sse")

  it("the real cohort_matrix frame is classified and has an autocmd pattern", function()
    local parsed = sse.parse_chunk(fx.read("sse-cohort-matrix.txt"))
    assert.are.equal("cohort_matrix", sse.classify_event(parsed[1]).action)
    assert.are.equal("SageFsCohortMatrix", events.build_autocmd_data("cohort_matrix", {}).pattern)
  end)

  it("claim_changed, landing_changed, save_observed and cohort_changed are classified and have patterns", function()
    for _, name in ipairs({ "claim_changed", "landing_changed", "save_observed" }) do
      assert.are.equal(name, sse.classify_event({ type = name, data = "{}" }).action)
    end
    assert.are.equal("SageFsClaimChanged", events.build_autocmd_data("claim_changed", {}).pattern)
    assert.are.equal("SageFsLandingChanged", events.build_autocmd_data("landing_changed", {}).pattern)
    assert.are.equal("SageFsSaveObserved", events.build_autocmd_data("save_observed", {}).pattern)
    assert.are.equal("cohort_changed", sse.classify_state_event({ cohortChanged = true }))
    assert.are.equal("SageFsCohortChanged", events.build_autocmd_data("cohort_changed", {}).pattern)
  end)

  it("the member id in a cohort_matrix frame from an older daemon is masked before it is shown", function()
    local parsed = sse.parse_chunk(fx.read("sse-cohort-matrix.txt"))
    local data = vim.json.decode(parsed[1].data)
    local lines = C.matrix_summary(data)
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("1 member", 1, true))
    assert.is_nil(text:find("AAAAAAAAAAAAAAAAAAAAAA", 1, true))
  end)
end)
