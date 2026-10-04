# sagefs.nvim modernization — inspection + plan

## Progress (landed this session — all TDD + dogfooded against a live daemon)

- **P1 nvim: decode the 0.6 `state` SSE envelope** — pure `classify_state_event` +
  handler routing + 0.6 field names. Proven against a live daemon (field names match
  exactly). Branch `fix/daemon-0.6-sse-protocol` (pushed).
- **VS Code: same envelope-drop bug fixed** — `LiveTestingListener.fs` `"state"` arm was
  discarding the payload identically. Mirrored classifier + 11 golden tests (18/18 pass),
  Fable compiles clean. Branch `fix/vscode-0.6-protocol` in the SageFs repo (pushed).
- **Daemon gap closed — export-fsx route** — was contracted but never mapped (both editors'
  export 404'd). Implemented `GET /api/sessions/{sid}/export-fsx` returning `{evalCount,
  content}`; proven live (2-eval session exports both cells; 400/404 edges correct). SageFs
  branch `fix/daemon-export-and-session-events` (pushed).
- **P3 nvim: `:SageFsExportFile`** repointed off the dead `/api/history` to the live
  endpoint (pushed).
- **P5 nvim: `:checkhealth` version guard** — pure `version_drift` + a warning when the
  daemon is a minor ahead (the guard that would have caught this whole drift class). 6 new
  specs (pushed).
- **Docs**: SageFs repo + sagetech.dev refreshed against source, plain English — branches
  `docs/full-refresh` in both repos (pushed). Corrected the MCP tool count (~50 not 17),
  nvim stats (62 modules / 55 commands), ports, SSE event count, test-framework support,
  and stripped the deprecated VS extension.
- **Gap B reclassified**: `SessionCreated`/`SessionStopped` are vestigial DU cases (session
  lifecycle is driven by the Elm `ListSessions` -> state render for the dashboard, and
  clients poll `GET /api/sessions`). Not a feature-breaking gap; not wired.

Test loop for this box (busted-via-luarocks doesn't work; nvim's luajit won't bind native
`lfs`): use plenary (see command below). Nothing merged to master yet — merging the SageFs
branches triggers the publish pipeline, so that is a release decision to confirm.

Remaining: P4 (confirm the live-testing/coverage path against a live daemon), P6 (nvim docs
accuracy), the SessionScribe `;;;;` double-semicolon cosmetic bug in export output, and a
`test.sh` + `run_busted.lua` fix so the suite runs on Linux.

---



One place for the whole picture: what's drifted from the daemon, what the docs get
wrong, how to run the tests on this machine, and the ordered work to fix it. Supersedes
the earlier `nvim-plugin-inspection.md` / `-grug.md` scratch reports.

Plugin is at `/home/will/Work/sagefs.nvim`. Daemon source of truth is
`/home/will/Work/SageFs`. Plugin version `0.5.543`; daemon `0.6.553`.

## Status in one paragraph

The plugin is well-built (~62 Lua modules, a pure/testable split, a large spec suite)
but a full minor version behind the daemon's wire protocol, and it missed the `0.5 -> 0.6`
SSE unification. Daily REPL work still works — eval, reset, sessions, completions,
warmup, test results, coverage badges, inline annotations. What broke is the live
push-notification surface: the daemon folded its many named SSE events into two envelope
events (`state`, `session`) plus a consolidated `test_summary`, and the plugin still
listens for the old flat names. So session-faulted, file-reloaded, system-alarm, and
live session create/stop no longer reach the plugin, and a chunk of the documented
scripting hooks can never fire.

## Test loop on this machine (works today)

busted-via-luarocks does not work here: `run_busted.lua` hardcodes Windows luarocks
paths, and the native `lfs` rock won't bind under nvim's embedded luajit
(`undefined symbol: luaL_register`). The plugin has only ever been exercised on Windows.

Use plenary (installed at `~/.local/share/nvim/lazy/plenary.nvim`) — it runs the
existing busted-style specs inside nvim with no luarocks:

```bash
# one spec file
nvim --headless --clean \
  --cmd "set rtp+=$HOME/.local/share/nvim/lazy/plenary.nvim" \
  --cmd "set rtp+=$(pwd)" \
  -c "PlenaryBustedFile spec/sse_spec.lua"

# whole directory
nvim --headless --clean \
  --cmd "set rtp+=$HOME/.local/share/nvim/lazy/plenary.nvim" \
  --cmd "set rtp+=$(pwd)" \
  -c "PlenaryBustedDirectory spec/ { minimal_init = 'spec/helper.lua' }"
