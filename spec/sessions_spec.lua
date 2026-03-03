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
end)
