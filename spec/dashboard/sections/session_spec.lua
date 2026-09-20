-- spec/dashboard/sections/session_spec.lua — Session section tests

describe("Session section", function()
  local session_section, state_mod

  before_each(function()
    session_section = require("sagefs.dashboard.sections.session")
    state_mod = require("sagefs.dashboard.state")
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.sections.session"] = nil
    package.loaded["sagefs.dashboard.state"] = nil
  end)

  it("conforms to section protocol", function()
    local section = require("sagefs.dashboard.section")
    assert.is_true(section.validate(session_section))
    package.loaded["sagefs.dashboard.section"] = nil
  end)

  it("shows no sessions when empty", function()
    local s = state_mod.new()
    local out = session_section.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("No sessions"))
  end)

  it("renders sessions with active marker", function()
    local s = state_mod.new()
    s.sessions = {
      { id = "abc12345-long", status = "Ready", project = "Tests" },
      { id = "def67890-long", status = "Evaluating", project = "Core" },
    }
    s.active_session_id = "abc12345-long"
    local out = session_section.render(s)
    assert.is_true(#out.lines >= 3)
    -- First session should have ▶ marker
    assert.truthy(out.lines[2]:find("▶"))
    assert.truthy(out.lines[2]:find("abc12345"))
    assert.truthy(out.lines[2]:find("Ready"))
  end)

  it("highlights faulted sessions", function()
    local s = state_mod.new()
    s.sessions = { { id = "abc12345-long", status = "Faulted", project = "X" } }
    local out = session_section.render(s)
    local has_faulted_hl = false
    for _, hl in ipairs(out.highlights) do
      if hl.hl_group == "SageFsSessionFaulted" then has_faulted_hl = true end
    end
    assert.is_true(has_faulted_hl)
  end)

  -- §5.5: a `Degraded` session (worker Ready, but nothing usable loaded) is,
  -- by definition, `status == "Ready"` — the same status a healthy session
  -- has. Rendering only on `status == "Faulted"` shows it as perfectly
  -- healthy. When `s.health` is present, the verdict must be visible.

  it("highlights a Degraded session distinctly from a healthy Ready one", function()
    local s = state_mod.new()
    s.sessions = {
      { id = "abc12345-long", status = "Ready", project = "X", health = { status = "Degraded", reason = "0 assemblies loaded" } },
    }
    local out = session_section.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("Degraded"), "line should show the Degraded verdict")
    assert.truthy(joined:find("0 assemblies loaded"), "line should show the reason")

    local has_degraded_hl = false
    for _, hl in ipairs(out.highlights) do
      if hl.hl_group == "SageFsSessionDegraded" then has_degraded_hl = true end
    end
    assert.is_true(has_degraded_hl, "should have a distinct highlight group for Degraded")
  end)

  it("does not highlight a Ready session with no health data as degraded (no invented problems)", function()
    local s = state_mod.new()
    s.sessions = { { id = "abc12345-long", status = "Ready", project = "X" } }
    local out = session_section.render(s)
    for _, hl in ipairs(out.highlights) do
      assert.are_not.equal("SageFsSessionDegraded", hl.hl_group)
    end
  end)

  it("has switch_session keymaps", function()
    local s = state_mod.new()
    s.sessions = { { id = "xyz", status = "Ready" } }
    local out = session_section.render(s)
    local found = false
    for _, km in ipairs(out.keymaps) do
      if km.action.type == "switch_session" and km.action.session_id == "xyz" then
        found = true
      end
    end
    assert.is_true(found)
  end)
end)
