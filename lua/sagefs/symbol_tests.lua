-- sagefs/symbol_tests.lua — Pure reading of the daemon's symbol-to-tests map
-- Zero vim dependencies.
--
-- GET /api/dependency-graph (SageFs/McpServer.fs, MapGet "/api/dependency-graph"; the reply is
-- built by SageFs/DependencyGraphRoute.fs from SageFs.Core/Features/SymbolTests.fs) answers which
-- tests cover a symbol, for ONE session. It keeps no call edges, so it cannot say who calls a
-- symbol or what a symbol calls; the old callers and callees commands asked routes
-- (/api/callers, /api/callees) that the daemon never mapped. The VS Code client reads the same
-- route (sagefs-vscode/src/SymbolTestsPure.fs, SageFsClient.fs getSymbolTests).
--
-- The route lives on the MCP port. It reads the session named by `?session=<id>`; with none it
-- takes the only session, and with several it refuses with AmbiguousSessions (HTTP 400, the
-- structured body of SageFsError.toJson under `errorDetails`). It used to read the primary
-- session's graph whoever asked, so a plugin bound to another session got an empty map. The
-- symbol query is matched exactly, so the overview is read first and the name is resolved here,
-- which lets a mistyped name be told apart from a symbol nothing covers.
--
--   no query:       { Session, State, Symbols = [{ Symbol, TestCount }], TotalSymbols }
--   ?symbol=<name>: { Session, State, Symbol, Tests = [{ TestId, TestName, Status }], TotalSymbols }
--   no Elm model:   503 { error = "Elm model not available" }
--
-- `State` says why the map is the size it is: nothing_analysed, no_coverage_recorded,
-- coverage_of_another_build, nothing_reached or mapped. A daemon from before the route took a
-- session sends neither `Session` nor `State`, and those replies read as they always did.
local util = require("sagefs.util")

local M = {}

M.PATH = "/api/dependency-graph"

--- How many near names are listed when a query matches no symbol exactly.
M.MAX_NEAR = 15

local function percent_encode(s)
  return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

