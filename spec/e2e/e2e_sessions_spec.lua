-- spec/e2e/e2e_sessions_spec.lua — E2E tests for session management
-- Runs against a real SageFs daemon with the Minimal sample project.
-- Usage: nvim --headless --clean -u NONE -l spec/e2e/e2e_sessions_spec.lua

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
package.path = script_dir .. "?.lua;" .. package.path

local H = require("e2e_harness")

H.run_suite({
  name = "Sessions",
  sample = "Minimal",
  port = 47751,

  fn = function(sagefs, temp, handle)

    H.describe("GET /api/sessions", function()
      H.it("returns at least one session", function()
        local resp = H.http_get("/api/sessions", handle.port)
        H.assert_eq(200, resp.status, "sessions status")
        -- Response should be JSON array or object with session data
        H.assert_truthy(#resp.body > 2, "sessions body should have content")
      end)

      H.it("session has project metadata", function()
        local resp = H.http_get("/api/sessions", handle.port)
        H.assert_eq(200, resp.status, "sessions status")
        -- Response JSON includes projects array and workingDirectory field
        H.assert_truthy(
          resp.body:find("projects") or resp.body:find("workingDirectory") or resp.body:find("fsproj"),
          "session should reference the loaded project"
        )
      end)
    end)

    H.describe("session persistence across reset", function()
      H.it("session survives /reset", function()
        -- Get sessions before reset
        local before = H.http_get("/api/sessions", handle.port)
        H.assert_eq(200, before.status, "pre-reset sessions")

        -- Reset
        H.reset_session(handle.port)

        -- Get sessions after reset
        local after = H.http_get("/api/sessions", handle.port)
        H.assert_eq(200, after.status, "post-reset sessions")

        -- Should still have sessions
        H.assert_truthy(#after.body > 2, "should still have sessions after reset")
      end)
    end)

    H.describe("GET /api/status", function()
      H.it("returns system status", function()
        local resp = H.http_get("/api/status", handle.port)
        H.assert_eq(200, resp.status, "status endpoint")
        H.assert_truthy(#resp.body > 10, "status should have content")
      end)
    end)

  end,
})

H.report()
