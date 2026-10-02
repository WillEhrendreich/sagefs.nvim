-- Tests: per-test coverage in sagefs.coverage.
--
-- The daemon records coverage per test and reports it two ways:
--   * file_annotations: every CoverageAnnotation line carries CoveringTests
--     ({TestId, DisplayName}, in discovery order), the tests whose own recorded
--     coverage reaches that line;
--   * coverage_view: one event per symbol with Generation, Symbol, FilePath,
--     DefinitionLine, TotalCount, Overflow, InlineBadgeText and Health, merged
--     per (file, generation): a newer generation replaces the file's views, the
--     same generation appends, an older one is a dropped straggler, and an
--     absent generation is 0, which never sweeps.
--
-- The coverage_view fixture is a real replay from the dev daemon (all Absent,
-- the covering lists in the real file_annotations were all empty there). The
-- fixture with non-empty CoveringTests is derived from the real one by filling
-- the documented CoveringTestRef shape for a few lines.
--
-- The old per-batch bitmap path (coverage_updated: files/lines/hits) must keep
-- working; coverage_spec.lua covers it and a few cases here pin that it did not
-- move.
require("spec.helper")

local coverage = require("sagefs.coverage")
local testing = require("sagefs.testing")
local util = require("sagefs.util")

local function fixture(name)
  local src = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
  local f = assert(io.open(src .. "fixtures/wire/" .. name, "rb"))
  local text = f:read("*a")
  f:close()
  local ok, data = util.json_decode(text)
  assert(ok, "fixture " .. name .. " did not decode")
  return data
end

local FILE = "/tmp/lem/tour-live-testing-passing-04/w/DemoEnv.Tests/DemoEnvTests.fs"

local function view(overrides)
  local v = {
    SessionId = "s1", Generation = 4, Symbol = "Mod.add", FilePath = "/p/Prod.fs", DefinitionLine = 10,
    TotalCount = 3, Overflow = { Case = "Within" }, InlineBadgeText = "✓ 3", Health = { Case = "Passing" },
  }
  for k, val in pairs(overrides or {}) do v[k] = val end
  return v
end

local function symbols(state, file)
  local out = {}
  for _, v in ipairs(coverage.views_for_file(state, file)) do table.insert(out, v.symbol) end
  return out
end

-- ─── coverage_view: the per-(file, generation) merge ─────────────────────────