--- The request path for the overview (no symbol) or one symbol's tests, for the bound session.
--- With no session the daemon infers the only one, or refuses when there are several.
---@param symbol string|nil
---@param session_id string|nil
---@return string
function M.path(symbol, session_id)
  local query = {}
  if type(symbol) == "string" and symbol ~= "" then
    query[#query + 1] = "symbol=" .. percent_encode(symbol)
  end
  if type(session_id) == "string" and session_id ~= "" then
    query[#query + 1] = "session=" .. percent_encode(session_id)
  end
  if #query == 0 then return M.PATH end
  return M.PATH .. "?" .. table.concat(query, "&")
end

local function excerpt(raw)
  local text = tostring(raw):gsub("%s+", " ")
  if #text > 80 then text = text:sub(1, 80) .. "…" end
  return text
end

--- The sentence for an AmbiguousSessions refusal: more than one session exists and the request
--- named none. The daemon's own text says "Specify sessionId", which a person typing a command
--- cannot do; the way out here is to bind the plugin to a session.
---@param details table the refusal's `errorDetails`
---@return string
local function describe_ambiguity(details)
  local lines = {
    "SageFs has more than one session running and this window is bound to none. "
      .. "Pick one with :SageFsSessions, then run :SageFsSymbolTests again.",
  }
  local listed = type(details.fields) == "table" and details.fields.sessionDescriptions
  if type(listed) == "table" and #listed > 0 then
    lines[#lines + 1] = "Sessions:"
    for _, description in ipairs(listed) do lines[#lines + 1] = "  " .. tostring(description) end
  end
  return table.concat(lines, "\n")
end

--- Turn a transport reply into the decoded JSON object, or a message that says what went wrong.
--- No `meta` means no response arrived at all (connect refused, timeout); a status means the
--- daemon answered. The third result is "ambiguous" when the daemon refused because several
--- sessions exist and none was named: that is something to do, not a fault.
---@param ok boolean
---@param raw string|nil
---@param meta table|nil { status = integer }
---@param url string the url asked, for the message
---@return table|nil parsed, string|nil message, string|nil refusal
function M.read_reply(ok, raw, meta, url)
  if not meta then
    return nil, "Could not reach the SageFs daemon at " .. url .. ": " .. tostring(raw or "no answer")
  end
  if not ok then
    local decoded, parsed = util.json_decode(raw)
    local details = decoded and type(parsed) == "table" and parsed.errorDetails or nil
    if type(details) == "table" and details.case == "AmbiguousSessions" then
      return nil, describe_ambiguity(details), "ambiguous"
    end
    -- An unmapped route answers 404 with no body at all; "Unknown error" would hide that.
    local why = (raw == nil or raw == "") and "no message in the reply"
      or util.format_server_error(decoded and parsed or nil, raw)
    return nil, "The daemon answered " .. tostring(meta.status) .. " for " .. M.PATH .. ": " .. why
  end
  if not raw or raw == "" then
    return nil, "The daemon's reply to " .. M.PATH .. " was empty"
  end
  local decoded, parsed = util.json_decode(raw)
  if not decoded then
    return nil, "The daemon's reply to " .. M.PATH .. " was not JSON: " .. excerpt(raw)
  end
  if type(parsed) ~= "table" or (parsed[1] ~= nil) then
    return nil, "The daemon's reply to " .. M.PATH .. " was not a JSON object: " .. excerpt(raw)
  end
  return parsed, nil
end

--- The tracked symbols of an overview reply.
---@param parsed table
---@return table|nil overview { total, session?, state?, symbols = [{ name, test_count }] }, string|nil message
function M.read_overview(parsed)
  if type(parsed.Symbols) ~= "table" then
    return nil, "The daemon's reply had no Symbols list: is this a SageFs daemon with " .. M.PATH .. "?"
  end
  local symbols = {}
  for _, entry in ipairs(parsed.Symbols) do
    if type(entry) == "table" and type(entry.Symbol) == "string" then
      symbols[#symbols + 1] = { name = entry.Symbol, test_count = entry.TestCount or 0 }
    end
  end
  return {
    total = parsed.TotalSymbols or #symbols,
    session = type(parsed.Session) == "string" and parsed.Session or nil,
    state = M.read_state(parsed),
    symbols = symbols,
  }, nil
end

--- The words `State` can carry (SymbolTestsState.toWire in SageFs.Core/Features/SymbolTests.fs).
local STATES = {
  nothing_analysed = true,
  no_coverage_recorded = true,
  coverage_of_another_build = true,
  nothing_reached = true,
  mapped = true,
}

--- The state a reply names, or nil when it names none or a word this plugin does not know. A
--- daemon from before the route took a session sends no `State`; nil is "not stated", and no
--- caller may read it as a claim about the map.
---@param parsed table
---@return string|nil
function M.read_state(parsed)
  local word = parsed.State
  if type(word) == "string" and STATES[word] then return word end
  return nil
end

--- What an empty map means, in plain words. The same map was once reported as "no graph yet" for
--- every cause, which is wrong for the ones a wait will not fix.
---@param state string|nil from read_state
---@return string
function M.describe_empty(state)
  if state == "nothing_analysed" then
    return "No test file has been analysed in this session yet. Edit or save a file with live testing on "
      .. "(:SageFsEnableTesting turns it on), then ask again."
  end
  if state == "no_coverage_recorded" then
    return "Files are analysed, but no test has recorded coverage yet. Run the tests (:SageFsRunTests), "
      .. "then ask again."
  end
  if state == "coverage_of_another_build" then
    return "Coverage was recorded against another build than the one this session holds. "
      .. "Run the tests against the built assembly, then ask again."
  end
  if state == "nothing_reached" then
    return "Coverage is recorded, and no test reaches an analysed symbol. After an evaluated run the test "
      .. "file's own lines are not instrumented, so editing only a test file can read this way until the "
      .. "next compiled run."
  end
  if state == "mapped" then
    return "The daemon reports the map as built, yet it lists no symbols for this session."
  end
  -- A daemon from before the route took a session says nothing about why.
  return "The daemon has no test dependency graph yet: it fills as live testing analyzes test files. "
    .. ":SageFsEnableTesting turns live testing on."
end

--- Find the query among the tracked symbols: an exact name, else the names that contain it
--- (ignoring case), else nothing. A near match is offered, never picked, because a mistyped
--- name that silently turned into another symbol would show the wrong tests.
---@param overview table
---@param query string
---@return table { kind = "exact"|"near"|"absent"|"empty", name?, names?, more? }
function M.resolve(overview, query)
  if #overview.symbols == 0 then return { kind = "empty", state = overview.state } end
  local needle = query:lower()
  local near = {}
  for _, sym in ipairs(overview.symbols) do
    if sym.name == query then return { kind = "exact", name = sym.name } end
    if sym.name:lower():find(needle, 1, true) then near[#near + 1] = sym.name end
  end
  if #near == 0 then return { kind = "absent" } end
  table.sort(near)
  local shown = {}
  for i = 1, math.min(#near, M.MAX_NEAR) do shown[i] = near[i] end
  return { kind = "near", names = shown, more = #near - #shown }
end

--- The sentence for a query that did not resolve to one symbol.
---@param resolution table from resolve
---@param query string
---@param total integer how many symbols the daemon tracks
---@return string
function M.describe_resolution(resolution, query, total)
  if resolution.kind == "empty" then return M.describe_empty(resolution.state) end
  if resolution.kind == "near" then
    local lines = { query .. " is not a tracked symbol name. Names containing it:" }
    for _, name in ipairs(resolution.names) do lines[#lines + 1] = "  " .. name end
    if resolution.more > 0 then lines[#lines + 1] = string.format("  … and %d more", resolution.more) end
    return table.concat(lines, "\n")
  end
  return string.format("%s is not in the graph (%d symbols tracked). Use the symbol's full name, for example Module.function.",
    query, total)
end

--- The tests of one symbol from a ?symbol= reply.
---@param parsed table
---@return table|nil detail { symbol, session?, tests = [{ id, name, status }] }, string|nil message
function M.read_detail(parsed)
  if type(parsed.Tests) ~= "table" then
    return nil, "The daemon's reply had no Tests list for the symbol"
  end
  local tests = {}
  for _, t in ipairs(parsed.Tests) do
    if type(t) == "table" then
      tests[#tests + 1] = {
        id = t.TestId or "",
        name = t.TestName or t.TestId or "?",
        status = t.Status or "unknown",
      }
    end
  end
  return {
    symbol = parsed.Symbol or "?",
    session = type(parsed.Session) == "string" and parsed.Session or nil,
    tests = tests,
  }, nil
end

local ICONS = { passed = "✓", failed = "✗" }

--- Float lines for one symbol's tests.
---@param detail table from read_detail
---@return string[]
function M.format_tests(detail)
  local lines = { "Tests referencing: " .. detail.symbol, string.rep("─", 40) }
  -- The answer belongs to one session; a daemon that does not say which leaves the line out.
  if detail.session then lines[#lines + 1] = "  session " .. detail.session end
  if #detail.tests == 0 then
    lines[#lines + 1] = "  The graph tracks this symbol but lists no tests for it."
  else
    local passed, failed = 0, 0
    for _, t in ipairs(detail.tests) do
      if t.status == "passed" then passed = passed + 1 elseif t.status == "failed" then failed = failed + 1 end
      lines[#lines + 1] = string.format("  %s %s  [%s]", ICONS[t.status] or "●", t.name, t.status)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("  %d %s: %d passed, %d failed",
      #detail.tests, #detail.tests == 1 and "test" or "tests", passed, failed)
  end
  lines[#lines + 1] = "  (the tests that reference this symbol, not callers: SageFs keeps no call edges)"
  return lines
end

return M