```

Confirmed: `spec/sse_spec.lua` runs 55/0/0 green this way. A follow-up task is to add a
Linux-friendly `test.sh` wrapping this and update `TESTING.md`/`run_busted.lua`.

Integration specs (tree-sitter, real vim APIs) use the repo's own
`spec/nvim_harness.lua` via `nvim --headless --clean -u NONE -l spec/nvim_harness.lua`.
End-to-end SSE behavior needs a live daemon on 37749 (none running right now).

## The core mechanism (read once)

The daemon's `/events` stream (`SageFs/McpServer.fs:2081`) now emits, in the live loop,
every state change as a single event named `state` (`:2114`) plus named test/session
frames. The `SseEvent` DU (`SageFs/SseEvent.fs`) routes to two event names with the real
discriminant inside the JSON:

- **`state` channel** (`SseEvent.fs:51-59`) — `SessionProgress`, `SessionReady`,
  `SessionSwitched`, `HotReloadChanged`, `FileReloaded`, `SessionFaulted`, `ModelChanged`,
  `WarmupProgress`, `SystemAlarm`. JSON is a flat object keyed by a camelCase field
  (`{sessionFaulted, error}`, `{fileReloaded, sessionId}`, `{systemAlarm, phase, message}`,
  `{sessionReady}`, `{hotReloadChanged, sessionId}`, `{warmupProgress, sessionId, step, total}`,
  `{sessionSwitched}`, `{sessionProgress}`, `{outputCount, diagCount}`).
- **`session` channel** (`SseEvent.fs:159-184`) — carries an inner `type`:
  `warmup_context_snapshot`, `hotreload_snapshot`, `hotreload_file_toggled`,
  `session_activated`, `session_created`, `session_stopped`, `workflow_switching`,
  `workflow_switched`.

The plugin (`lua/sagefs/sse.lua:88`) still classifies by the old flat names and maps
`state -> state_update`, whose handler (`init.lua:207`) discards the payload. Confirmed:
`session_faulted`, `file_reloaded`, `system_alarm`, `session_created`, `session_stopped`,
`warmup_completed` have zero distinct emitters in the daemon — they exist only inside
these envelopes. `warmup_progress` is the exception: it also has its own emitter
(`SageFs/SseWriter.fs:91`), so the statusline warmup bar still works.

Still-live named frames the plugin already handles correctly: `test_summary`,
`test_results_batch`, `test_trace`, `test_source_locations`, `coverage_view`,
`file_annotations`, `eval_result`, `eval_diff`, `eval_timeline`, `cell_dependencies`,
`binding_scope_map`, `bindings_snapshot`, `failure_narratives`, `warmup_progress`.

Likely consolidated into `test_summary` (needs a live-daemon confirm, not yet done):
`tests_discovered`, `test_run_started`, `test_run_completed`, `affected_tests_computed`,
`providers_detected`, `run_tests_requested`, `test_cycle_timing_recorded`,
`live_testing_enabled`/`disabled`, `run_policy_changed`. Coverage: `coverage_updated`,
`coverage_cleared` likely folded into `coverage_view` + `file_annotations`.
`diagnostics_updated` may arrive on the separate `/diagnostics` stream the plugin also
opens.

## Work plan (ordered by leverage)

Each code task is TDD: RED spec under plenary, GREEN, refactor, then a live-daemon check
where the behavior needs the wire. Commit per task, plain-English messages.

### P1 — Decode the `state` envelope (highest user-visible win)
Rewrite `sse.lua` so a `state` event is classified by the field present in its JSON, and
`init.lua`'s handler routes to the existing `session_faulted` / `file_reloaded` /
`system_alarm` / hot-reload / warmup handlers with the correct field names
(`sessionFaulted`+`error`, not `session_id`+`reason`). Revives session-crash
notifications and file-reloaded handling.
Evidence: `sse.lua:94`, `init.lua:207,298`. Test: feed a `state` frame with
`{sessionFaulted, error}` and assert it classifies to the fault action (RED today).

### P2 — Complete the `session` envelope
Add `session_created`, `session_stopped`, `session_activated`, `hotreload_file_toggled`
branches to `init.lua`'s `session_event` handler so the session list updates live instead
of only on the next `/api/sessions` poll.
Evidence: `init.lua:229-251`; wire types `SseEvent.fs:168-174`.

### P3 — Fix `:SageFsExportFile`
It calls the dead `/api/history` (`commands.lua:1119`). The daemon serves
`/api/sessions/{sid}/export-fsx`. Repoint it.

### P4 — Confirm the test/coverage consolidation on a live daemon
Start a 0.6.x daemon, drive a session, and observe which frames actually arrive. Then
either delete the dead granular test/coverage handlers or re-derive their behavior from
`test_summary` / `coverage_view` fields. Update the live-testing doc's SSE table to match.

### P5 — Version sync + a health warning
Wire `sync-version.sh` into a hook so `version.lua` tracks the daemon, and add a check to
`:checkhealth sagefs` that warns when the daemon's minor version is ahead of the plugin's
build. This makes the next drift surface loudly.

### P6 — Documentation pass (do the protocol parts *with* P1/P2, not before)
- Reconcile the command count to 55 in all three docs (`SageFs/Readme.md:297` says 57;
  `docs/README.md` says 51; `README.md:451` says 55 = correct; real is 44 literal + 11
  in `commands.lua:13-92`).
- Module count: `SageFs/Readme.md:297` says 59; real is 62.
- Event count: `README.md` says 37 (lines 137, 567) and 38 (line 421); real is 38.
- Drop the phantom `density = "normal"` from the README config example (`README.md:178`)
  or wire it — nothing reads `config.density`; the real knob is `cell_highlight.style`
  (`init.lua:45-47`).
- Replace the Windows local-dev path/name (`README.md:189`,
  `dir = "C:/Code/Repos/sagefs-nvim"`).
- Add a "fires today?" column to the events table and rewrite `docs/README.md`'s
  "Communication Protocol" section to describe the `state`/`session` envelopes.
- Fix `docs/live-testing-as-you-type.md`'s "SSE Events" table (it lists autocmd names as
  SSE frames; five are dead) and its dead `./coverage.md` link.
- Replace hardcoded test counts (`docs/README.md` "1372/56/28"; `SageFs/Readme.md:297`
  "1400+") with a derive step or a plain pointer; `.last-run.json` currently reads
  `status: failed`.

### P0 (done this session) — Test loop
plenary command above proven. Task remainder: add `test.sh` + fix `run_busted.lua`/
`TESTING.md` for Linux.

## Dogfooding findings (live 0.6.551 daemon, isolated data dir)

Ran a real daemon and captured `/events` while driving a session. Results that changed
the plan:

- **P1 is proven against the real wire.** The `state` channel field names match the
  classifier exactly: `{outputCount, diagCount}` (model), `{warmupProgress, sessionId,
  step, total}` (warmup), `{sessionProgress}` (heartbeat). No guessing left here.
- **P2 is a daemon-side gap, not a plugin fix.** `SseEvent.SessionCreated` and
  `SessionStopped` are defined and have JSON serializers but are **never constructed for
  emission** anywhere in the daemon (only in the DU, the serializer, and no-op match arms
  at `McpServer.fs:1023-1024`, `Dashboard.fs:466-467`). Live proof: creating a session
  emitted only `state`-channel events; stopping one emitted `warmup_context_snapshot` +
  `hotreload_snapshot` (session channel) but **no `session_stopped`**. So adding plugin
  handlers for session_created/stopped would be dead code. The real fix, if live
  session-list updates are wanted, is daemon-side (make the daemon emit them). The plugin
  keeps its list fresh by polling `/api/sessions`. Session-channel events that DO fire and
  the plugin already handles: `warmup_context_snapshot`, `hotreload_snapshot`, and
  (on switch) `workflow_switching`/`workflow_switched`.
- **P3 export is broken on both ends.** `/api/history` → 404 (dead), and the assumed
  replacement `/api/sessions/{sid}/export-fsx` → 404 too: it is declared in
  `EndpointContracts.fs:49` but **never mapped as a route**. Both plugin export commands
  (`commands.lua:257` and `:1119`) hit dead endpoints. Options: implement the route in the
  daemon, or export locally in the plugin from SSE-accumulated history — `export.lua`'s
  `format_fsx(events)` is already pure and takes event data, so a plugin-local export
  needs no endpoint. Plugin-local is the cleaner, self-contained fix.

Net: the SSE-correctness core (P1) lands cleanly plugin-side; P2 and P3 surface daemon
gaps. The daemon fixes (emit SessionCreated/Stopped; implement or drop the export-fsx
route) are separate SageFs work, dogfooded through the SageFs REPL per mandate #1.

## What's confirmed vs inferred

Confirmed by reading daemon source + the plugin: the `state`/`session` envelope routing,
the dead handlers, the `/api/history` break, all doc counts, the phantom config key, the
version gap, the working plenary loop. Inferred (needs the live-daemon run in P4): that
the granular test/coverage events are consolidated rather than removed, so live testing
still *displays* but without granular toasts.
