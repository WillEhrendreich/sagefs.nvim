-- =============================================================================
-- Filter Scope Tests — sagefs/testing.lua (RED → GREEN → REFACTOR)
-- =============================================================================
-- Test panel scope filtering: file, module, all.
-- Pure Lua, no vim API. Defines acceptance criteria for filterable test panel.
-- =============================================================================

local testing = require("sagefs.testing")

-- ─── Test fixture builder ────────────────────────────────────────────────────

--- Build a testing state with realistic test data spanning multiple files/modules
local function build_test_state()
  local s = testing.new()
  -- File 1: EditorTests.fs — 3 tests in SageFs.Tests.EditorTests module
  s = testing.update_test(s, {
    testId = "ed-1",
    displayName = "cursor moves right",
    fullName = "SageFs.Tests.EditorTests.allEditorTests/Editor/cursor moves right",
    origin = { Case = "SourceMapped", Fields = { "C:\\SageFs\\EditorTests.fs", 10 } },
    framework = "Expecto",
    category = "Unit",
    currentPolicy = "OnEveryChange",
    status = "Passed",
  })
  s = testing.update_test(s, {
    testId = "ed-2",
    displayName = "cursor moves left",
    fullName = "SageFs.Tests.EditorTests.allEditorTests/Editor/cursor moves left",
    origin = { Case = "SourceMapped", Fields = { "C:\\SageFs\\EditorTests.fs", 20 } },
    framework = "Expecto",
    category = "Unit",
    currentPolicy = "OnEveryChange",
    status = "Failed",
  })
  s = testing.update_test(s, {
    testId = "ed-3",
    displayName = "delete forward",
    fullName = "SageFs.Tests.EditorTests.allEditorTests/Editor/delete forward",
    origin = { Case = "SourceMapped", Fields = { "C:\\SageFs\\EditorTests.fs", 30 } },
    framework = "Expecto",
    category = "Unit",
    currentPolicy = "OnEveryChange",
    status = "Passed",
  })
  -- File 2: SessionTests.fs — 2 tests in SageFs.Tests.SessionTests module
  s = testing.update_test(s, {
    testId = "sess-1",
    displayName = "session creates",
    fullName = "SageFs.Tests.SessionTests.allSessionTests/Session/session creates",
    origin = { Case = "SourceMapped", Fields = { "C:\\SageFs\\SessionTests.fs", 5 } },
    framework = "Expecto",
    category = "Unit",
    currentPolicy = "OnEveryChange",
    status = "Passed",
  })
  s = testing.update_test(s, {
    testId = "sess-2",
    displayName = "session destroys",
    fullName = "SageFs.Tests.SessionTests.allSessionTests/Session/session destroys",
    origin = { Case = "SourceMapped", Fields = { "C:\\SageFs\\SessionTests.fs", 15 } },
    framework = "Expecto",
    category = "Integration",
    currentPolicy = "OnEveryChange",
    status = "Running",
  })
  -- File 3: EditorTests.fs but different module — SageFs.Tests.EditorAdvanced
  s = testing.update_test(s, {
    testId = "adv-1",
    displayName = "multi-cursor works",
    fullName = "SageFs.Tests.EditorAdvanced.advancedTests/Advanced/multi-cursor works",
    origin = { Case = "SourceMapped", Fields = { "C:\\SageFs\\EditorTests.fs", 100 } },
    framework = "Expecto",
    category = "Unit",
    currentPolicy = "OnEveryChange",
    status = "Passed",
  })
  -- Test with no file mapping (no origin)
  s = testing.update_test(s, {
    testId = "orphan-1",
    displayName = "orphan test",
    fullName = "SageFs.Tests.Misc.orphan test",
    framework = "Expecto",
    category = "Unit",
    currentPolicy = "OnEveryChange",
    status = "Passed",
  })
  return s
end

-- ─── VALID_SCOPES ────────────────────────────────────────────────────────────

describe("testing.VALID_SCOPES", function()
  it("contains file, module, and all", function()
    assert.is_true(testing.VALID_SCOPES.file)
    assert.is_true(testing.VALID_SCOPES.module)
    assert.is_true(testing.VALID_SCOPES.all)
  end)

  it("does not contain cursor (deferred)", function()
    assert.is_nil(testing.VALID_SCOPES.cursor)
  end)
end)

describe("testing.is_valid_scope", function()
  it("accepts file, module, all", function()
    assert.is_true(testing.is_valid_scope("file"))
    assert.is_true(testing.is_valid_scope("module"))
    assert.is_true(testing.is_valid_scope("all"))
  end)

  it("rejects unknown scopes", function()
    assert.is_false(testing.is_valid_scope("cursor"))
    assert.is_false(testing.is_valid_scope("banana"))
    assert.is_false(testing.is_valid_scope(""))
    assert.is_false(testing.is_valid_scope(nil))
  end)
end)

