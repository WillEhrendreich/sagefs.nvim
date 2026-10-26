-- sagefs/symbol_tests.lua — Pure reading of the daemon's symbol graph
-- Zero vim dependencies.
--
-- GET /api/dependency-graph (SageFs/McpServer.fs, MapGet near line 4313; contract listed in
-- SageFs.Core/EndpointContracts.fs near line 123) serializes the live testing model's
-- TestDependencyGraph.SymbolToTests: a symbol's full name to the tests that reference it. The
-- graph has no call edges, so it cannot say who calls a symbol or what a symbol calls. The old
-- callers and callees commands asked routes (/api/callers, /api/callees) that the daemon
-- never mapped. What the route does answer is "which tests cover this symbol", which is what the
-- VS Code client shows for the same route (sagefs-vscode/src/Extension.fs, sagefs.showCallGraph).
--
-- The route lives on the MCP port. It takes no session id: it reads the daemon's single Elm
-- model. The symbol query is matched exactly, so the overview is read first and the name is
-- resolved here, which lets a mistyped name be told apart from a symbol nothing covers.
--
--   no query:       { Symbols = [{ Symbol, TestCount }], TotalSymbols }
--   ?symbol=<name>: { Symbol, Tests = [{ TestId, TestName, Status }], TotalSymbols }
--   no Elm model:   503 { error = "Elm model not available" }
local util = require("sagefs.util")

local M = {}

M.PATH = "/api/dependency-graph"

--- How many near names are listed when a query matches no symbol exactly.
M.MAX_NEAR = 15

local function percent_encode(s)
  return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

--- The request path for the overview (no symbol) or one symbol's tests.
---@param symbol string|nil
---@return string
function M.path(symbol)
  if type(symbol) ~= "string" or symbol == "" then return M.PATH end
  return M.PATH .. "?symbol=" .. percent_encode(symbol)
end

local function excerpt(raw)
  local text = tostring(raw):gsub("%s+", " ")
  if #text > 80 then text = text:sub(1, 80) .. "…" end
  return text
end

--- Turn a transport reply into the decoded JSON object, or a message that says what went wrong.
--- No `meta` means no response arrived at all (connect refused, timeout); a status means the
--- daemon answered.
---@param ok boolean
---@param raw string|nil
---@param meta table|nil { status = integer }
---@param url string the url asked, for the message
---@return table|nil parsed, string|nil message
function M.read_reply(ok, raw, meta, url)
  if not meta then
    return nil, "Could not reach the SageFs daemon at " .. url .. ": " .. tostring(raw or "no answer")
  end
  if not ok then
    local decoded, parsed = util.json_decode(raw)
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
---@return table|nil overview { total, symbols = [{ name, test_count }] }, string|nil message
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
  return { total = parsed.TotalSymbols or #symbols, symbols = symbols }, nil
end

--- Find the query among the tracked symbols: an exact name, else the names that contain it
--- (ignoring case), else nothing. A near match is offered, never picked, because a mistyped
--- name that silently turned into another symbol would show the wrong tests.
---@param overview table
---@param query string
---@return table { kind = "exact"|"near"|"absent"|"empty", name?, names?, more? }
function M.resolve(overview, query)
  if #overview.symbols == 0 then return { kind = "empty" } end
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
  if resolution.kind == "empty" then
    return "The daemon has no test dependency graph yet: it fills as live testing analyzes test files. "
      .. ":SageFsEnableTesting turns live testing on."
  end
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
---@return table|nil detail { symbol, tests = [{ id, name, status }] }, string|nil message
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
  return { symbol = parsed.Symbol or "?", tests = tests }, nil
end

local ICONS = { passed = "✓", failed = "✗" }

--- Float lines for one symbol's tests.
---@param detail table from read_detail
---@return string[]
function M.format_tests(detail)
  local lines = { "Tests referencing: " .. detail.symbol, string.rep("─", 40) }
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
