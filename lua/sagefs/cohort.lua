-- sagefs/cohort.lua — the cohort and the trunk, read from get_cohort_status
-- Pure Lua, zero vim dependencies
--
-- One cohort spans every session and agent in a REPOSITORY, and one daemon holds one
-- cohort per repository — each with its own conductor seat, so a user with two
-- repositories open never has them contend. The caller says which by passing
-- `working_directory`. `get_cohort_status`
-- answers in text (SageFs.Core/Features/CohortStatusText.fs plus the integration
-- and Trunk lines of McpCohortIntegration.getCohortStatus):
--
--   Cohort ledger head: v13853
--   Conductor: mcp:...
--   Members (n):            "  - <id> [Role] present" or "departed <time>"
--   Claims (n):             "  - <id> <scope> held-by=<id> fence=<n> state=<%A>"
--   Integration head: <sha>
--   Landings (n):           "  - <id> requester=<id> state=<%A> <queue> statement=\"..\" commits=[..]"
--   Integration session: ...
--   Trunk: checkout=<path> landings (n):
--     trunk <landingId>: <verdict>
--
-- A member id is one of three forms. `mcp:m-<16 hex>` is a connection's one-way
-- fingerprint, `cap:<hex>` is a run minted with mint_member (a capability token is
-- its own member), and an older daemon prints `mcp:<Mcp-Session-Id>`, which is the
-- bearer handle of that agent's MCP connection. The first two are not secrets and
-- are shown whole. The third still is one, so mask_member hides it, and `%A` of a
-- claim's state can print it again, so a state is reduced to its case name.

local reload_state = require("sagefs.reload_state")

local M = {}

-- ─── Small helpers ───────────────────────────────────────────────────────────

local ELLIPSIS = "…"
local EM_DASH = "\226\128\148"