-- ─── filter_by_scope: all ────────────────────────────────────────────────────

describe("testing.filter_by_scope (all)", function()
  it("returns all tests", function()
    local s = build_test_state()
    local scope = { kind = "all" }
    local results = testing.filter_by_scope(s, scope)
    assert.are.equal(7, #results)
  end)

  it("returns empty for empty state", function()
    local s = testing.new()
    local scope = { kind = "all" }
    local results = testing.filter_by_scope(s, scope)
    assert.are.equal(0, #results)
  end)
end)

-- ─── filter_by_scope: file ───────────────────────────────────────────────────

describe("testing.filter_by_scope (file)", function()
  it("returns only tests from the specified file", function()
    local s = build_test_state()
    local scope = { kind = "file", path = "C:\\SageFs\\EditorTests.fs" }
    local results = testing.filter_by_scope(s, scope)
    -- EditorTests.fs has ed-1, ed-2, ed-3, adv-1 (4 tests, 2 modules)
    assert.are.equal(4, #results)
  end)

  it("returns empty when file has no tests", function()
    local s = build_test_state()
    local scope = { kind = "file", path = "C:\\SageFs\\NoSuchFile.fs" }
    local results = testing.filter_by_scope(s, scope)
    assert.are.equal(0, #results)
  end)

  it("returns empty when path is nil", function()
    local s = build_test_state()
    local scope = { kind = "file", path = nil }
    local results = testing.filter_by_scope(s, scope)
    assert.are.equal(0, #results)
  end)

  it("returns only SessionTests file tests", function()
    local s = build_test_state()
    local scope = { kind = "file", path = "C:\\SageFs\\SessionTests.fs" }
    local results = testing.filter_by_scope(s, scope)
    assert.are.equal(2, #results)
    local names = {}
    for _, r in ipairs(results) do names[r.displayName] = true end
    assert.is_true(names["session creates"])
    assert.is_true(names["session destroys"])
  end)

  it("matches when buffer uses backslashes but index uses forward slashes", function()
    -- Daemon stores paths with forward slashes; Neovim buffers use backslashes on Windows
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "fwd-1",
      displayName = "forward slash test",
      fullName = "Mod.fwd test",
      origin = { Case = "SourceMapped", Fields = { "C:/Code/Repos/Proj/Foo.fs", 5 } },
      framework = "Expecto", category = "Unit", currentPolicy = "OnEveryChange", status = "Passed",
    })
    -- Query with backslash path (as Neovim would provide)
    local scope = { kind = "file", path = "C:\\Code\\Repos\\Proj\\Foo.fs" }
    local results = testing.filter_by_scope(s, scope)
    assert.are.equal(1, #results)
    assert.are.equal("forward slash test", results[1].displayName)
  end)

  it("matches when buffer uses forward slashes but index uses backslashes", function()
    local s = testing.new()
    s = testing.update_test(s, {
      testId = "bk-1",
      displayName = "backslash test",
      fullName = "Mod.bk test",
      origin = { Case = "SourceMapped", Fields = { "C:\\Code\\Repos\\Proj\\Bar.fs", 5 } },
      framework = "Expecto", category = "Unit", currentPolicy = "OnEveryChange", status = "Passed",
    })
    local scope = { kind = "file", path = "C:/Code/Repos/Proj/Bar.fs" }
    local results = testing.filter_by_scope(s, scope)
    assert.are.equal(1, #results)
    assert.are.equal("backslash test", results[1].displayName)
  end)
end)

-- ─── filter_by_scope: module ─────────────────────────────────────────────────

describe("testing.filter_by_scope (module)", function()
  it("returns tests whose fullName starts with prefix", function()
    local s = build_test_state()
    local scope = { kind = "module", prefix = "SageFs.Tests.EditorTests" }
    local results = testing.filter_by_scope(s, scope)
    -- Only ed-1, ed-2, ed-3 — NOT adv-1 (EditorAdvanced)
    assert.are.equal(3, #results)
    local names = {}
    for _, r in ipairs(results) do names[r.displayName] = true end
    assert.is_true(names["cursor moves right"])
    assert.is_true(names["cursor moves left"])
    assert.is_true(names["delete forward"])
  end)

  it("returns tests from a broader prefix", function()
    local s = build_test_state()
    local scope = { kind = "module", prefix = "SageFs.Tests.Editor" }
    local results = testing.filter_by_scope(s, scope)
    -- Matches EditorTests (3) + EditorAdvanced (1) = 4
    assert.are.equal(4, #results)
  end)

  it("returns empty for non-matching prefix", function()
    local s = build_test_state()
    local scope = { kind = "module", prefix = "SageFs.Tests.Nonexistent" }
    local results = testing.filter_by_scope(s, scope)
    assert.are.equal(0, #results)
  end)

  it("returns empty when prefix is nil", function()
    local s = build_test_state()
    local scope = { kind = "module", prefix = nil }
    local results = testing.filter_by_scope(s, scope)
    assert.are.equal(0, #results)
  end)

  it("matches all tests with top-level namespace prefix", function()
    local s = build_test_state()
    local scope = { kind = "module", prefix = "SageFs.Tests" }
    local results = testing.filter_by_scope(s, scope)
    -- All 7 tests are under SageFs.Tests.*
    assert.are.equal(7, #results)
  end)
end)

-- ─── filter_by_scope: binding (treesitter-detected) ─────────────────────────

describe("testing.filter_by_scope (binding)", function()
  it("returns tests whose fullName contains the binding name", function()
    local s = build_test_state()
    -- "allEditorTests" appears in fullName: SageFs.Tests.EditorTests.allEditorTests/Editor/...
    local scope = { kind = "binding", name = "allEditorTests", path = "C:\\SageFs\\EditorTests.fs" }
    local results = testing.filter_by_scope(s, scope)
    assert.are.equal(3, #results)
    for _, r in ipairs(results) do
      assert.is_truthy(r.fullName:find("allEditorTests"), "should match binding name")
    end
  end)

  it("returns empty when no tests match the binding name", function()
    local s = build_test_state()
    local scope = { kind = "binding", name = "nonexistentBinding", path = "C:\\SageFs\\EditorTests.fs" }
    local results = testing.filter_by_scope(s, scope)
    assert.are.equal(0, #results)
  end)

  it("scopes to file first, then filters by binding name", function()
    local s = build_test_state()
    -- "allEditorTests" only in EditorTests.fs, not in SessionTests.fs
    local scope = { kind = "binding", name = "allEditorTests", path = "C:\\SageFs\\SessionTests.fs" }
    local results = testing.filter_by_scope(s, scope)
    assert.are.equal(0, #results)
  end)

  it("returns empty when name is nil", function()
    local s = build_test_state()
    local scope = { kind = "binding", name = nil, path = "C:\\SageFs\\EditorTests.fs" }
    local results = testing.filter_by_scope(s, scope)
    assert.are.equal(0, #results)
  end)
end)

-- ─── filter_by_scope: unknown kind ──────────────────────────────────────────

describe("testing.filter_by_scope (unknown kind)", function()
  it("errors on unknown scope kind", function()
    local s = build_test_state()
    local scope = { kind = "banana" }
    assert.has_error(function()
      testing.filter_by_scope(s, scope)
    end, "unknown scope kind: banana")
  end)
end)

-- ─── filter_by_scope: result structure ──────────────────────────────────────

describe("testing.filter_by_scope result entries", function()
  it("each entry has testId, displayName, fullName, status, file, line", function()
    local s = build_test_state()
    local scope = { kind = "file", path = "C:\\SageFs\\SessionTests.fs" }
    local results = testing.filter_by_scope(s, scope)
    for _, entry in ipairs(results) do
      assert.is_not_nil(entry.testId, "should have testId")
      assert.is_not_nil(entry.displayName, "should have displayName")
      assert.is_not_nil(entry.fullName, "should have fullName")
      assert.is_not_nil(entry.status, "should have status")
    end
  end)
end)

-- ─── format_scoped_panel_entries ─────────────────────────────────────────────

describe("testing.format_scoped_panel_entries", function()
  it("header shows scope kind and target for file scope", function()
    local s = build_test_state()
    local scope = { kind = "file", path = "C:\\SageFs\\EditorTests.fs" }
    local entries = testing.format_scoped_panel_entries(s, scope)
    -- First entry is the header
    assert.is_truthy(entries[1].text:find("file"), "header should mention scope kind")
    assert.is_truthy(entries[1].text:find("EditorTests.fs"), "header should show filename")
  end)

  it("header shows scope kind for all scope", function()
    local s = build_test_state()
    local scope = { kind = "all" }
    local entries = testing.format_scoped_panel_entries(s, scope)
    assert.is_truthy(entries[1].text:find("all"), "header should mention 'all'")
  end)

  it("header shows scope kind and prefix for module scope", function()
    local s = build_test_state()
    local scope = { kind = "module", prefix = "SageFs.Tests.EditorTests" }
    local entries = testing.format_scoped_panel_entries(s, scope)
    assert.is_truthy(entries[1].text:find("module"), "header should mention scope kind")
    assert.is_truthy(entries[1].text:find("EditorTests"), "header should show module name")
  end)

  it("header includes pass/fail counts", function()
    local s = build_test_state()
    local scope = { kind = "file", path = "C:\\SageFs\\EditorTests.fs" }
    local entries = testing.format_scoped_panel_entries(s, scope)
    -- EditorTests.fs: 3 passed, 1 failed
    assert.is_truthy(entries[1].text:find("3"), "header should show passed count")
    assert.is_truthy(entries[1].text:find("1"), "header should show failed count")
  end)

  it("shows keybinding hints in second line", function()
    local s = build_test_state()
    local scope = { kind = "file", path = "C:\\SageFs\\EditorTests.fs" }
    local entries = testing.format_scoped_panel_entries(s, scope)
    local hint_line = entries[2].text
    -- Active scope shows as [f]ile, others as m:module, a:all
    assert.is_truthy(hint_line:find("%[f%]"), "should show [f] for active scope")
    assert.is_truthy(hint_line:find("m:"), "should show m: hint")
    assert.is_truthy(hint_line:find("a:"), "should show a: hint")
  end)

  it("failures sort before passes in test entries", function()
    local s = build_test_state()
    local scope = { kind = "file", path = "C:\\SageFs\\EditorTests.fs" }
    local entries = testing.format_scoped_panel_entries(s, scope)
    -- Skip header (1), separator (2), blank (3) — tests start at 4
    local test_entries = {}
    for i = 4, #entries do
      if entries[i].file then
        table.insert(test_entries, entries[i])
      end
    end
    -- First test entry should be the failed one
    assert.is_truthy(test_entries[1].text:find("✖"), "first test should be failed (✖)")
    assert.is_truthy(test_entries[1].text:find("cursor moves left"), "first test should be the failed one")
  end)

  it("shows '0 tests' message when scope matches nothing", function()
    local s = build_test_state()
    local scope = { kind = "file", path = "C:\\SageFs\\NoSuchFile.fs" }
    local entries = testing.format_scoped_panel_entries(s, scope)
    local all_text = ""
    for _, e in ipairs(entries) do all_text = all_text .. (e.text or "") end
    assert.is_truthy(all_text:find("No tests"), "should show empty message")
  end)

  it("entries have navigation metadata (file + line)", function()
    local s = build_test_state()
    local scope = { kind = "file", path = "C:\\SageFs\\EditorTests.fs" }
    local entries = testing.format_scoped_panel_entries(s, scope)
    local has_nav = false
    for _, e in ipairs(entries) do
      if e.file and e.line then has_nav = true; break end
    end
    assert.is_true(has_nav, "at least one entry should have file+line for navigation")
  end)

  it("hint line shows [b]inding when binding scope active", function()
    local s = build_test_state()
    local scope = { kind = "binding", name = "allEditorTests", path = "C:\\SageFs\\EditorTests.fs" }
    local entries = testing.format_scoped_panel_entries(s, scope)
    local hint = entries[2].text
    assert.is_truthy(hint:find("%[b%]"), "should show [b] for active binding scope")
    assert.is_truthy(hint:find("f:file"), "should show f:file as inactive")
  end)
end)

-- ─── scope_label: human-readable description ────────────────────────────────

describe("testing.scope_label", function()
  it("returns filename for file scope", function()
    local label = testing.scope_label({ kind = "file", path = "C:\\SageFs\\EditorTests.fs" })
    assert.are.equal("file: EditorTests.fs", label)
  end)

  it("returns module prefix for module scope", function()
    local label = testing.scope_label({ kind = "module", prefix = "SageFs.Tests.EditorTests" })
    assert.are.equal("module: EditorTests", label)
  end)

  it("returns 'all' for all scope", function()
    local label = testing.scope_label({ kind = "all" })
    assert.are.equal("all", label)
  end)

  it("handles nil path gracefully", function()
    local label = testing.scope_label({ kind = "file", path = nil })
    assert.are.equal("file: (none)", label)
  end)

  it("handles nil prefix gracefully", function()
    local label = testing.scope_label({ kind = "module", prefix = nil })
    assert.are.equal("module: (none)", label)
  end)

  it("returns binding name for binding scope", function()
    local label = testing.scope_label({ kind = "binding", name = "allEditorTests" })
    assert.are.equal("binding: allEditorTests", label)
  end)

  it("handles nil binding name gracefully", function()
    local label = testing.scope_label({ kind = "binding", name = nil })
    assert.are.equal("binding: (none)", label)
  end)
end)

-- ─── next_scope: cycling ────────────────────────────────────────────────────

describe("testing.next_scope", function()
  it("cycles binding → file → module → all → binding", function()
    assert.are.equal("file", testing.next_scope("binding"))
    assert.are.equal("module", testing.next_scope("file"))
    assert.are.equal("all", testing.next_scope("module"))
    assert.are.equal("binding", testing.next_scope("all"))
  end)

  it("defaults to binding for unknown input", function()
    assert.are.equal("binding", testing.next_scope("banana"))
    assert.are.equal("binding", testing.next_scope(nil))
  end)
end)
