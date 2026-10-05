-- sagefs/reload_state.lua — hot reload truth: closed sets, one display function, pure fold
-- Pure Lua, zero vim dependencies
--
-- What the daemon says a save did to the running process arrives as the
-- `reloadReported` object of the `state` SSE event, as `lastReload` on every
-- session report, and (in the worker's own stream) with a `type` cue, `reasons`
-- and `declarations` added. This module reads all three shapes into one report
-- and keeps the display wording in exactly one function, `M.display`, so the
-- statusline, the panel, the virtual text and the trunk lines cannot disagree
-- about what "applied" or "patched" means:
--
--   PatchPending  applied, new body has not run yet
--   Patched       patched (ran)
--   NeverEntered  applied, but the new body never ran
--   Restarted     restarted: <cause>
--   RestartRequired / CompileFailed / NoEffect / KeptLiveState likewise
--
-- A mechanism ("detour" or "metadata-delta") is read from the field and never
-- from the words of `message`. A token outside the closed sets is shown as
-- unrecognized rather than guessed at.

local closed_set = require("sagefs.closed_set")

local M = {}

-- ─── Closed sets ─────────────────────────────────────────────────────────────

--- SageFs.Core/SessionReload.fs ReloadCase, one token per case.
M.OUTCOME = closed_set.define("ReloadOutcome", {
  "Patched", "PatchPending", "NeverEntered", "Restarted",
  "NoEffect", "RestartRequired", "CompileFailed", "KeptLiveState",
})

--- SageFs.Core ReloadOutcome.PatchMechanism wire names. "" is a verdict that is not a patch.
M.MECHANISM = closed_set.define("PatchMechanism", {
  { "Detour", "detour" },
  { "MetadataDelta", "metadata-delta" },
  { "NoPatch", "" },
})

--- Where a report is in its life: nothing yet, a save compiling, a finished verdict.
M.PHASE = closed_set.define("ReloadPhase", {
  { "None", "none" },
  { "Compiling", "compiling" },
  { "Finished", "finished" },
})

--- SageFs.Core/Features/CallerState.fs CallersState, one token per case. A token
--- outside this set is read as KNOWN-unrecognised rather than guessed at: an
--- unknown state is a newer daemon, and guessing which of the four it meant would
--- put a caller's file in the wrong place.
M.CALLER_STATES = closed_set.define("CallersState", {
  "CallersCurrent", "CallersPending", "CallersNotChecked", "CallersNotReported",
})

--- Highlight group -> the standard group it links to. Applied by the UI layer
--- (and the dashboard's highlight table), defined here so display names them once.
M.HL = {
  SageFsReloadOk = "DiagnosticOk",
  SageFsReloadPending = "DiagnosticInfo",
  SageFsReloadWarn = "DiagnosticWarn",
  SageFsReloadError = "DiagnosticError",
  SageFsReloadQuiet = "Comment",
  SageFsReplBehind = "WarningMsg",
}

-- The worker's `type` cue, used only when the outcome token is missing.
local CUE_OUTCOME = {
  pending = "PatchPending",
  patched = "Patched",
  neverentered = "NeverEntered",
  restarted = "Restarted",
  noeffect = "NoEffect",
  failed = "CompileFailed",
}

-- ─── Parsing ─────────────────────────────────────────────────────────────────

local function text_or(v, default)
  if type(v) == "string" then return v end
  return default
end

local function count_or_zero(v)
  if type(v) == "number" then return v end
  return 0
end

local function list_of_strings(v)
  local out = {}
  if type(v) ~= "table" then return out end
  for _, item in ipairs(v) do
    if type(item) == "string" then table.insert(out, item) end
  end
  return out
end

local function parse_reasons(v)
  local out = {}
  if type(v) ~= "table" then return out end
  for _, r in ipairs(v) do
    if type(r) == "table" then
      table.insert(out, {
        case = text_or(r.case, ""),
        message = text_or(r.message, ""),
        suggested_action = text_or(r.suggestedAction, ""),
      })
    end
  end
  return out
end

local function parse_kept(v)
  local out = {}
  if type(v) ~= "table" then return out end
  for _, k in ipairs(v) do
    if type(k) == "table" then
      table.insert(out, {
        binding = text_or(k.binding, ""),
        kept_value = text_or(k.keptValue, ""),
        new_initializer = text_or(k.newInitializer, ""),
      })
    end
  end
  return out
end

--- One call site left on the old method. `resolved_by_compiler` is the honest
--- answer to "how sure are we": a site the compiler tied to the re-signed
--- declaration is a fact, and one matched only because the NAMES agree is a
--- guess the daemon labels as such. Drawing both as "a caller" claims a certainty
--- the second one does not have.
local function parse_site(v)
  if type(v) ~= "table" then return nil end
  local by_compiler = text_or(v.evidence, "") == "ResolvedByCompiler"
  return {
    file = text_or(v.file, ""),
    line = count_or_zero(v.line),
    caller = text_or(v.caller, ""),
    evidence = text_or(v.evidence, ""),
    resolved_by_compiler = by_compiler,
    name_only_reason = text_or(v.nameOnlyReason, nil),
    name_only_detail = text_or(v.nameOnlyDetail, nil),
  }
end

--- A declaration whose signature changed and whose callers are still on the old
--- method. Built only from a non-empty site list, so a pending entry with no
--- caller cannot exist (the daemon refuses to write one, and the plugin refuses to
--- show one).
local function parse_pending_entry(v)
  if type(v) ~= "table" then return nil end
  local sites = {}
  if type(v.sites) == "table" then
    for _, s in ipairs(v.sites) do
      local site = parse_site(s)
      if site then table.insert(sites, site) end
    end
  end
  if #sites == 0 then return nil end
  return {
    declaration = text_or(v.declaration, ""),
    cause = text_or(v.cause, ""),
    file = text_or(v.file, ""),
    sites = sites,
  }
end

--- A declaration nobody could list callers for, with the reason. `why_subject` and
--- `why_detail` carry whatever the reason is ABOUT (an operator's name, a
--- compiler error), so the reason can be read in words rather than decoded from a
--- token.
local function parse_unchecked_entry(v)
  if type(v) ~= "table" then return nil end
  return {
    declaration = text_or(v.declaration, ""),
    cause = text_or(v.cause, ""),
    file = text_or(v.file, ""),
    why = text_or(v.why, ""),
    why_subject = text_or(v.whySubject, ""),
    why_detail = text_or(v.whyDetail, ""),
  }
end

--- The `callers` object of a reload report (CallerState.toJson on the daemon side).
---
--- A payload with NO `callers` field is `CallersNotReported`, never `CallersCurrent`:
--- that is a worker predating the field, which has said nothing, and reading silence
--- as "all callers are current" claims a check nobody ran. The daemon pins the same
--- distinction in SageFs.Tests/CallerWireTests.
local function parse_callers(v)
  local out = {
    state = "CallersNotReported",
    known = false,
    message = nil,
    suggested_action = "",
    pending = {},
    not_checked = {},
  }
  if type(v) ~= "table" then return out end
  local state = text_or(v.state, "")
  if state == "" then return out end
  out.state = state
  out.known = M.CALLER_STATES.has(state)
  out.message = text_or(v.message, nil)
  out.suggested_action = text_or(v.suggestedAction, "")
  if type(v.pending) == "table" then
    for _, p in ipairs(v.pending) do
      local entry = parse_pending_entry(p)
      if entry then table.insert(out.pending, entry) end
    end
  end
  if type(v.notChecked) == "table" then
    for _, u in ipairs(v.notChecked) do
      local entry = parse_unchecked_entry(u)
      if entry then table.insert(out.not_checked, entry) end
    end
  end
  return out
end

--- Read a reload report from any of its three wire shapes.
--- Returns nil when there is no report (null, absent, not an object, or an object
--- that is neither a compiling frame nor a finished verdict).
---@param payload any
---@return table|nil report
function M.parse(payload)
  if type(payload) ~= "table" then return nil end
  local cue = payload.type
  if cue == "none" then
    return {
      phase = M.PHASE.None, known = true, declarations = {}, reasons = {}, kept = {},
      patched = 0, considered = 0, callers = parse_callers(nil),
    }
  end
  local phase
  local outcome = payload.outcome
  if type(outcome) ~= "string" and type(cue) == "string" then outcome = CUE_OUTCOME[cue] end
  if payload.state == "compiling" or cue == "compiling" then
    phase = M.PHASE.Compiling
    outcome = nil
  elseif type(outcome) == "string" then
    phase = M.PHASE.Finished
  else
    return nil
  end
  return {
    phase = phase,
    outcome = outcome,
    known = outcome == nil or M.OUTCOME.has(outcome),
    mechanism = text_or(payload.mechanism, ""),
    patched = count_or_zero(payload.patched),
    considered = count_or_zero(payload.considered),
    message = text_or(payload.message, ""),
    suggested_action = text_or(payload.suggestedAction, ""),
    declarations = list_of_strings(payload.declarations),
    reasons = parse_reasons(payload.reasons),
    kept = parse_kept(payload.kept),
    file = text_or(payload.file, nil),
    -- `callers` rides the reloadReported object AND lastReload on a session report,
    -- both written by CallerState.toJson. A payload without it is NotReported.
    callers = parse_callers(payload.callers),
  }
end

-- ─── Display: the one function that maps a report to words ───────────────────

local function first_line(s)
  local line = (s or ""):match("^[^\n]*") or ""
  return (line:gsub("^%s+", ""):gsub("%s+$", ""))
end

local EM_DASH = "\226\128\148"

-- How each outcome's message prefixes its cause, so the cause can be read out of
-- the daemon wire, which does not carry `reasons`.
local function cause_from_message(outcome, message)
  local line = first_line(message)
  if line == "" then return nil end
  local stripped
  if outcome == M.OUTCOME.Restarted then
    stripped = line:match("^Restarted the app: (.*)$")
  elseif outcome == M.OUTCOME.RestartRequired then
    stripped = line:match("^Restart needed: (.*)$")
  elseif outcome == M.OUTCOME.CompileFailed then
    stripped = line:match("last good code: (.*)$")
  elseif outcome == M.OUTCOME.NoEffect then
    stripped = line:match("reached the running app " .. EM_DASH .. " (.*)$")
  end
  return stripped or line
end

--- The cause behind a restart-shaped verdict: the first named reason when the
--- payload has reasons, otherwise the cause the message states.
---@param report table
---@return table|nil cause { case: string|nil, text: string, more: integer }
function M.cause(report)
  if not report then return nil end
  local first = report.reasons and report.reasons[1]
  if first then
    return {
      case = first.case ~= "" and first.case or nil,
      text = first_line(first.message),
      more = #report.reasons - 1,
    }
  end
  local text = cause_from_message(report.outcome, report.message)
  if not text then return nil end
  return { text = text, more = 0 }
end

local function cause_text(cause)
  if not cause then return nil end
  local out
  if cause.case and cause.text ~= "" then
    out = cause.case .. ", " .. cause.text
  elseif cause.case then
    out = cause.case
  else
    out = cause.text
  end
  if cause.more and cause.more > 0 then
    out = out .. string.format(" (and %d more)", cause.more)
  end
  return out
end

local MECHANISM_TEXT = {
  [M.MECHANISM.Detour] = { text = "via detour", tag = "detour" },
  [M.MECHANISM.MetadataDelta] = { text = "via metadata delta", tag = "delta" },
}

local function mechanism_of(report)
  local m = report.mechanism
  if m == nil or m == M.MECHANISM.NoPatch then return nil, nil, nil end
  local known = MECHANISM_TEXT[m]
  if known then return m, known.text, known.tag end
  return m, string.format("via unrecognized mechanism '%s'", m), m
end

local MAX_NAMES = 5

--- "patched: A.f, A.g and 3 more" from the structured `declarations` field of a
--- PatchPending frame, or nil when the daemon sent none.
local function declared_names(report)
  local names = report.declarations
  if type(names) ~= "table" or #names == 0 then return nil end
  local shown = {}
  for i = 1, math.min(MAX_NAMES, #names) do shown[i] = names[i] end
  local text = "patched: " .. table.concat(shown, ", ")
  if #names > MAX_NAMES then text = text .. string.format(" and %d more", #names - MAX_NAMES) end
  return text
end

local FADE_OK_MS = 15000
local FADE_QUIET_MS = 8000

--- Map a report to everything a surface needs to show it.
---@param report table|nil
---@return table|nil display { key, text, short, icon, hl, severity, notify_level, attention, fade_ms, mechanism, mechanism_text, tag, cause, remedy }
function M.display(report)
  if not report then return nil end
  local d = {
    severity = "quiet", hl = "SageFsReloadQuiet", icon = "○", attention = false,
  }
  if report.phase == M.PHASE.None then
    d.key = "None"
    d.text = "no hot reload yet"
    d.short = "no hot reload yet"
    return d
  end
  if report.phase == M.PHASE.Compiling then
    local name = report.file and report.file:match("([^/\\]+)$") or nil
    d.key = "Compiling"
    d.icon = "…"
    d.severity, d.hl = "info", "SageFsReloadPending"
    d.text = name and ("compiling " .. name) or "compiling"
    d.short = "compiling"
    return d
  end

  local outcome = report.outcome
  d.key = outcome
  d.mechanism, d.mechanism_text, d.tag = mechanism_of(report)
  d.remedy = first_line(report.suggested_action)
  if d.remedy == "" then d.remedy = nil end

  if not M.OUTCOME.has(outcome) then
    d.icon = "?"
    d.severity, d.hl, d.notify_level, d.attention = "warn", "SageFsReloadWarn", "warn", true
    d.text = string.format("unrecognized reload outcome '%s'", tostring(outcome))
    d.short = "unrecognized reload outcome"
    return d
  end

  if outcome == M.OUTCOME.PatchPending then
    d.icon = "◐"
    d.severity, d.hl = "info", "SageFsReloadPending"
    d.text = "applied, new body has not run yet"
    d.short = "applied, not run yet"
    d.detail = declared_names(report)
  elseif outcome == M.OUTCOME.Patched then
    d.icon = "●"
    d.severity, d.hl, d.fade_ms = "ok", "SageFsReloadOk", FADE_OK_MS
    d.text = "patched (ran)"
    d.short = "patched (ran)"
  elseif outcome == M.OUTCOME.NeverEntered then
    d.icon = "◌"
    d.severity, d.hl, d.notify_level, d.attention = "warn", "SageFsReloadWarn", "warn", true
    if report.considered > 0 then
      d.text = string.format(
        "applied, but the new body never ran (%d of %d did): exercise it, or the callee was inlined",
        report.patched, report.considered)
    else
      d.text = "applied, but the new body never ran: exercise it, or the callee was inlined"
    end
    d.short = "applied, never ran"
    -- Which code did not run is in the daemon's own first line ("Not confirmed:
    -- the new code for Logic.neverCalled has not run since the save"); a save
    -- can change several methods, and the counts alone do not say which.
    local line = first_line(report.message)
    if line ~= "" then d.detail = line end
  elseif outcome == M.OUTCOME.Restarted then
    d.icon = "↻"
    d.severity, d.hl, d.notify_level, d.attention = "warn", "SageFsReloadWarn", "info", true
    d.cause = M.cause(report)
    local why = cause_text(d.cause)
    d.text = why and ("restarted: " .. why) or "restarted"
    d.short = "restarted"
  elseif outcome == M.OUTCOME.RestartRequired then
    d.icon = "↻"
    d.severity, d.hl, d.notify_level, d.attention = "error", "SageFsReloadError", "error", true
    d.cause = M.cause(report)
    local why = cause_text(d.cause)
    d.text = why and ("restart needed: " .. why) or "restart needed"
    d.short = (d.cause and d.cause.case) and ("restart needed: " .. d.cause.case) or "restart needed"
  elseif outcome == M.OUTCOME.CompileFailed then
    d.icon = "✗"
    d.severity, d.hl, d.notify_level, d.attention = "error", "SageFsReloadError", "error", true
    d.cause = M.cause(report)
    local base = "did not compile; the app keeps running the last code that did"
    d.text = (d.cause and d.cause.text ~= "") and (base .. ": " .. d.cause.text) or base
    d.short = "compile failed"
  elseif outcome == M.OUTCOME.NoEffect then
    d.icon = "○"
    d.severity, d.hl, d.fade_ms = "quiet", "SageFsReloadQuiet", FADE_QUIET_MS
    if report.reasons[1] then
      d.cause = M.cause(report)
      d.text = "no effect: " .. cause_text(d.cause)
    elseif report.counts_unknown then
      -- A trunk line carries the case and no counts; "0 of 0" would be invented.
      d.text = "no effect"
    else
      d.text = string.format(
        "no effect (%d of %d changed definitions reached the running app)",
        report.patched, report.considered)
    end
    d.short = "no effect"
  elseif outcome == M.OUTCOME.KeptLiveState then
    d.icon = "●"
    d.severity, d.hl, d.fade_ms = "ok", "SageFsReloadOk", FADE_OK_MS
    local k = report.kept[1]
    if k then
      d.text = string.format(
        "kept live value %s = %s (the new initializer %s applies when you reset it)",
        k.binding, k.kept_value, k.new_initializer)
      if #report.kept > 1 then d.text = d.text .. string.format(" (and %d more)", #report.kept - 1) end
    else
      d.text = "kept live value"
    end
    d.short = "kept live value"
  end
  return d
end

-- ─── Statusline and panel lines ──────────────────────────────────────────────

--- A compact statusline segment, or "" when there is nothing to say. A settled
--- harmless verdict (patched, kept, no effect) fades when the caller supplies the
--- time; a report only a session list has seen shows only if it is a problem.
---@param report table|nil
---@param now_ms number|nil
---@return string
function M.statusline(report, now_ms)
  local d = M.display(report)
  if not d or report.phase == M.PHASE.None then return "" end
  if d.fade_ms then
    if report.polled then return "" end
    if now_ms and report.seen_ms and (now_ms - report.seen_ms) > d.fade_ms then return "" end
  end
  local seg = "HR " .. d.icon .. " " .. d.short
  if d.tag then seg = seg .. " [" .. d.tag .. "]" end
  return seg
end

local MAX_CAUSES = 3

local function is_quiet_no_effect(report)
  return report
    and report.outcome == M.OUTCOME.NoEffect
    and report.considered == 0
    and #report.reasons == 0
end

--- Whether this report is a no-op that must not take over the display.
---
--- The daemon records EVERY terminal event as the session's `lastReload`,
--- including a `noeffect` produced by an eval the save produced nothing from
--- (SageFs/DaemonMode.fs:3001 relays each payload straight to
--- `ReloadObserved`). So an eval sitting behind a patched save replaces "patched
--- (ran)" with "no effect" and the user reads a working hot reload as broken.
---
--- A no-effect with nothing considered and no reason names nothing: there is no
--- verdict in it to show, so it is kept in the model (the state is real) but it
--- does not become what is displayed. An older daemon sends the same no-op, so
--- this guard is the plugin's own and does not wait on a daemon change.
---@param report table|nil
---@return boolean
function M.is_a_no_op(report)
  return is_quiet_no_effect(report) == true
end

--- Lines for a panel: the truth, the mechanism, the named causes, the remedy.
---@param report table|nil
---@param previous table|nil the settled verdict this one replaced, shown under a quiet no-effect
---@return { text: string, hl: string }[]
function M.lines(report, previous)
  local d = M.display(report)
  if not d then return {} end
  local lines = { { text = d.icon .. " " .. d.text, hl = d.hl } }
  if d.mechanism_text then
    table.insert(lines, { text = "  " .. d.mechanism_text, hl = "SageFsReloadQuiet" })
  end
  if d.detail then
    table.insert(lines, { text = "  " .. d.detail, hl = "SageFsReloadQuiet" })
  end
  if report.reasons and #report.reasons > 0 then
    for i = 1, math.min(MAX_CAUSES, #report.reasons) do
      local r = report.reasons[i]
      table.insert(lines, { text = string.format("  cause: %s: %s", r.case, first_line(r.message)), hl = "SageFsReloadQuiet" })
    end
    if #report.reasons > MAX_CAUSES then
      table.insert(lines, { text = string.format("  and %d more", #report.reasons - MAX_CAUSES), hl = "SageFsReloadQuiet" })
    end
  end
  if report.outcome ~= M.OUTCOME.KeptLiveState and report.kept and #report.kept > 0 then
    for _, k in ipairs(report.kept) do
      table.insert(lines, {
        text = string.format("  kept %s = %s (the new initializer %s applies when you reset it)", k.binding, k.kept_value, k.new_initializer),
        hl = "SageFsReloadQuiet",
      })
    end
  end
  -- The callers section rides with the panel, between the causes and the remedy:
  -- "these files are still on the old method" is the reason a patched save is not
  -- yet done.
  --
  -- The callers' OWN `suggestedAction` is NOT printed here: `d.remedy` below is the
  -- remedy the panel already prints, and CallerState.remedy leads with the callers'
  -- when they are pending (the outcome's own words stay in the message). Printing
  -- both put "→ Save Pages.fs" on the panel twice, which is what the first version
  -- of this did.
  for _, l in ipairs(M.callers_lines(report)) do
    table.insert(lines, { text = l, hl = "SageFsReloadQuiet" })
  end
  if d.remedy then
    table.insert(lines, { text = "  → " .. d.remedy, hl = d.hl })
  end
  if previous and is_quiet_no_effect(report) then
    local pd = M.display(previous)
    if pd then
      table.insert(lines, { text = "  last save: " .. pd.text, hl = pd.hl })
    end
  end
  return lines
end

-- ─── The callers section: what a save left behind in other files ─────────────

--- How a site reads, in one line: where it is, and how sure the check is. The
--- certainty is part of the line and not a decoration: a site the compiler tied to
--- the re-signed declaration and one matched only because the names agree are both
--- "a caller", and only one of them is a fact.
local function site_text(s)
  local where = string.format("%s:%d", s.file, s.line)
  if s.caller ~= "" then
    where = where .. "  in " .. s.caller
  else
    where = where .. "  (outside any declaration)"
  end
  if s.resolved_by_compiler then return where end
  local why = s.name_only_reason or "MatchedByName"
  if s.name_only_detail and s.name_only_detail ~= "" then
    why = why .. " (" .. first_line(s.name_only_detail) .. ")"
  end
  return where .. "  matched by name, not by the compiler: " .. why
end

--- The lines for the callers section, or none at all.
---
--- NO LINES for `CallersCurrent` and none for `CallersNotReported`: in the first
--- nothing was left behind, and in the second nobody said. An empty section headed
--- "callers" would read as "no callers", which is the one claim the second state
--- cannot support.
---
--- The WORDS are the daemon's (`message`, `suggestedAction`); what is added here is
--- the list of files and lines, because a sentence naming one file cannot list six.
---
--- The callers' `suggestedAction` is read into the model and NOT printed here. The
--- panel prints ONE remedy (`M.lines`'s `d.remedy`), and `CallerState.remedy` already
--- leads with the callers' action when they are pending, so printing it here too put
--- "→ Save Pages.fs" on the panel twice.
---@param report table|nil
---@return string[] lines
function M.callers_lines(report)
  if type(report) ~= "table" then return {} end
  local c = report.callers
  if type(c) ~= "table" then return {} end
  if c.state == "CallersCurrent" or c.state == "CallersNotReported" then return {} end
  if #c.pending == 0 and #c.not_checked == 0 then return {} end

  local out = {}
  if c.message and c.message ~= "" then
    table.insert(out, "  callers: " .. first_line(c.message))
  end
  for _, p in ipairs(c.pending) do
    table.insert(out, string.format("    %s (%s, in %s)", p.declaration, p.cause, p.file))
    for _, s in ipairs(p.sites) do
      table.insert(out, "      " .. site_text(s))
    end
  end
  for _, u in ipairs(c.not_checked) do
    local why = u.why
    if u.why_subject and u.why_subject ~= "" then why = why .. ": " .. u.why_subject end
    if u.why_detail and u.why_detail ~= "" then why = why .. " (" .. first_line(u.why_detail) .. ")" end
    table.insert(out, string.format("    not checked: %s (%s) — %s", u.declaration, u.cause, why))
  end
  return out
end

-- ─── Model: the latest report per session ────────────────────────────────────

local function copy_map(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

--- A fresh model: latest report per session, the settled verdict each replaced,
--- and the last no-op per session (kept apart, because a no-op must not be
--- displayed: see `M.observe`).
function M.model_new()
  return { by_session = {}, previous = {}, last_sid = nil, last_noop = {} }
end

local function is_verdict(report)
  return report ~= nil
    and report.phase == M.PHASE.Finished
    and not is_quiet_no_effect(report)
end

--- Record a report for a session. `source` is "sse" (an event said it) or "poll"
--- (a session list said it); `now_ms` stamps when, so a harmless verdict can fade.
---
--- A quiet no-effect does NOT take over the display. It is recorded under
--- `last_noop` so the state is not lost, and the verdict the user is actually
--- looking at stays put. It is also not pushed into `previous`, because it is not
--- a verdict: it names nothing, so it cannot be the "last save" a panel shows
--- under a real one. Without this, an eval behind a patched save reads as a
--- broken hot reload (see `M.is_a_no_op`).
function M.observe(model, sid, report, source, now_ms)
  local out = { by_session = copy_map(model.by_session), previous = copy_map(model.previous),
                last_sid = sid, last_noop = copy_map(model.last_noop or {}) }
  local old = model.by_session[sid]
  local stamped = {}
  for k, v in pairs(report) do stamped[k] = v end
  stamped.source = source
  stamped.polled = (source == "poll")
  stamped.seen_ms = now_ms
  if M.is_a_no_op(stamped) then
    out.last_noop = copy_map(model.last_noop or {})
    out.last_noop[sid] = stamped
    -- Nothing else changes: by_session, previous and last_sid keep what they
    -- held, so the displayed verdict is exactly what it was. When there was
    -- never a verdict, the no-op is the only word there is, so it is shown:
    -- "no hot reload yet" would be a worse answer than the truth.
    if not model.by_session[sid] then out.by_session[sid] = stamped end
    return out
  end
  if is_verdict(old) and old ~= nil then out.previous[sid] = old end
  out.by_session[sid] = stamped
  return out
end

local function copy_last_noop(model)
  return copy_map(model.last_noop or {})
end

local function clear_session(model, sid)
  local out = { by_session = copy_map(model.by_session), previous = copy_map(model.previous), last_sid = model.last_sid,
                last_noop = copy_last_noop(model) }
  out.by_session[sid] = nil
  out.previous[sid] = nil
  out.last_noop[sid] = nil
  return out
end

--- Fold one `state` envelope that carries a reload report (or its absence).
---@return table model, table info { changed: boolean, sid: string|nil, report: table|nil, cleared: boolean|nil }
function M.apply_sse(model, data, now_ms)
  if type(data) ~= "table" then return model, { changed = false } end
  local sid = data.sessionId or data.SessionId
  if type(sid) ~= "string" then return model, { changed = false } end
  local raw = data.reloadReported
  if type(raw) == "table" then
    local report = M.parse(raw)
    if not report then return model, { changed = false } end
    return M.observe(model, sid, report, "sse", now_ms), { changed = true, sid = sid, report = report }
  end
  return clear_session(model, sid), { changed = true, sid = sid, cleared = true }
end

--- The report a surface should show for a session: the live one, else the last
--- verdict, and never a no-op. A session list polled right after an eval reports
--- the daemon's no-op as `lastReload`, so the poll path needs the same guard the
--- event path has; without it a polled list would undo the fix for the one
--- surface (the statusline) that re-reads on every eval.
---@param model table
---@param sid string|nil
---@param polled table|nil the session row's own last_reload, when there is one
---@return table|nil
function M.displayable(model, sid, polled)
  if type(model) ~= "table" then return M.is_a_no_op(polled) and nil or polled end
  if not sid then return polled end
  local live = model.by_session[sid]
  local held = (model.last_noop or {})[sid]
  -- Something real to show: the live verdict, else the verdict it replaced.
  if live and not M.is_a_no_op(live) then return live end
  -- A no-op only steps aside when a real verdict is already on the books. A
  -- session whose saves have all done nothing still shows its no-op: it is the
  -- only word there is, and "no hot reload yet" would be a worse answer.
  if model.previous[sid] then return model.previous[sid] end
  if not polled then return held or live end
  if M.is_a_no_op(polled) then return nil end
  return polled
end

--- Drop one session's report and the verdict it replaced.
function M.forget(model, sid)
  return clear_session(model, sid)
end

function M.current(model, sid)
  return model.by_session[sid]
end

function M.previous(model, sid)
  return model.previous[sid]
end

--- The report that changed most recently, for a surface with no session in hand.
function M.latest(model)
  if model.last_sid then return model.by_session[model.last_sid], model.last_sid end
  return nil, nil
end

--- Seed from a normalized session list: believe it for a session no event has
--- spoken for, and never override a report an event delivered.
function M.seed(model, sessions)
  local out = model
  for _, s in ipairs(sessions or {}) do
    if s.id then
      local existing = out.by_session[s.id]
      if not (existing and existing.source == "sse") then
        if s.last_reload then
          out = M.observe(out, s.id, s.last_reload, "poll", nil)
        elseif existing then
          out = clear_session(out, s.id)
        end
      end
    end
  end
  return out
end

--- Forget every report an event delivered (the connection dropped, so events may
--- have been missed); the next session list is believed again.
function M.drop_events(model)
  local out = { by_session = {}, previous = {}, last_sid = model.last_sid, last_noop = {} }
  for sid, report in pairs(model.by_session) do
    if report.source ~= "sse" then
      out.by_session[sid] = report
      out.previous[sid] = model.previous[sid]
    end
  end
  return out
end

return M
