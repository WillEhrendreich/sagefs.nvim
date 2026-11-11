-- spec/dashboard/sessions_wiring_spec.lua — the Sessions section shows the plugin's sessions
--
-- Nothing ever wrote state.sessions, so the section said "No sessions" beside a
-- statusline that said "Ready". The plugin's session list (sessions.lua shape:
-- `projects` array, `fault_reason`) now reaches the dashboard state.

local state_mod = require("sagefs.dashboard.state")
local session_section = require("sagefs.dashboard.sections.session")

local plugin_sessions = {
  { id = "abc12345-long", name = "App", status = "Ready", projects = { "src/App.fsproj" } },
  { id = "def67890-long", name = "Core", status = "Faulted", projects = {}, fault_reason = "FSI died" },
}

describe("dashboard sessions", function()
  it("the section listens for the event that carries the session list", function()
    local listens = false
    for _, e in ipairs(session_section.events) do
      if e == "sessions_changed" then listens = true end
    end
    assert.is_true(listens)
  end)

  it("sessions_changed fills the state from the plugin's session shape", function()
    local s = state_mod.update(state_mod.new(), "sessions_changed", { sessions = plugin_sessions, active_id = "abc12345-long" })
    assert.equals(2, #s.sessions)
    assert.equals("abc12345-long", s.sessions[1].id)
    assert.equals("Ready", s.sessions[1].status)
    assert.equals("src/App.fsproj", s.sessions[1].project)
    assert.equals("abc12345-long", s.active_session_id)
  end)

  it("a session without projects shows its name", function()
    local s = state_mod.update(state_mod.new(), "sessions_changed", { sessions = plugin_sessions })
    assert.equals("Core", s.sessions[2].project)
  end)

  it("an empty list clears the sessions", function()
    local s = state_mod.update(state_mod.new(), "sessions_changed", { sessions = plugin_sessions })
    s = state_mod.update(s, "sessions_changed", { sessions = {} })
    assert.equals(0, #s.sessions)
  end)

  it("renders the sessions, the active marker and the fault reason", function()
    local s = state_mod.update(state_mod.new(), "sessions_changed", { sessions = plugin_sessions, active_id = "abc12345-long" })
    local text = table.concat(session_section.render(s).lines, "\n")
    assert.is_nil(text:find("No sessions", 1, true))
    assert.is_truthy(text:find("abc12345", 1, true))
    assert.is_truthy(text:find("FSI died", 1, true), "a faulted session shows the daemon's reason")
  end)

  it("dashboard.sync_sessions feeds the open dashboard's state", function()
    package.loaded["sagefs.dashboard"] = nil
    local dashboard = require("sagefs.dashboard")
    dashboard.set_state(state_mod.new())
    dashboard.sync_sessions(plugin_sessions, { id = "def67890-long" })
    assert.equals(2, #dashboard.get_state().sessions)
    assert.equals("def67890-long", dashboard.get_state().active_session_id)
    package.loaded["sagefs.dashboard"] = nil
  end)
end)
