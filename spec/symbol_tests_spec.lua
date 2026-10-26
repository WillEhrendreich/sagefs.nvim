-- Tests: sagefs.symbol_tests, the pure half of :SageFsSymbolTests.
--
-- GET /api/dependency-graph (SageFs/McpServer.fs, mapped near line 4313) answers from the live
-- testing model's TestDependencyGraph: symbol name to the tests that reference it. It has no
-- call edges, so "callers of X" and "callees of X" cannot be read from it, and what it can say
-- is "which tests cover X". Two shapes:
--   no query:        { Symbols = [{ Symbol, TestCount }], TotalSymbols }
--   ?symbol=<name>:  { Symbol, Tests = [{ TestId, TestName, Status }], TotalSymbols }
-- Status is "passed", "failed", "other" or "unknown". A 503 carries { error } when the daemon
-- has no Elm model yet.
local symbol_tests = require("sagefs.symbol_tests")

local URL = "http://localhost:37749/api/dependency-graph"

describe("symbol_tests.path", function()
  it("asks for the overview with no symbol", function()
    assert.equals("/api/dependency-graph", symbol_tests.path(nil))
    assert.equals("/api/dependency-graph", symbol_tests.path(""))
  end)

  it("percent-encodes the symbol so a generic or operator name survives the query", function()
    assert.equals("/api/dependency-graph?symbol=Mod.add", symbol_tests.path("Mod.add"))
    assert.equals("/api/dependency-graph?symbol=Mod.%28%7C%3E%29", symbol_tests.path("Mod.(|>)"))
    assert.equals("/api/dependency-graph?symbol=a%20b%2Bc", symbol_tests.path("a b+c"))
  end)
end)

describe("symbol_tests.read_reply", function()
  it("says the daemon could not be reached, with the url and the cause, when no response arrived", function()
    local parsed, msg = symbol_tests.read_reply(false, "connect: ECONNREFUSED", nil, URL)
    assert.is_nil(parsed)
    assert.is_truthy(msg:find("Could not reach the SageFs daemon", 1, true))
    assert.is_truthy(msg:find(URL, 1, true))
    assert.is_truthy(msg:find("ECONNREFUSED", 1, true))
  end)

  it("names a timeout as the cause", function()
    local _, msg = symbol_tests.read_reply(false, "timeout", nil, URL)
    assert.is_truthy(msg:find("timeout", 1, true))
  end)

  it("reports a non-200 with its status and the server's own words", function()
    local parsed, msg = symbol_tests.read_reply(false, '{"error":"Elm model not available"}', { status = 503 }, URL)
    assert.is_nil(parsed)
    assert.is_truthy(msg:find("503", 1, true))
    assert.is_truthy(msg:find("Elm model not available", 1, true))
  end)

  it("says so when the daemon answered a non-200 with no body, rather than 'Unknown error'", function()
    local _, msg = symbol_tests.read_reply(false, "", { status = 404 }, URL)
    assert.is_truthy(msg:find("404", 1, true))
    assert.is_truthy(msg:find("no message in the reply", 1, true))
    assert.is_nil(msg:find("Unknown error", 1, true))
  end)

  it("reports a 404 body that is not JSON by quoting it", function()
    local _, msg = symbol_tests.read_reply(false, "Not Found", { status = 404 }, URL)
    assert.is_truthy(msg:find("404", 1, true))
    assert.is_truthy(msg:find("Not Found", 1, true))
  end)

  it("reports a 200 whose body is not JSON, quoting its start", function()
    local parsed, msg = symbol_tests.read_reply(true, "<html>login</html>", { status = 200 }, URL)
    assert.is_nil(parsed)
    assert.is_truthy(msg:find("not JSON", 1, true))
    assert.is_truthy(msg:find("<html>login</html>", 1, true))
  end)

  it("reports a 200 with an empty body", function()
    local _, msg = symbol_tests.read_reply(true, "", { status = 200 }, URL)
    assert.is_truthy(msg:find("empty", 1, true))
  end)

  it("returns the decoded table for a good reply", function()
    local parsed = symbol_tests.read_reply(true, '{"Symbols":[],"TotalSymbols":0}', { status = 200 }, URL)
    assert.equals(0, parsed.TotalSymbols)
  end)

  it("rejects JSON that is not an object", function()
    local parsed, msg = symbol_tests.read_reply(true, "[1,2]", { status = 200 }, URL)
    assert.is_nil(parsed)
    assert.is_truthy(msg:find("not a JSON object", 1, true))
  end)
end)