describe("coverage.apply_coverage_view", function()
  it("reads the real replay: 20 views of generation 4 across two files, all absent", function()
    local state = coverage.new()
    for _, payload in ipairs(fixture("coverage_view_replay.json")) do
      state = coverage.apply_coverage_view(state, payload)
    end
    local views = coverage.views_for_file(state, FILE)
    assert.are.equal(20, #views)
    assert.are.equal(4, coverage.generation_for_file(state, FILE))
    assert.are.equal("Absent", views[1].health)
    assert.are.equal(0, views[1].total)
    assert.is_nil(coverage.format_badge(views[1]), "an absent view draws nothing")
  end)

  it("returns the views of a file ordered by definition line", function()
    local state = coverage.new()
    state = coverage.apply_coverage_view(state, view({ Symbol = "b", DefinitionLine = 30 }))
    state = coverage.apply_coverage_view(state, view({ Symbol = "a", DefinitionLine = 10 }))
    assert.are.same({ "a", "b" }, symbols(state, "/p/Prod.fs"))
  end)

  it("same generation appends one view per symbol", function()
    local state = coverage.new()
    state = coverage.apply_coverage_view(state, view({ Symbol = "a", Generation = 7 }))
    state = coverage.apply_coverage_view(state, view({ Symbol = "b", Generation = 7, DefinitionLine = 20 }))
    state = coverage.apply_coverage_view(state, view({ Symbol = "c", Generation = 7, DefinitionLine = 30 }))
    assert.are.same({ "a", "b", "c" }, symbols(state, "/p/Prod.fs"))
  end)

  it("a symbol sent again in the same generation replaces its view instead of doubling it", function()
    local state = coverage.new()
    state = coverage.apply_coverage_view(state, view({ Symbol = "a", Generation = 7, TotalCount = 1, InlineBadgeText = "✓ 1" }))
    state = coverage.apply_coverage_view(state, view({ Symbol = "a", Generation = 7, TotalCount = 2, InlineBadgeText = "✓ 2" }))
    local views = coverage.views_for_file(state, "/p/Prod.fs")
    assert.are.equal(1, #views)
    assert.are.equal(2, views[1].total)
  end)

  it("a newer generation replaces the file's whole set (symbols it no longer names are gone)", function()
    local state = coverage.new()
    state = coverage.apply_coverage_view(state, view({ Symbol = "old1", Generation = 7 }))
    state = coverage.apply_coverage_view(state, view({ Symbol = "old2", Generation = 7, DefinitionLine = 20 }))
    state = coverage.apply_coverage_view(state, view({ Symbol = "new1", Generation = 8 }))
    assert.are.same({ "new1" }, symbols(state, "/p/Prod.fs"))
    assert.are.equal(8, coverage.generation_for_file(state, "/p/Prod.fs"))
  end)

  it("an older generation is a dropped straggler", function()
    local state = coverage.new()
    state = coverage.apply_coverage_view(state, view({ Symbol = "now", Generation = 8 }))
    local v = state._version
    state = coverage.apply_coverage_view(state, view({ Symbol = "late", Generation = 7 }))
    assert.are.same({ "now" }, symbols(state, "/p/Prod.fs"))
    assert.are.equal(v, state._version, "a dropped straggler changes nothing")
  end)

  it("an absent generation is 0 and never sweeps", function()
    local state = coverage.new()
    local no_generation = view({ Symbol = "x" })
    no_generation.Generation = nil
    state = coverage.apply_coverage_view(state, view({ Symbol = "keep", Generation = 5 }))
    state = coverage.apply_coverage_view(state, no_generation)
    assert.are.same({ "keep" }, symbols(state, "/p/Prod.fs"), "0 is older than 5: dropped, and it did not sweep")
  end)

  it("without generations at all (an older daemon) views accumulate per symbol and never sweep", function()
    local state = coverage.new()
    local function bare(symbol, line)
      local v = view({ Symbol = symbol, DefinitionLine = line })
      v.Generation = nil
      return v
    end
    state = coverage.apply_coverage_view(state, bare("a", 10))
    state = coverage.apply_coverage_view(state, bare("b", 20))
    state = coverage.apply_coverage_view(state, bare("a", 10))
    assert.are.same({ "a", "b" }, symbols(state, "/p/Prod.fs"))
    assert.are.equal(0, coverage.generation_for_file(state, "/p/Prod.fs"))
  end)

  it("a generation after generation 0 sweeps the 0 views away", function()
    local state = coverage.new()
    local bare = view({ Symbol = "bare" })
    bare.Generation = nil
    state = coverage.apply_coverage_view(state, bare)
    state = coverage.apply_coverage_view(state, view({ Symbol = "real", Generation = 3 }))
    assert.are.same({ "real" }, symbols(state, "/p/Prod.fs"))
  end)

  it("keeps files apart: one file's generation does not sweep another", function()
    local state = coverage.new()
    state = coverage.apply_coverage_view(state, view({ Symbol = "a", FilePath = "/p/A.fs", Generation = 9 }))
    state = coverage.apply_coverage_view(state, view({ Symbol = "b", FilePath = "/p/B.fs", Generation = 2 }))
    assert.are.same({ "a" }, symbols(state, "/p/A.fs"))
    assert.are.same({ "b" }, symbols(state, "/p/B.fs"))
  end)

  it("finds a file by a buffer path that differs only by separators or a prefix", function()
    local state = coverage.apply_coverage_view(coverage.new(), view({ FilePath = "C:\\w\\Prod.fs" }))
    assert.are.equal(1, #coverage.views_for_file(state, "C:/w/Prod.fs"))
  end)

  it("bumps the version when something changed", function()
    local state = coverage.new()
    local v0 = state._version
    state = coverage.apply_coverage_view(state, view())
    assert.is_true(state._version > v0)
  end)

  it("ignores a payload with no file path", function()
    local state = coverage.new()
    local v0 = state._version
    local broken = view()
    broken.FilePath = nil
    assert.are.equal(v0, coverage.apply_coverage_view(state, broken)._version)
    assert.are.equal(v0, coverage.apply_coverage_view(state, nil)._version)
  end)

  it("clear() forgets the views too", function()
    local state = coverage.apply_coverage_view(coverage.new(), view())
    state = coverage.clear(state)
    assert.are.same({}, coverage.views_for_file(state, "/p/Prod.fs"))
  end)

  it("works on a state built before views existed", function()
    local old = { files = {}, enabled = false, _version = 3 }
    old = coverage.apply_coverage_view(old, view())
    assert.are.equal(1, #coverage.views_for_file(old, "/p/Prod.fs"))
  end)
end)

describe("coverage.format_badge", function()
  it("is the daemon's one-line text with its health", function()
    local state = coverage.apply_coverage_view(coverage.new(), view({ InlineBadgeText = "✓ 97 ✗ 3", TotalCount = 100, Health = { Case = "Failing" } }))
    local text, health = coverage.format_badge(coverage.views_for_file(state, "/p/Prod.fs")[1])
    assert.are.equal("✓ 97 ✗ 3", text)
    assert.are.equal("Failing", health)
  end)

  it("names the hidden count when the daemon says some did not fit", function()
    local state = coverage.apply_coverage_view(coverage.new(), view({ InlineBadgeText = "✓ 97", TotalCount = 100,
      Overflow = { Case = "Overflow", Fields = { 3 } } }))
    local text = coverage.format_badge(coverage.views_for_file(state, "/p/Prod.fs")[1])
    assert.are.equal("✓ 97 +3 more", text)
  end)

  it("is nil for a view with no covering tests", function()
    local state = coverage.apply_coverage_view(coverage.new(), view({ TotalCount = 0, InlineBadgeText = "", Health = { Case = "Absent" } }))
    assert.is_nil(coverage.format_badge(coverage.views_for_file(state, "/p/Prod.fs")[1]))
  end)
end)

-- ─── Per-line covering tests ─────────────────────────────────────────────────

describe("coverage.covering_info", function()
  local ann = fixture("file_annotations_covering_synthetic.json")

  local function tests_state()
    local state = testing.new()
    local function add(id, name, status)
      testing.update_test(state, { testId = id, displayName = name, fullName = name, status = status,
        origin = { Case = "SourceMapped", Fields = { FILE, 8 } } })
    end
    add("47DE23FB95057848", "garbage yields None", "Passed")
    add("7638D0E81B145CA1", "unset (None) yields None", "Failed")
    add("D39C4D7B318839A9", "a negative integer yields None", "Failed")
    return state
  end

  it("lists the tests whose own coverage reaches the line, in the daemon's order, with their last result", function()
    local info = coverage.covering_info(ann, 11, tests_state())
    assert.are.equal(11, info.line)
    assert.are.equal(2, #info.tests)
    assert.are.equal("garbage yields None", info.tests[1].name)
    assert.are.equal("Passed", info.tests[1].status)
    assert.are.equal("unset (None) yields None", info.tests[2].name)
    assert.are.equal("Failed", info.tests[2].status)
    assert.are.equal("47DE23FB95057848", info.tests[1].test_id)
    assert.are.equal("Covered", info.status)
  end)

  it("a test the plugin has no result for says so instead of guessing", function()
    local info = coverage.covering_info(ann, 36, tests_state())
    assert.are.equal("ABAAEE6BDF27575A", info.tests[1].test_id)
    assert.is_nil(info.tests[1].status)
  end)

  it("a multi-line annotation covers every line it spans, the innermost one winning", function()
    local info = coverage.covering_info(ann, 37, tests_state())
    assert.are.equal(36, info.span.from)
    assert.are.equal(38, info.span.to)
    assert.are.equal(1, #info.tests)
  end)

  it("a line inside an annotation that has no covering tests says no test covers it", function()
    local info = coverage.covering_info(ann, 9, tests_state())
    assert.are.equal(0, #info.tests)
    assert.are.equal("NotCovered", info.status)
  end)

  it("the daemon's real payload (every covering list empty) gives the same honest answer", function()
    local real = fixture("file_annotations_demoenv_tests.json")
    local info = coverage.covering_info(real, 11, tests_state())
    assert.are.equal(0, #info.tests)
    assert.are.equal("Covered", info.status)
    assert.are.equal("AllPassing", info.health)
  end)

  it("is nil for a line no annotation reaches", function()
    assert.is_nil(coverage.covering_info(ann, 400, tests_state()))
  end)

  it("is nil when there are no annotations at all", function()
    assert.is_nil(coverage.covering_info(nil, 11, tests_state()))
    assert.is_nil(coverage.covering_info({ CoverageAnnotations = {} }, 11, tests_state()))
  end)

  it("reads camelCase annotation keys too", function()
    local camel = { coverageAnnotations = { { line = 3, endLine = 3, detail = { Case = "Covered", Fields = { 1, { Case = "AllPassing" } } },
      coveringTests = { { testId = "T1", displayName = "t one" } } } } }
    local info = coverage.covering_info(camel, 3, testing.new())
    assert.are.equal("t one", info.tests[1].name)
  end)

  it("falls back to the test ids when the daemon sent ids without names", function()
    local ids_only = { CoverageAnnotations = { { Line = 3, EndLine = 3, Detail = { Case = "Covered", Fields = { 1, { Case = "AllPassing" } } },
      CoveringTestIds = { "ID1", "ID2" }, CoveringTests = {} } } }
    local state = testing.new()
    testing.update_test(state, { testId = "ID1", displayName = "named in state", fullName = "x", status = "Passed",
      origin = { Case = "SourceMapped", Fields = { "/p/T.fs", 5 } } })
    local info = coverage.covering_info(ids_only, 3, state)
    assert.are.equal("named in state", info.tests[1].name)
    assert.are.equal("ID2", info.tests[2].name)
  end)
end)

describe("coverage.test_location", function()
  it("is the file and line the live testing state mapped the test to", function()
    local state = testing.new()
    testing.update_test(state, { testId = "T1", displayName = "t", fullName = "S.t", status = "Passed",
      origin = { Case = "SourceMapped", Fields = { "/p/Tests.fs", 42 } } })
    local file, line = coverage.test_location(state, "T1", "t")
    assert.are.equal("/p/Tests.fs", file)
    assert.are.equal(42, line)
  end)

  it("falls back to the daemon's source locations by test name", function()
    local state = testing.new()
    state.source_locations = { ["S.t"] = { FilePath = "/p/Tests.fs", StartLine = 17 } }
    local file, line = coverage.test_location(state, "NOPE", "S.t")
    assert.are.equal("/p/Tests.fs", file)
    assert.are.equal(17, line)
  end)

  it("is nil when nothing is known", function()
    assert.is_nil(coverage.test_location(testing.new(), "NOPE", "nothing"))
  end)
end)

-- ─── The old per-batch path did not move ─────────────────────────────────────

describe("coverage (older per-batch payloads)", function()
  it("coverage_updated still folds files, lines and hits into the totals", function()
    local state = coverage.new()
    state = coverage.apply_coverage_response(state, { files = { { path = "/p/A.fs", lines = {
      { line = 1, hits = 2 }, { line = 2, hits = 0 } } } } })
    local s = coverage.compute_file_summary(state, "/p/A.fs")
    assert.are.equal(2, s.total)
    assert.are.equal(1, s.covered)
    assert.are.equal(50, coverage.compute_total_summary(state).percent)
  end)

  it("views do not leak into the per-batch totals", function()
    local state = coverage.apply_coverage_view(coverage.new(), view())
    assert.are.equal(0, coverage.file_count(state))
    assert.are.equal(0, coverage.compute_total_summary(state).total)
  end)
end)
