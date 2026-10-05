-- The reload panel's callers section: what the daemon says about the calls left
-- behind by a save that changed a declaration's signature.
--
-- WHY THIS EXISTS: a save that re-signs a method patches into the running app, and
-- the app now runs the NEW body while a caller in ANOTHER file is still compiled
-- against the old one. `patched (ran)` is true and the save is still not done. The
-- daemon reports this as `lastReload.callers` (and the `callers` object on
-- `reloadReported`), and the plugin had nowhere to show it: the report parsed and
-- the field was dropped on the floor, so the panel said "patched" and stopped.
--
-- The words are the DAEMON'S (`message`, `suggestedAction`), not ours: one writer
-- (`CallerState.toJson`) sends both the structure and the words, so a client that
-- shows its own text can disagree with every other client. What the plugin adds is
-- the LIST: which file, which line, which declaration, and how sure the check was.
require("spec.helper")
local R = require("sagefs.reload_state")
local fx = require("spec.wire_fixtures")

local function decoded(name)
  return vim.json.decode(fx.read(name))
end

describe("reload_state: the callers state is parsed, not dropped", function()
  local report = R.parse(decoded("reload-callers-pending.json"))

  it("reads the state token, so the panel can tell Pending from Current", function()
    assert.are.equal("CallersPending", report.callers.state)
    assert.is_true(report.callers.known)
  end)

  it("reads the daemon's own words rather than inventing some", function()
    -- CallerState.toJson sends `message` and `suggestedAction` so that a client
    -- showing text shows the SAME text. Rewording them here is how the panel and
    -- the dashboard start disagreeing about what a save did.
    assert.truthy(report.callers.message:find("still on the old method", 1, true))
    assert.are.equal("Save Pages.fs", report.callers.suggested_action)
  end)

  it("reads each pending declaration with its cause and its call sites", function()
    assert.are.equal(1, #report.callers.pending)
    local p = report.callers.pending[1]
    assert.are.equal("Shop.Tags.stamp", p.declaration)
    assert.are.equal("ReSigned", p.cause)
    assert.are.equal("/p/Tags.fs", p.file)
    assert.are.equal(3, #p.sites)
  end)

  it("reads a site's file, line and calling declaration", function()
    local s = report.callers.pending[1].sites[1]
    assert.are.equal("/p/Pages.fs", s.file)
    assert.are.equal(12, s.line)
    assert.are.equal("Shop.Pages.render", s.caller)
    assert.are.equal("ResolvedByCompiler", s.evidence)
  end)

  it("distinguishes a site the COMPILER resolved from one matched only by name", function()
    -- This is the whole reason a site carries its evidence: a name match can be
    -- wrong, and a panel that draws both as "a caller" is claiming a certainty it
    -- does not have.
    local s = report.callers.pending[1].sites[2]
    assert.are.equal("MatchedByName", s.evidence)
    assert.are.equal("NoProjectOptions", s.name_only_reason)
    assert.is_false(s.resolved_by_compiler)
    assert.is_true(report.callers.pending[1].sites[1].resolved_by_compiler)
  end)

  it("keeps the detail a name-only match carries, when there is one", function()
    local s = report.callers.pending[1].sites[3]
    assert.are.equal("CompilerFailed", s.name_only_reason)
    assert.are.equal("the check timed out", s.name_only_detail)
  end)

  it("gives a site with no calling declaration an empty one, not a fake module", function()
    -- Caller is "" for code outside any declaration, and a panel that invents a
    -- module name there points the reader at a file that does not exist.
    assert.are.equal("", report.callers.pending[1].sites[2].caller)
  end)

  it("reads the declarations whose callers could not be listed, with the reason", function()
    assert.are.equal(2, #report.callers.not_checked)
    assert.are.equal("NotSearchableByName", report.callers.not_checked[1].why)
    assert.are.equal("( + )", report.callers.not_checked[1].why_subject)
    assert.are.equal("ProjectNotLoaded", report.callers.not_checked[2].why)
  end)

  it("reads NotChecked as its own state, with nothing pending", function()
    local nc = R.parse(decoded("reload-callers-not-checked.json"))
    assert.are.equal("CallersNotChecked", nc.callers.state)
    assert.are.equal(0, #nc.callers.pending)
    assert.are.equal(1, #nc.callers.not_checked)
  end)
end)

describe("reload_state: a report that says nothing about callers", function()
  it("is NotReported, never Current", function()
    -- The distinction is the load-bearing one: NotReported means a worker that
    -- predates the field said nothing, and reading that as "all callers are
    -- current" would claim a check nobody ran. CallerWireTests pins the daemon's
    -- side of exactly this.
    local report = R.parse({ outcome = "Patched", patched = 1, considered = 1 })
    assert.are.equal("CallersNotReported", report.callers.state)
    assert.is_false(report.callers.known)
  end)

  it("says nothing about pending callers, rather than an empty list that reads as none", function()
    local report = R.parse({ outcome = "Patched" })
    assert.are.equal(0, #report.callers.pending)
    assert.is_nil(report.callers.message)
  end)
end)

describe("reload_state.callers_lines: the section the panel shows", function()
  local report = R.parse(decoded("reload-callers-pending.json"))

  it("leads with the daemon's words, so the section needs no explanation of its own", function()
    local lines = R.callers_lines(report)
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("still on the old method", 1, true))
    -- the daemon's message names the file to save; the panel prints that as its ONE
    -- remedy, so the section itself does not repeat it
    assert.truthy(report.callers.suggested_action == "Save Pages.fs",
      "the action is read off the wire even though the section does not print it")
  end)

  it("lists every call site with its file and line, which is what the reader jumps to", function()
    local text = table.concat(R.callers_lines(report), "\n")
    assert.truthy(text:find("Pages.fs", 1, true))
    assert.truthy(text:find("12", 1, true))
    assert.truthy(text:find("40", 1, true))
    assert.truthy(text:find("Shop.fs", 1, true))
    assert.truthy(text:find("Shop.Pages.render", 1, true))
  end)

  it("marks a site matched only by name, because that match can be wrong", function()
    local text = table.concat(R.callers_lines(report), "\n")
    assert.truthy(text:find("by name", 1, true))
    assert.truthy(text:find("NoProjectOptions", 1, true))
  end)

  it("says what could not be checked, and why", function()
    local nc = R.parse(decoded("reload-callers-not-checked.json"))
    local text = table.concat(R.callers_lines(nc), "\n")
    assert.truthy(text:find("ProjectNotLoaded", 1, true))
    assert.truthy(text:find("Shop.Pages.render", 1, true))
  end)

  it("gives no lines at all for a report that said nothing, rather than a confident empty section", function()
    local quiet = R.parse({ outcome = "Patched" })
    assert.are.same({}, R.callers_lines(quiet))
  end)

  it("gives no lines when the state is Current, because there is nothing left behind", function()
    local current = R.parse({
      outcome = "Patched",
      callers = { state = "CallersCurrent", message = "no declaration changed", pending = {}, notChecked = {} },
    })
    assert.are.same({}, R.callers_lines(current))
  end)

  it("returns strings with no highlight group, so the panel keeps one colouring rule", function()
    for _, line in ipairs(R.callers_lines(report)) do
      assert.are.equal("string", type(line))
    end
  end)
end)

describe("reload_state.lines: the callers section does not repeat the panel's remedy", function()
  -- The first version printed the callers' own suggestedAction AND let the panel
  -- print d.remedy, and CallerState.remedy already leads with the callers' when
  -- they are pending. So "→ Save Pages.fs" appeared twice, one quiet and one
  -- coloured. Caught by reading the rendered panel, not by any assertion.
  local report = R.parse(decoded("reload-callers-pending.json"))

  it("prints the remedy exactly once", function()
    -- counted by the ARROW, which is what a remedy line starts with. Counting the
    -- word "→" anywhere also catches a message that happens to contain it, which is
    -- not a second remedy.
    local lines = R.lines(report)
    local arrows = 0
    for _, l in ipairs(lines) do
      if l.text:match("^%s*→") then arrows = arrows + 1 end
    end
    assert.are.equal(1, arrows)
  end)

  it("still prints the remedy at all, so the section is not read as a dead end", function()
    local text = table.concat((function()
      local t = {}
      for _, l in ipairs(R.lines(report)) do table.insert(t, l.text) end
      return t
    end)(), "\n")
    assert.truthy(text:find("Save Pages.fs", 1, true), "the action is still there: " .. text)
  end)

  it("puts the callers section after the verdict and before the remedy", function()
    local lines = R.lines(report)
    local verdict, callers, remedy = nil, nil, nil
    for i, l in ipairs(lines) do
      if l.text:find("new body has not run yet", 1, true) then verdict = i end
      if l.text:find("callers:", 1, true) then callers = i end
      if l.text:find("→", 1, true) then remedy = i end
    end
    assert.truthy(verdict ~= nil and callers ~= nil and remedy ~= nil, "all three are on the panel")
    assert.is_true(verdict < callers, "the verdict leads")
    assert.is_true(callers < remedy, "and the remedy comes last")
  end)
end)
