-- Loader for the captured wire payloads under spec/fixtures/wire/.
-- Not a spec: busted only runs *_spec files, this is required by them.
--
-- Provenance of each fixture (captured 2026-10-02 from the dev SageFs daemon,
-- master d7e11077, port 37749, against a small Falco app run with run_app;
-- paths shortened and the one cohort member handle replaced by a placeholder):
--   api-sessions.json          GET /api/sessions, three sessions (a hot reload session
--                              BehindApp with a NoEffect lastReload, an in-sync REPL
--                              session, a session with a lastRestart)
--   sse-hot-reload-session.txt the state frames GET /events sent for one save sequence:
--                              Restarted, PatchPending, Patched, NoEffect, PatchPending,
--                              Patched, Restarted (signature), PatchPending, NeverEntered
--   sse-cohort-matrix.txt      the cohort_matrix frame, as sent
--   cohort-status-idle.txt     get_cohort_status text from a cohort with no integration
--   cohort-status-trunk.txt    get_cohort_status text WITH the Trunk section. The dev
--                              daemon's cohort has no integration configured (and may not
--                              be reconfigured), so this one is written from the formatter
--                              (CohortStatusText.render, McpCohortIntegration.getCohortStatus,
--                              TrunkFollow.statusLines) and the strings TrunkFollowTests pin.
--   cohort-status-veto.txt     a status with a VETOED landing. Written from the same
--                              formatter: CohortStatusText.landingStateText prints
--                              `Blocked(vetoed by <member>: "<reason>") awaiting the
--                              conductor: resolve_veto clears it, withdraw_landing takes it
--                              back`, and the landing line is
--                              `  - <id> requester=<id> state=<state> <queue> statement=".."
--                              commits=[..]`. A veto needs a second seated member with a
--                              reason, so it is not something to stage on the dev daemon to
--                              photograph; every character here comes from those two format
--                              strings.
--   reload-callers-pending.json    the `callers` object of a reload report, Pending,
--                                 with sites reached both by the compiler and by name,
--                                 and two notChecked entries. Written from
--                                 CallerState.toJson (the field names: state, message,
--                                 suggestedAction, pending[], notChecked[], and inside a
--                                 pending entry declaration/cause/file/sites[] with
--                                 file/line/caller/evidence plus nameOnlyReason/nameOnlyDetail
--                                 when the evidence is MatchedByName) using the values
--                                 SageFs.Tests/CallerWireTests.fs pins, so the wire is
--                                 the daemon's own writer rather than a photograph.
--                                 A pending callers state needs a running app whose
--                                 method is re-signed while another file calls it, which
--                                 is a whole hot-reload scenario to stage for one object.
--   reload-callers-not-checked.json  the NotChecked shape: one unresolved declaration
--                                 and a reason, with nothing pending. Same source.
--   exec-behind-app.json       POST /exec body from a BehindApp session
local M = {}

local function fixture_dir()
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  local dir = src:match("^(.*)/[^/]*$") or "."
  return dir .. "/fixtures/wire/"
end

function M.read(name)
  local f = assert(io.open(fixture_dir() .. name, "rb"), "missing fixture " .. name)
  local text = f:read("*a")
  f:close()
  return text
end

return M