--- What kind of member an id names: "connection" (`mcp:m-<16 hex>`), "capability"
--- (`cap:<hex>`, a minted run), "legacy" (an older daemon's `mcp:<session id>`) or
--- "other".
---@param id string|nil
---@return string
function M.member_kind(id)
  if type(id) ~= "string" then return "other" end
  if id:match("^mcp:m%-%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") then return "connection" end
  if id:match("^cap:%x+$") then return "capability" end
  if id:match("^mcp:.") then return "legacy" end
  return "other"
end

--- A member id for display. Fingerprints and minted ids are shown whole. An id from
--- an older daemon is its connection's bearer handle, so only `mcp:` and the first
--- six characters are kept.
---@param id string|nil
---@return string
function M.mask_member(id)
  if type(id) ~= "string" then return "" end
  if M.member_kind(id) == "legacy" then
    local rest = id:sub(5)
    if #rest > 6 then return "mcp:" .. rest:sub(1, 6) .. ELLIPSIS end
  end
  return id
end

local function plural(n, word)
  if n == 1 then return string.format("1 %s", word) end
  return string.format("%d %ss", n, word)
end

-- ─── Trunk verdicts ──────────────────────────────────────────────────────────

-- Split on "; " outside parentheses: a cause list sits inside the parentheses.
local function split_top_level(text, separator)
  local parts = {}
  local depth, start, i = 0, 1, 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == "(" then
      depth = depth + 1
    elseif c == ")" then
      depth = math.max(0, depth - 1)
    elseif depth == 0 and text:sub(i, i + #separator - 1) == separator then
      table.insert(parts, text:sub(start, i - 1))
      start = i + #separator
      i = i + #separator - 1
    end
    i = i + 1
  end
  table.insert(parts, text:sub(start))
  return parts
end

local function parse_file(entry)
  local file, reason = entry:match("^(%S+) needs a rebuild: (.*)$")
  if file then return { kind = "NeedsRebuild", file = file, reason = reason } end
  file = entry:match("^(%S+) is not watched, so nothing ran$")
  if file then return { kind = "NotWatched", file = file } end
  file, reason = entry:match("^(%S+) ran the save pipeline and it reached no verdict: (.*)$")
  if file then return { kind = "NoVerdict", file = file, reason = reason } end
  local name, case, rest = entry:match("^(%S+) (%a+)(.*)$")
  if not name then return { kind = "Unrecognized", text = entry } end
  local mechanism = rest:match("^ by ([%w%-]+)") or ""
  local cause_text = rest:match("%((.*)%)%s*$")
  local cause
  if cause_text then
    local first = split_top_level(cause_text, "; ")[1]
    local case_token, message = first:match("^(%a+): (.*)$")
    cause = case_token and { case = case_token, message = message } or { message = first }
  end
  return {
    kind = "Reloaded", file = name, case = case, mechanism = mechanism, cause = cause,
    known = reload_state.OUTCOME.has(case),
  }
end

local function parse_delivery(chunk)
  local session, body = chunk:match("^session (%S+): (.*)$")
  if not session then return { kind = "Unrecognized", text = chunk } end
  local d = { session = session }
  if body:find("^no running app to update") then
    d.kind = "NoApp"
    d.detail = body:match("%((.*)%)%s*$")
  elseif body == "the landing changed no file the app runs" then
    d.kind = "NoFiles"
  elseif body:find("^no hot reload pipeline: ") then
    d.kind, d.reason = "NoPipeline", body:match("^no hot reload pipeline: (.*)$")
  elseif body:find("^did not answer: ") then
    d.kind, d.reason = "Unreachable", body:match("^did not answer: (.*)$")
  elseif body:find("^not available: ") then
    d.kind, d.reason = "Unavailable", body:match("^not available: (.*)$")
  else
    d.kind = "Delivered"
    d.files = {}
    for _, entry in ipairs(split_top_level(body, "; ")) do
      table.insert(d.files, parse_file(entry))
    end
  end
  return d
end

--- Read one `trunk <id>: <verdict>` verdict (TrunkFollow.describeVerdict and the
--- in-flight and queued lines of TrunkFollow.statusLines).
---@param text string
---@return table verdict { kind, text, ... }
function M.parse_trunk_verdict(text)
  local verdict = { text = text }
  if text == "no session works in the trunk checkout" then
    verdict.kind = "NoTrunkSession"
  elseif text:find("^the trunk checkout did not move: ") then
    verdict.kind = "NotMoved"
    verdict.reason = text:match("^the trunk checkout did not move: (.*)$")
  elseif text:find("^following %(") then
    verdict.kind = "Following"
    verdict.detail = text:match("^following %((.*)%)$")
  elseif text == "queued behind the landing in flight" then
    verdict.kind = "Queued"
  elseif text:find("^session ") then
    verdict.kind = "Followed"
    verdict.deliveries = {}
    -- Deliveries are joined by "; session ", files within one by "; ".
    local starts = { 1 }
    local from = 1
    while true do
      local at = text:find("; session ", from, true)
      if not at then break end
      table.insert(starts, at + 2)
      from = at + 1
    end
    for i, s in ipairs(starts) do
      local stop = starts[i + 1] and (starts[i + 1] - 3) or #text
      table.insert(verdict.deliveries, parse_delivery(text:sub(s, stop)))
    end
  else
    verdict.kind = "Unrecognized"
  end
  return verdict
end

-- ─── Status text ─────────────────────────────────────────────────────────────

local function parse_integration_session(rest)
  if rest:find("^%(not configured") then return { kind = "NotConfigured" } end
  local id = rest:match("^(%S+) %(started%)$")
  if id then return { kind = "Started", id = id } end
  local reason = rest:match("^FAILED to start " .. EM_DASH .. " (.*)$")
  if reason then return { kind = "Failed", reason = reason } end
  if rest == "pending" then return { kind = "Pending" } end
  return { kind = "Unrecognized", text = rest }
end

local function parse_member(line)
  local id, role, seat_text = line:match("^%s+%- (%S+) %[(%w+)%] (.*)$")
  if not id then return nil end
  local m = { id = id, role = role, kind = M.member_kind(id) }
  local since = seat_text:match("^departed (.*)$")
  if since then
    m.seat, m.since = "departed", since
  else
    m.seat = seat_text
  end
  return m
end

local function parse_claim(line)
  local id, scope, holder, fence, state = line:match("^%s+%- (%S+) (.-) held%-by=(%S+) fence=(%d+) state=(.*)$")
  if not id then return nil end
  return { id = id, scope = scope, held_by = holder, fence = tonumber(fence), state = state:match("^%a+") or state }
end

local QUEUE_SUFFIXES = { " not queued$", " front of queue$", " position %d+ in queue$" }

local function parse_landing(line)
  local marker = ' statement="'
  local at = line:find(marker, 1, true)
  if not at then return nil end
  local left, right = line:sub(1, at - 1), line:sub(at + 1)
  local statement, commits = right:match('^statement="(.*)" commits=%[(.*)%]$')
  if not statement then return nil end
  local id, requester, state_and_queue = left:match("^%s+%- (%S+) requester=(%S+) state=(.*)$")
  if not id then return nil end
  local queue, state = "", state_and_queue
  for _, suffix in ipairs(QUEUE_SUFFIXES) do
    local q = state_and_queue:match(suffix)
    if q then
      queue = q:gsub("^%s+", "")
      state = state_and_queue:sub(1, #state_and_queue - #q)
      break
    end
  end
  local list = {}
  for sha in commits:gmatch("[^,]+") do table.insert(list, sha) end
  return {
    id = id, requester = requester, state = state:match("^%a+") or state, queue = queue,
    statement = statement, commits = list,
  }
end

--- Parse get_cohort_status text. nil when it is not a cohort status (an error
--- text, an empty reply).
---@param text string|nil
---@return table|nil model
function M.parse_status(text)
  if type(text) ~= "string" then return nil end
  local version = text:match("^Cohort ledger head: v(%d+)")
  if not version then return nil end
  local model = {
    version = tonumber(version),
    members = {}, members_total = 0,
    claims = {}, claims_total = 0,
    landings = {}, landings_total = 0,
    overflow = {},
    integration_session = { kind = "Unknown" },
  }
  local section
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local conductor = line:match("^Conductor: (.*)$")
    local members_total = line:match("^Members %((%d+)%):$")
    local claims_total = line:match("^Claims %((%d+)%):$")
    local landings_total = line:match("^Landings %((%d+)%):$")
    local integration_head = line:match("^Integration head: (.*)$")
    local integration_session = line:match("^Integration session: (.*)$")
    local trunk_checkout, trunk_count = line:match("^Trunk: checkout=(.-) landings %((%d+)%):$")
    if conductor then
      model.conductor = conductor
      section = nil
    elseif members_total then
      model.members_total = tonumber(members_total)
      section = "members"
    elseif claims_total then
      model.claims_total = tonumber(claims_total)
      section = "claims"
    elseif line == "Landings: (none)" then
      model.landings_total = 0
      section = nil
    elseif landings_total then
      model.landings_total = tonumber(landings_total)
      section = "landings"
    elseif integration_head then
      model.integration_head = integration_head
      section = nil
    elseif integration_session then
      model.integration_session = parse_integration_session(integration_session)
      section = nil
    elseif trunk_checkout then
      model.trunk = { checkout = trunk_checkout, count = tonumber(trunk_count), landings = {} }
      section = "trunk"
    elseif section == "trunk" then
      local id, verdict = line:match("^%s+trunk (%S+): (.*)$")
      if id then
        table.insert(model.trunk.landings, { id = id, verdict = M.parse_trunk_verdict(verdict) })
      end
    elseif section and line:match("^%s+%+%d+ more ") then
      table.insert(model.overflow, (line:gsub("^%s+", "")))
    elseif section == "members" then
      local m = parse_member(line)
      if m then table.insert(model.members, m) end
    elseif section == "claims" then
      local c = parse_claim(line)
      if c then table.insert(model.claims, c) end
    elseif section == "landings" then
      local l = parse_landing(line)
      if l then table.insert(model.landings, l) end
    end
  end
  return model
end

-- ─── Rendering ───────────────────────────────────────────────────────────────

local SEVERITY_RANK = { quiet = 0, ok = 1, info = 2, warn = 3, error = 4 }

-- A trunk file outcome, in the words the reload display uses for the same case.
local function describe_file(f)
  if f.kind == "NeedsRebuild" then
    return f.file .. " needs a rebuild: " .. f.reason, "warn", "SageFsReloadWarn"
  elseif f.kind == "NotWatched" then
    return f.file .. " is not watched, so nothing ran", "quiet", "SageFsReloadQuiet"
  elseif f.kind == "NoVerdict" then
    return f.file .. " ran the save pipeline and it reached no verdict: " .. f.reason, "warn", "SageFsReloadWarn"
  elseif f.kind == "Reloaded" then
    local report = {
      phase = reload_state.PHASE.Finished, outcome = f.case, mechanism = f.mechanism or "",
      patched = 0, considered = 0, message = "", suggested_action = "", declarations = {}, kept = {},
      reasons = f.cause and { { case = f.cause.case or "", message = f.cause.message or "", suggested_action = "" } } or {},
      counts_unknown = true,
    }
    local d = reload_state.display(report)
    local text = f.file .. " " .. d.text
    if d.mechanism_text then text = text .. " (" .. d.mechanism_text .. ")" end
    return text, d.severity, d.hl
  end
  return f.text or "?", "warn", "SageFsReloadWarn"
end

local SEVERITY_HL = {
  quiet = "SageFsReloadQuiet", ok = "SageFsReloadOk", info = "SageFsReloadPending",
  warn = "SageFsReloadWarn", error = "SageFsReloadError",
}

local function describe_delivery(d)
  local prefix = "session " .. d.session .. ": "
  if d.kind == "NoApp" then
    return prefix .. "no running app to update" .. (d.detail and (" (" .. d.detail .. ")") or ""), "warn"
  elseif d.kind == "NoFiles" then
    return prefix .. "the landing changed no file the app runs", "quiet"
  elseif d.kind == "NoPipeline" then
    return prefix .. "no hot reload pipeline: " .. d.reason, "warn"
  elseif d.kind == "Unreachable" then
    return prefix .. "did not answer: " .. d.reason, "warn"
  elseif d.kind == "Unavailable" then
    return prefix .. "not available: " .. d.reason, "warn"
  elseif d.kind == "Delivered" then
    local texts, worst = {}, "quiet"
    for _, f in ipairs(d.files) do
      local text, severity = describe_file(f)
      table.insert(texts, text)
      if SEVERITY_RANK[severity] > SEVERITY_RANK[worst] then worst = severity end
    end
    return prefix .. table.concat(texts, "; "), worst
  end
  return d.text or "?", "warn"
end

--- The words and highlight for one trunk verdict.
---@param verdict table
---@return string text, string hl
function M.describe_verdict(verdict)
  local k = verdict.kind
  if k == "NoTrunkSession" then
    return "no session works in the trunk checkout", "SageFsReloadQuiet"
  elseif k == "NotMoved" then
    return "the trunk checkout did not move: " .. verdict.reason, "SageFsReloadError"
  elseif k == "Following" then
    return "following (" .. verdict.detail .. ")", "SageFsReloadPending"
  elseif k == "Queued" then
    return "queued behind the landing in flight", "SageFsReloadQuiet"
  elseif k == "Followed" then
    local texts, worst = {}, "quiet"
    for _, d in ipairs(verdict.deliveries) do
      local text, severity = describe_delivery(d)
      table.insert(texts, text)
      if SEVERITY_RANK[severity] > SEVERITY_RANK[worst] then worst = severity end
    end
    return table.concat(texts, "; "), SEVERITY_HL[worst]
  end
  return verdict.text or "?", "SageFsReloadWarn"
end

local function integration_text(s)
  if s.kind == "NotConfigured" then return "no integration configured (set_integration_ref)" end
  if s.kind == "Started" then return string.format("%s (started)", s.id) end
  if s.kind == "Failed" then return "FAILED to start " .. EM_DASH .. " " .. s.reason end
  if s.kind == "Pending" then return "pending" end
  return s.text or "unknown"
end

--- Lay a parsed status out as buffer lines with highlight groups.
---@param model table|nil
---@return { lines: { text: string, hl: string|nil }[] }
function M.render(model)
  if not model then
    return { lines = { { text = "no cohort status yet", hl = "SageFsReloadQuiet" } } }
  end
  local lines = {}
  local function add(text, hl) table.insert(lines, { text = text, hl = hl }) end

  add(string.format("Cohort (ledger v%d)", model.version), "Title")
  add("Conductor: " .. M.mask_member(model.conductor or "(none yet)"))
  add("")
  add(string.format("Members (%d)", model.members_total), "Title")
  for _, m in ipairs(model.members) do
    local seat = m.seat == "departed" and ("departed " .. (m.since or "")) or m.seat
    local tail = m.kind == "capability" and "  (minted run)" or ""
    add(string.format("  %s  %s  %s%s", M.mask_member(m.id), m.role, seat, tail), m.seat == "departed" and "SageFsReloadQuiet" or nil)
  end
  add("")
  add(string.format("Claims (%d)", model.claims_total), "Title")
  for _, c in ipairs(model.claims) do
    add(string.format("  %s  %s  held by %s  fence %d  %s", c.id, c.scope, M.mask_member(c.held_by), c.fence, c.state))
  end
  add("")
  if model.landings_total == 0 then
    add("Landings: none", "Title")
  else
    add(string.format("Landings (%d)", model.landings_total), "Title")
    for _, l in ipairs(model.landings) do
      add(string.format("  %s  %s  %s  %s  %s  [%s]",
        l.id, l.state, l.queue, M.mask_member(l.requester), l.statement, table.concat(l.commits, ",")))
    end
  end
  for _, o in ipairs(model.overflow) do add("  " .. o, "SageFsReloadQuiet") end
  add("")
  add("Integration head: " .. (model.integration_head or "?"))
  add("Integration session: " .. integration_text(model.integration_session))
  if model.trunk then
    add("")
    add(string.format("Trunk: checkout=%s (%s)", model.trunk.checkout, plural(model.trunk.count, "landing")), "Title")
    for _, entry in ipairs(model.trunk.landings) do
      local text, hl = M.describe_verdict(entry.verdict)
      add(string.format("  trunk %s: %s", entry.id, text), hl)
    end
  end
  return { lines = lines }
end

--- A short summary of a cohort_matrix SSE frame, for when the status text cannot
--- be fetched. Ids are shown like everywhere else.
---@param data table decoded cohort_matrix payload
---@return string[]
function M.matrix_summary(data)
  data = type(data) == "table" and data or {}
  local members = data.Members or data.members or {}
  local claims = data.Claims or data.claims or {}
  local landings = data.Landings or data.landings or {}
  local conductor
  for _, m in ipairs(members) do
    if m.Conductor or m.conductor then conductor = m.Id or m.id end
  end
  local lines = {
    string.format("Cohort v%s (from the event stream): %s, %s, %s",
      tostring(data.Version or data.version or "?"),
      plural(#members, "member"), plural(#claims, "claim"), plural(#landings, "landing")),
  }
  if conductor then table.insert(lines, "Conductor: " .. M.mask_member(conductor)) end
  return lines
end

return M
