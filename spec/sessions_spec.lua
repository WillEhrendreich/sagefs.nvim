require("spec.helper")
local sessions = require("sagefs.sessions")

describe("sagefs.sessions", function()

  -- ─── parse_sessions_response ─────────────────────────────────────────────

  describe("parse_sessions_response", function()
    it("parses a valid sessions list", function()
      local json = vim.json.encode({
        sessions = {
          {
            id = "abc-123",
            status = "Ready",
            projects = { "MyApp.fsproj" },
            workingDirectory = "C:\\Code\\MyApp",
            evalCount = 5,
            avgDurationMs = 42.3,
          },
          {
            id = "def-456",
            status = "Busy",
            projects = { "Tests.fsproj" },
            workingDirectory = "C:\\Code\\Tests",
            evalCount = 12,
            avgDurationMs = 100.0,
          },
        },
      })

      local result = sessions.parse_sessions_response(json)
      assert.is_true(result.ok)
      assert.equals(2, #result.sessions)
      assert.equals("abc-123", result.sessions[1].id)
      assert.equals("Ready", result.sessions[1].status)
      assert.same({ "MyApp.fsproj" }, result.sessions[1].projects)
      assert.equals("C:\\Code\\MyApp", result.sessions[1].working_directory)
      assert.equals(5, result.sessions[1].eval_count)
      assert.equals(42.3, result.sessions[1].avg_duration_ms)
    end)

    -- §5.5: `sessions.lua`'s normalization dropped `health`, `faultReason`
    -- and `loadedProjects` entirely, so a `Degraded` session (worker Ready,
    -- but nothing usable loaded) rendered identically to a healthy one
    -- everywhere in the plugin — the picker, the statusline, the dashboard.

    it("parses health, faultReason and loadedProjects", function()
      local json = vim.json.encode({
        sessions = {
          {
            id = "abc-123",
            status = "Ready",
            projects = {},
            workingDirectory = "C:\\Code\\MyApp",
            evalCount = 0,
            avgDurationMs = 0,
            faultReason = vim.NIL,
            health = { status = "Degraded", reason = "Session is Ready but nothing was loaded" },
            loadedProjects = { "C:\\Code\\MyApp\\MyApp.fsproj" },
          },
        },
      })

      local result = sessions.parse_sessions_response(json)
      assert.is_true(result.ok)
      assert.same({ status = "Degraded", reason = "Session is Ready but nothing was loaded" }, result.sessions[1].health)
      assert.same({ "C:\\Code\\MyApp\\MyApp.fsproj" }, result.sessions[1].loaded_projects)
    end)

    it("defaults loaded_projects to an empty list and health to nil when absent", function()
      local json = vim.json.encode({
        sessions = { { id = "abc", status = "Ready", projects = {}, workingDirectory = "", evalCount = 0, avgDurationMs = 0 } },
      })
      local result = sessions.parse_sessions_response(json)
      assert.is_nil(result.sessions[1].health)
      assert.same({}, result.sessions[1].loaded_projects)
    end)

    it("returns error for nil input", function()
      local result = sessions.parse_sessions_response(nil)
      assert.is_false(result.ok)
      assert.is_truthy(result.error)
    end)

    it("returns error for empty string", function()
      local result = sessions.parse_sessions_response("")
      assert.is_false(result.ok)
    end)

    it("returns error for invalid JSON", function()
      local result = sessions.parse_sessions_response("{not json")
      assert.is_false(result.ok)
    end)

    it("returns empty list when no sessions", function()
      local json = vim.json.encode({ sessions = {} })
      local result = sessions.parse_sessions_response(json)
      assert.is_true(result.ok)
      assert.equals(0, #result.sessions)
    end)

    it("handles missing optional fields gracefully", function()
      local json = vim.json.encode({
        sessions = {
          { id = "min-session", status = "Ready" },
        },
      })
      local result = sessions.parse_sessions_response(json)
      assert.is_true(result.ok)
      assert.equals("min-session", result.sessions[1].id)
      assert.same({}, result.sessions[1].projects)
      assert.equals("", result.sessions[1].working_directory)
      assert.equals(0, result.sessions[1].eval_count)
      assert.equals(0, result.sessions[1].avg_duration_ms)
    end)
  end)

  -- ─── parse_action_response ───────────────────────────────────────────────

  describe("parse_action_response", function()
    it("parses a success response", function()
      local json = vim.json.encode({ success = true, message = "Session created" })
      local result = sessions.parse_action_response(json)
      assert.is_true(result.ok)
      assert.equals("Session created", result.message)
    end)

    it("parses an error response", function()
      local json = vim.json.encode({ success = false, error = "Session not found" })
      local result = sessions.parse_action_response(json)
      assert.is_false(result.ok)
      assert.equals("Session not found", result.error)
    end)

    it("returns error for nil input", function()
      local result = sessions.parse_action_response(nil)
      assert.is_false(result.ok)
    end)

    it("returns error for invalid JSON", function()
      local result = sessions.parse_action_response("oops")
      assert.is_false(result.ok)
    end)

    it("extracts sessionId from switch response", function()
      local json = vim.json.encode({ success = true, sessionId = "abc-123" })
      local result = sessions.parse_action_response(json)
      assert.is_true(result.ok)
      assert.equals("abc-123", result.session_id)
    end)

    -- §5.8: /api/sessions/create|switch|stop errors actually come back as
    -- `{success=false, error=<describe>, errorDetails={message,
    -- suggestedAction}}` (McpServer.fs's structuredErrorBody) — the daemon
    -- DOES send a remedy on these routes, and parse_action_response threw
    -- it away.
    it("appends suggestedAction from errorDetails to the error message", function()
      local json = vim.json.encode({
        success = false,
        error = "Session not found",
        errorDetails = { case = "NotFound", message = "Session not found", suggestedAction = "Run :SageFsSessions to see live sessions" },
      })
      local result = sessions.parse_action_response(json)
      assert.is_false(result.ok)
      assert.is_truthy(result.error:find("Session not found", 1, true))
      assert.is_truthy(result.error:find("Run :SageFsSessions", 1, true))
    end)

    it("still works when errorDetails is absent", function()
      local json = vim.json.encode({ success = false, error = "Session not found" })
      local result = sessions.parse_action_response(json)
      assert.equals("Session not found", result.error)
    end)
  end)

  -- ─── format_session_line ─────────────────────────────────────────────────

  describe("format_session_line", function()
    it("shows project name and status", function()
      local s = {
        id = "abc-123",
        status = "Ready",
        projects = { "MyApp.fsproj" },
        working_directory = "C:\\Code\\MyApp",
        eval_count = 5,
        avg_duration_ms = 42.3,
      }
      local line = sessions.format_session_line(s)
      assert.is_truthy(line:find("MyApp.fsproj"))
      assert.is_truthy(line:find("Ready"))
    end)

    it("shows multiple projects", function()
      local s = {
        id = "abc",
        status = "Ready",
        projects = { "A.fsproj", "B.fsproj" },
        working_directory = "",
        eval_count = 0,
        avg_duration_ms = 0,
      }
      local line = sessions.format_session_line(s)
      assert.is_truthy(line:find("A.fsproj"))
      assert.is_truthy(line:find("B.fsproj"))
    end)

    it("shows (no project) when projects list is empty", function()
      local s = {
        id = "abc",
        status = "Ready",
        projects = {},
        working_directory = "",
        eval_count = 0,
        avg_duration_ms = 0,
      }
      local line = sessions.format_session_line(s)
      assert.is_truthy(line:find("no project"))
    end)

    it("includes eval count", function()
      local s = {
        id = "abc",
        status = "Ready",
        projects = { "X.fsproj" },
        working_directory = "",
        eval_count = 42,
        avg_duration_ms = 0,
      }
      local line = sessions.format_session_line(s)
      assert.is_truthy(line:find("42"))
    end)

    -- §5.5: a `Degraded` session (worker Ready, but nothing usable loaded)
    -- rendered in the picker as plain "MyApp.fsproj  Ready" — identical to
    -- a healthy session. The picker line must say so.

    it("shows a Degraded verdict and reason in the picker line", function()
      local s = {
        id = "abc", status = "Ready", projects = { "MyApp.fsproj" }, working_directory = "",
        eval_count = 3, avg_duration_ms = 0,
        health = { status = "Degraded", reason = "0 assemblies loaded" },
      }
      local line = sessions.format_session_line(s)
      assert.is_truthy(line:find("Degraded", 1, true))
      assert.is_truthy(line:find("0 assemblies loaded", 1, true))
    end)

    it("shows no health suffix for a Healthy session", function()
      local s = {
        id = "abc", status = "Ready", projects = { "MyApp.fsproj" }, working_directory = "",
        eval_count = 0, avg_duration_ms = 0,
        health = { status = "Healthy" },
      }
      local line = sessions.format_session_line(s)
      assert.is_falsy(line:find("Degraded", 1, true))
      assert.is_falsy(line:find("Failed", 1, true))
    end)

    it("shows no health suffix when health is absent (no invented problems)", function()
      local s = { id = "abc", status = "Ready", projects = { "MyApp.fsproj" }, working_directory = "", eval_count = 0, avg_duration_ms = 0 }
      local line = sessions.format_session_line(s)
      assert.equals("MyApp.fsproj  Ready", line)
    end)
  end)

  -- ─── format_statusline ───────────────────────────────────────────────────

  describe("format_statusline", function()
    it("shows project name and status for active session", function()
      local s = {
        id = "abc",
        status = "Ready",
        projects = { "SageFs.Tests.fsproj" },
        working_directory = "C:\\Code\\SageFs",
        eval_count = 10,
        avg_duration_ms = 25.0,
      }
      local text = sessions.format_statusline(s)
      assert.is_truthy(text:find("SageFs.Tests"))
      assert.is_truthy(text:find("Ready"))
    end)

    it("returns empty string for nil session", function()
      assert.equals("", sessions.format_statusline(nil))
    end)

    it("strips .fsproj extension from project name", function()
      local s = {
        id = "abc",
        status = "Ready",
        projects = { "MyApp.fsproj" },
        working_directory = "",
        eval_count = 0,
        avg_duration_ms = 0,
      }
      local text = sessions.format_statusline(s)
      assert.is_truthy(text:find("MyApp"))
      assert.is_falsy(text:find("%.fsproj"))
    end)

    -- The connection-aware icon used to live only in the `else` branch of
    -- init.lua's statusline() — reached only when there was NO active
    -- session. With an active session, format_statusline always rendered
    -- an unconditional ⚡, so a dead daemon kept showing
    -- "⚡ MyProject (Ready)" forever. format_statusline now takes the
    -- connection status explicitly, so the caller can never skip it.

    it("defaults to the connected icon when no connection status is given (back-compat)", function()
      local s = { id = "abc", status = "Ready", projects = { "MyApp.fsproj" }, eval_count = 0, avg_duration_ms = 0 }
      local text = sessions.format_statusline(s)
      assert.is_truthy(text:find("⚡", 1, true))
    end)

    it("shows the connected icon when the transport is connected", function()
      local s = { id = "abc", status = "Ready", projects = { "MyApp.fsproj" }, eval_count = 0, avg_duration_ms = 0 }
      local text = sessions.format_statusline(s, "connected")
      assert.is_truthy(text:find("⚡", 1, true))
    end)

    it("shows the reconnecting icon when the transport is reconnecting, even with an active session", function()
      local s = { id = "abc", status = "Ready", projects = { "MyApp.fsproj" }, eval_count = 0, avg_duration_ms = 0 }
      local text = sessions.format_statusline(s, "reconnecting")
      assert.is_truthy(text:find("🔌", 1, true))
      assert.is_falsy(text:find("⚡", 1, true))
    end)

    it("shows a disconnected icon when the daemon is dead, even with an active session — the §5.1 fix", function()
      local s = { id = "abc", status = "Ready", projects = { "MyApp.fsproj" }, eval_count = 0, avg_duration_ms = 0 }
      local text = sessions.format_statusline(s, "disconnected")
      assert.is_truthy(text:find("💤", 1, true))
      assert.is_falsy(text:find("⚡", 1, true))
      -- The lie this fixes: the daemon is dead but the session still reads "Ready".
      assert.is_truthy(text:find("Ready", 1, true))
    end)

    it("appends a degraded marker when the session's health is Degraded", function()
      local s = {
        id = "abc", status = "Ready", projects = { "MyApp.fsproj" }, eval_count = 0, avg_duration_ms = 0,
        health = { status = "Degraded", reason = "0 assemblies loaded" },
      }
      local text = sessions.format_statusline(s, "connected")
      assert.is_truthy(text:find("⚠", 1, true))
    end)

    it("appends a failed marker when the session's health is Failed", function()
      local s = {
        id = "abc", status = "Faulted", projects = { "MyApp.fsproj" }, eval_count = 0, avg_duration_ms = 0,
        health = { status = "Failed", reason = "Session faulted" },
      }
      local text = sessions.format_statusline(s, "connected")
      assert.is_truthy(text:find("❌", 1, true))
    end)

    it("adds no marker when the session's health is Healthy", function()
      local s = {
        id = "abc", status = "Ready", projects = { "MyApp.fsproj" }, eval_count = 0, avg_duration_ms = 0,
        health = { status = "Healthy" },
      }
      local text = sessions.format_statusline(s, "connected")
      assert.is_falsy(text:find("⚠", 1, true))
      assert.is_falsy(text:find("❌", 1, true))
    end)
  end)

  -- ─── find_session_for_dir ────────────────────────────────────────────────

  describe("find_session_for_dir", function()
    local list = {
      {
        id = "s1",
        status = "Ready",
        projects = {},
        working_directory = "C:\\Code\\SageFs",
        eval_count = 0,
        avg_duration_ms = 0,
      },
      {
        id = "s2",
        status = "Ready",
        projects = {},
        working_directory = "C:\\Code\\Other",
        eval_count = 0,
        avg_duration_ms = 0,
      },
    }

    it("finds session matching working directory", function()
      local s = sessions.find_session_for_dir(list, "C:\\Code\\SageFs")
      assert.is_not_nil(s)
      assert.equals("s1", s.id)
    end)

    it("matches case-insensitively on Windows", function()
      local s = sessions.find_session_for_dir(list, "c:\\code\\sagefs")
      assert.is_not_nil(s)
      assert.equals("s1", s.id)
    end)

    it("returns nil when no match", function()
      local s = sessions.find_session_for_dir(list, "C:\\Code\\Nope")
      assert.is_nil(s)
    end)

    it("returns nil for empty list", function()
      local s = sessions.find_session_for_dir({}, "C:\\Code\\SageFs")
      assert.is_nil(s)
    end)

    it("matches forward-slash server path against backslash cwd", function()
      local mixed_list = {
        {
          id = "s1",
          status = "Ready",
          projects = { "App.fsproj" },
          working_directory = "C:/Code/SageFs",
          eval_count = 0,
          avg_duration_ms = 0,
        },
      }
      local s = sessions.find_session_for_dir(mixed_list, "C:\\Code\\SageFs")
      assert.is_not_nil(s)
      assert.equals("s1", s.id)
    end)
  end)

  -- ─── session_actions ─────────────────────────────────────────────────────

  describe("session_actions", function()
    it("offers switch and stop for a Ready session", function()
      local actions = sessions.session_actions({ status = "Ready" })
      local names = {}
      for _, a in ipairs(actions) do names[a.name] = true end
      assert.is_true(names["switch"])
      assert.is_true(names["stop"])
    end)

    it("offers stop for a Busy session", function()
      local actions = sessions.session_actions({ status = "Busy" })
      local names = {}
      for _, a in ipairs(actions) do names[a.name] = true end
      assert.is_true(names["stop"])
    end)

    it("always includes create", function()
      local actions = sessions.session_actions({ status = "Ready" })
      local names = {}
      for _, a in ipairs(actions) do names[a.name] = true end
      assert.is_true(names["create"])
    end)
  end)

  -- ─── normalize_path ──────────────────────────────────────────────────────

  describe("normalize_path", function()
    it("lowercases and normalizes backslashes to forward slashes", function()
      assert.equals("c:/code/sagefs", sessions.normalize_path("C:\\Code\\SageFs"))
    end)

    it("preserves forward slashes and lowercases", function()
      assert.equals("c:/code/sagefs", sessions.normalize_path("C:/Code/SageFs"))
    end)

    it("makes mixed separators equivalent", function()
      local a = sessions.normalize_path("C:\\Code\\SageFs")
      local b = sessions.normalize_path("C:/Code/SageFs")
      assert.equals(a, b)
    end)

    it("strips trailing separator", function()
      local result = sessions.normalize_path("C:\\Code\\SageFs\\")
      assert.is_falsy(result:match("[/\\]$"))
    end)

    it("handles nil gracefully", function()
      assert.equals("", sessions.normalize_path(nil))
    end)
  end)

  -- ─── build_buffer_change_request ─────────────────────────────────────────
  -- Routing logic for POST /api/sessions/{sid}/buffer-changed — mirrors
  -- sagefs-vscode's BufferBridge.resolveSessionOwnership.

  describe("build_buffer_change_request", function()
    local session_a = { id = "sess-a", working_directory = "C:\\Code\\ProjA" }
    local session_b = { id = "sess-b", working_directory = "C:\\Code\\ProjB" }

    it("returns nil for a non-F# file", function()
      local req = sessions.build_buffer_change_request(
        { session_a }, session_a, "C:\\Code\\ProjA\\Readme.md", "content")
      assert.is_nil(req)
    end)

    it("returns nil for an empty file path", function()
      local req = sessions.build_buffer_change_request({ session_a }, session_a, "", "content")
      assert.is_nil(req)
    end)

    it("routes to the unique session whose working directory contains the file", function()
      local req = sessions.build_buffer_change_request(
        { session_a, session_b }, nil, "C:\\Code\\ProjA\\Hello.fs", "let x = 1")

      assert.is_not_nil(req)
      assert.equals("/api/sessions/sess-a/buffer-changed", req.path)
      assert.same({ filePath = "C:\\Code\\ProjA\\Hello.fs", content = "let x = 1" }, req.body)
    end)

    it("matches .fsx and .fsi files too", function()
      local reqx = sessions.build_buffer_change_request(
        { session_a }, nil, "C:\\Code\\ProjA\\script.fsx", "1 + 1")
      assert.equals("/api/sessions/sess-a/buffer-changed", reqx.path)

      local reqi = sessions.build_buffer_change_request(
        { session_a }, nil, "C:\\Code\\ProjA\\Hello.fsi", "val x: int")
      assert.equals("/api/sessions/sess-a/buffer-changed", reqi.path)
    end)

    it("returns nil when the file is ambiguous across multiple sessions", function()
      local nested_a = { id = "sess-a", working_directory = "C:\\Code" }
      local nested_b = { id = "sess-b", working_directory = "C:\\Code\\ProjA" }
      local req = sessions.build_buffer_change_request(
        { nested_a, nested_b }, nil, "C:\\Code\\ProjA\\Hello.fs", "let x = 1")
      assert.is_nil(req)
    end)

    it("falls back to the active session when no session_list entry matches", function()
      local req = sessions.build_buffer_change_request(
        {}, session_a, "C:\\Code\\ProjA\\Hello.fs", "let x = 1")
      assert.is_not_nil(req)
      assert.equals("/api/sessions/sess-a/buffer-changed", req.path)
    end)

    it("returns nil when neither session_list nor the active session own the file", function()
      local req = sessions.build_buffer_change_request(
        { session_b }, session_b, "C:\\Code\\ProjA\\Hello.fs", "let x = 1")
      assert.is_nil(req)
    end)

    it("returns nil when there are no sessions at all", function()
      local req = sessions.build_buffer_change_request({}, nil, "C:\\Code\\ProjA\\Hello.fs", "let x = 1")
      assert.is_nil(req)
    end)
  end)
end)