describe("symbol_tests.read_overview", function()
  it("reads the tracked symbols and the total", function()
    local overview = symbol_tests.read_overview({
      Symbols = { { Symbol = "Mod.add", TestCount = 2 }, { Symbol = "Mod.sub", TestCount = 1 } },
      TotalSymbols = 2,
    })
    assert.equals(2, overview.total)
    assert.equals("Mod.add", overview.symbols[1].name)
    assert.equals(2, overview.symbols[1].test_count)
  end)

  it("says the reply lacked a Symbols list rather than showing an empty graph", function()
    local overview, msg = symbol_tests.read_overview({ foo = 1 })
    assert.is_nil(overview)
    assert.is_truthy(msg:find("Symbols", 1, true))
  end)
end)

describe("symbol_tests.resolve", function()
  local overview = {
    total = 4,
    symbols = {
      { name = "Mod.add", test_count = 2 },
      { name = "Mod.addAll", test_count = 1 },
      { name = "Other.Add", test_count = 1 },
      { name = "Mod.sub", test_count = 1 },
    },
  }

  it("finds an exact name", function()
    local r = symbol_tests.resolve(overview, "Mod.add")
    assert.equals("exact", r.kind)
    assert.equals("Mod.add", r.name)
  end)

  it("offers the names that contain the query, ignoring case, when nothing matches exactly", function()
    local r = symbol_tests.resolve(overview, "add")
    assert.equals("near", r.kind)
    assert.same({ "Mod.add", "Mod.addAll", "Other.Add" }, r.names)
  end)

  it("says the symbol is not in the graph when nothing resembles it", function()
    local r = symbol_tests.resolve(overview, "zzz")
    assert.equals("absent", r.kind)
  end)

  it("says the graph is empty when it has no symbols at all", function()
    local r = symbol_tests.resolve({ total = 0, symbols = {} }, "anything")
    assert.equals("empty", r.kind)
  end)

  it("caps the near list and says how many were left out", function()
    local many = { total = 30, symbols = {} }
    for i = 1, 30 do many.symbols[i] = { name = "N.f" .. i, test_count = 1 } end
    local r = symbol_tests.resolve(many, "f")
    assert.equals("near", r.kind)
    assert.equals(symbol_tests.MAX_NEAR, #r.names)
    assert.equals(30 - symbol_tests.MAX_NEAR, r.more)
  end)
end)

describe("symbol_tests.describe_resolution", function()
  it("tells an empty graph apart from a missing symbol", function()
    local empty = symbol_tests.describe_resolution({ kind = "empty" }, "X", 0)
    assert.is_truthy(empty:find("no test dependency graph", 1, true))
    local absent = symbol_tests.describe_resolution({ kind = "absent" }, "X", 12)
    assert.is_truthy(absent:find("X", 1, true))
    assert.is_truthy(absent:find("not in the graph", 1, true))
    assert.is_truthy(absent:find("12", 1, true))
  end)

  it("never presents a missing symbol as a symbol nothing covers", function()
    local absent = symbol_tests.describe_resolution({ kind = "absent" }, "X", 12)
    assert.is_nil(absent:find("no tests", 1, true))
  end)

  it("lists the near names", function()
    local near = symbol_tests.describe_resolution({ kind = "near", names = { "Mod.add", "Mod.addAll" }, more = 0 }, "add", 5)
    assert.is_truthy(near:find("Mod.add", 1, true))
    assert.is_truthy(near:find("Mod.addAll", 1, true))
  end)
end)

describe("symbol_tests.read_detail and format_tests", function()
  it("reads the tests of a symbol", function()
    local detail = symbol_tests.read_detail({
      Symbol = "Mod.add",
      Tests = {
        { TestId = "t1", TestName = "adds two", Status = "passed" },
        { TestId = "t2", TestName = "adds negatives", Status = "failed" },
      },
      TotalSymbols = 4,
    })
    assert.equals("Mod.add", detail.symbol)
    assert.equals(2, #detail.tests)
    assert.equals("adds negatives", detail.tests[2].name)
    assert.equals("failed", detail.tests[2].status)
  end)

  it("says the reply lacked a Tests list", function()
    local detail, msg = symbol_tests.read_detail({ Symbol = "x" })
    assert.is_nil(detail)
    assert.is_truthy(msg:find("Tests", 1, true))
  end)

  it("shows each test with its status and a tally", function()
    local lines = symbol_tests.format_tests({
      symbol = "Mod.add",
      tests = {
        { id = "t1", name = "adds two", status = "passed" },
        { id = "t2", name = "adds negatives", status = "failed" },
        { id = "t3", name = "adds floats", status = "unknown" },
      },
    })
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("Mod.add", 1, true))
    assert.is_truthy(text:find("3 tests", 1, true))
    assert.is_truthy(text:find("1 passed", 1, true))
    assert.is_truthy(text:find("1 failed", 1, true))
    assert.is_truthy(text:find("adds negatives", 1, true))
    assert.is_truthy(text:find("[failed]", 1, true))
  end)

  it("says a tracked symbol has no tests instead of printing a bare header", function()
    local lines = symbol_tests.format_tests({ symbol = "Mod.add", tests = {} })
    assert.is_truthy(table.concat(lines, "\n"):find("no tests", 1, true))
  end)

  it("says these are covering tests, so nobody reads them as callers", function()
    local lines = symbol_tests.format_tests({ symbol = "Mod.add", tests = { { id = "t", name = "n", status = "passed" } } })
    assert.is_truthy(table.concat(lines, "\n"):find("not callers", 1, true))
  end)
end)

-- The route answers about ONE session (SageFs/McpServer.fs, MapGet "/api/dependency-graph"; the
-- reply is built by SageFs/DependencyGraphRoute.fs). It used to read the primary session's graph,
-- so a plugin bound to another session got an empty map. Now it takes ?session=<id>, and its
-- reply carries `Session` and `State`, the reason an empty map is empty.
describe("symbol_tests.path with a session", function()
  it("sends the bound session on the overview request", function()
    assert.equals("/api/dependency-graph?session=abc12345", symbol_tests.path(nil, "abc12345"))
    assert.equals("/api/dependency-graph?session=abc12345", symbol_tests.path("", "abc12345"))
  end)

  it("sends the symbol and then the session on the detail request", function()
    assert.equals("/api/dependency-graph?symbol=Mod.add&session=abc12345", symbol_tests.path("Mod.add", "abc12345"))
  end)

  it("percent-encodes the session id too", function()
    assert.equals("/api/dependency-graph?session=a%20b", symbol_tests.path(nil, "a b"))
  end)

  it("names no session when the plugin is bound to none, so the daemon can infer the only one", function()
    assert.equals("/api/dependency-graph", symbol_tests.path(nil, nil))
    assert.equals("/api/dependency-graph?symbol=Mod.add", symbol_tests.path("Mod.add", ""))
  end)
end)

describe("symbol_tests.read_reply: the ambiguity refusal", function()
  local REFUSAL = vim.json.encode({
    success = false,
    error = "Multiple sessions active. Specify sessionId:\ns1 (/work/a)\ns2 (/work/b)",
    errorDetails = {
      case = "AmbiguousSessions",
      fields = { sessionDescriptions = { "s1 (/work/a)", "s2 (/work/b)" } },
      message = "Multiple sessions active. Specify sessionId:\ns1 (/work/a)\ns2 (/work/b)",
      suggestedAction = "Specify a sessionId explicitly",
    },
  })

  it("says what to do: pick a session in the plugin, then ask again", function()
    local parsed, msg = symbol_tests.read_reply(false, REFUSAL, { status = 400 }, URL)
    assert.is_nil(parsed)
    assert.is_truthy(msg:find(":SageFsSessions", 1, true))
    assert.is_truthy(msg:find("more than one", 1, true))
  end)

  it("lists the sessions the daemon named", function()
    local _, msg = symbol_tests.read_reply(false, REFUSAL, { status = 400 }, URL)
    assert.is_truthy(msg:find("s1 (/work/a)", 1, true))
    assert.is_truthy(msg:find("s2 (/work/b)", 1, true))
  end)

  it("does not mistake another 400 for the ambiguity", function()
    local _, msg = symbol_tests.read_reply(false, '{"error":"bad"}', { status = 400 }, URL)
    assert.is_nil(msg:find(":SageFsSessions", 1, true))
    assert.is_truthy(msg:find("400", 1, true))
  end)

  it("still says so when the refusal names no sessions", function()
    local bare = vim.json.encode({ errorDetails = { case = "AmbiguousSessions", fields = {} } })
    local _, msg = symbol_tests.read_reply(false, bare, { status = 400 }, URL)
    assert.is_truthy(msg:find(":SageFsSessions", 1, true))
  end)
end)

describe("symbol_tests.read_overview: State", function()
  it("reads the session and the state the daemon states", function()
    local overview = symbol_tests.read_overview({
      Session = "abc12345", State = "mapped", Symbols = {}, TotalSymbols = 0,
    })
    assert.equals("abc12345", overview.session)
    assert.equals("mapped", overview.state)
  end)

  it("leaves state nil for a daemon that sends none, which is not a claim about the map", function()
    local overview = symbol_tests.read_overview({ Symbols = {}, TotalSymbols = 0 })
    assert.is_nil(overview.state)
    assert.is_nil(overview.session)
  end)

  it("leaves state nil for a word this plugin does not know", function()
    local overview = symbol_tests.read_overview({ State = "from_the_future", Symbols = {}, TotalSymbols = 0 })
    assert.is_nil(overview.state)
  end)
end)

describe("symbol_tests.describe_empty", function()
  local states = { "nothing_analysed", "no_coverage_recorded", "coverage_of_another_build", "nothing_reached" }

  it("gives each state its own message", function()
    local seen = {}
    for _, state in ipairs(states) do
      local msg = symbol_tests.describe_empty(state)
      assert.is_string(msg)
      assert.is_nil(seen[msg], state .. " repeats another state's message")
      seen[msg] = true
    end
  end)

  it("says nothing was analysed and points at live testing", function()
    local msg = symbol_tests.describe_empty("nothing_analysed")
    assert.is_truthy(msg:find("analysed", 1, true))
    assert.is_truthy(msg:find(":SageFsEnableTesting", 1, true))
  end)

  it("says no coverage was recorded and to run the tests", function()
    local msg = symbol_tests.describe_empty("no_coverage_recorded")
    assert.is_truthy(msg:find("coverage", 1, true))
    assert.is_truthy(msg:find(":SageFsRunTests", 1, true))
  end)

  it("says the coverage belongs to another build and to run against the built assembly", function()
    local msg = symbol_tests.describe_empty("coverage_of_another_build")
    assert.is_truthy(msg:find("another build", 1, true))
    assert.is_truthy(msg:find("built assembly", 1, true))
  end)

  it("says nothing was reached, and that a test-file edit alone can read this way until a compiled run", function()
    local msg = symbol_tests.describe_empty("nothing_reached")
    assert.is_truthy(msg:find("no test reaches", 1, true))
    assert.is_truthy(msg:find("compiled run", 1, true))
  end)

  it("never presents an empty map as a missing graph", function()
    for _, state in ipairs(states) do
      assert.is_nil(symbol_tests.describe_empty(state):find("no test dependency graph", 1, true))
    end
  end)

  it("keeps the old sentence for a daemon that states no state", function()
    local msg = symbol_tests.describe_empty(nil)
    assert.is_truthy(msg:find("no test dependency graph", 1, true))
  end)

  it("says the map is mapped yet empty without inventing a cause", function()
    local msg = symbol_tests.describe_empty("mapped")
    assert.is_truthy(msg:find("lists no symbols", 1, true))
  end)
end)

describe("symbol_tests.resolve and describe_resolution with a state", function()
  it("carries the state on an empty map", function()
    local r = symbol_tests.resolve({ total = 0, symbols = {}, state = "nothing_reached" }, "x")
    assert.equals("empty", r.kind)
    assert.equals("nothing_reached", r.state)
  end)

  it("describes an empty map by its state", function()
    local msg = symbol_tests.describe_resolution({ kind = "empty", state = "no_coverage_recorded" }, "X", 0)
    assert.is_truthy(msg:find("no test has recorded coverage", 1, true))
  end)
end)

describe("symbol_tests.format_tests: the session", function()
  it("names the session a detail reply came from when the daemon says which", function()
    local detail = symbol_tests.read_detail({ Session = "abc12345", Symbol = "Mod.add", Tests = {}, TotalSymbols = 1 })
    assert.equals("abc12345", detail.session)
    assert.is_truthy(table.concat(symbol_tests.format_tests(detail), "\n"):find("abc12345", 1, true))
  end)

  it("prints nothing about a session when an older daemon sends none", function()
    local detail = symbol_tests.read_detail({ Symbol = "Mod.add", Tests = {}, TotalSymbols = 1 })
    assert.is_nil(detail.session)
    assert.is_nil(table.concat(symbol_tests.format_tests(detail), "\n"):find("session", 1, true))
  end)
end)
