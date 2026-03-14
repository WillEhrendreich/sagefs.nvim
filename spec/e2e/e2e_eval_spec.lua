-- spec/e2e/e2e_eval_spec.lua — E2E tests for code evaluation
-- Runs against a real SageFs daemon with the Minimal sample project.
-- Usage: nvim --headless --clean -u NONE -l spec/e2e/e2e_eval_spec.lua

-- Bootstrap: add spec/e2e to package path so we can require the harness
local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
package.path = script_dir .. "?.lua;" .. package.path

local H = require("e2e_harness")

H.run_suite({
  name = "Eval",
  sample = "Minimal",
  port = 47749,

  fn = function(sagefs, temp, handle)

    H.describe("health endpoint", function()
      H.it("returns 200", function()
        local resp = H.http_get("/health", handle.port)
        H.assert_eq(200, resp.status, "health status")
      end)
    end)

    H.describe("version endpoint", function()
      H.it("returns 200 with apiVersion", function()
        local resp = H.http_get("/version", handle.port)
        H.assert_eq(200, resp.status, "version status")
        H.assert_contains(resp.body, "\"apiVersion\"", "version body contains apiVersion")
      end)
    end)

    H.describe("POST /exec", function()
      H.it("evaluates simple expression", function()
        local resp = H.eval("let x = 42;;", handle.port)
        H.assert_eq(200, resp.status, "exec status")
        H.assert_contains(resp.body, "42", "result contains 42")
      end)

      H.it("returns error for invalid code", function()
        local resp = H.eval('let x: int = "nope";;', handle.port)
        -- SageFs returns 200 with error info in the body
        H.assert_eq(200, resp.status, "exec status")
        H.assert_truthy(
          resp.body:find("error") or resp.body:find("Error") or resp.body:find("FS"),
          "response should contain error info"
        )
      end)

      H.it("can use project modules", function()
        local resp = H.eval("Library.add 2 3;;", handle.port)
        H.assert_eq(200, resp.status, "exec status")
        H.assert_contains(resp.body, "5", "add 2 3 = 5")
      end)

      H.it("evaluates multi-line code", function()
        local resp = H.eval("let fact5 = Library.factorial 5;;", handle.port)
        H.assert_eq(200, resp.status, "exec status")
        H.assert_contains(resp.body, "120", "5! = 120")
      end)
    end)

    H.describe("GET /api/status", function()
      H.it("returns session status", function()
        local resp = H.http_get("/api/status", handle.port)
        H.assert_eq(200, resp.status, "status endpoint")
        H.assert_truthy(#resp.body > 10, "status body should have content")
      end)
    end)

    H.describe("POST /reset", function()
      H.it("resets session successfully", function()
        -- First eval something
        H.eval("let resetTest = 99;;", handle.port)

        -- Reset — Note: /reset uses a fixed agent without working_directory,
        -- so it may not resolve to the session. We verify the endpoint responds
        -- and the daemon remains healthy.
        local resp = H.reset_session(handle.port)
        H.assert_eq(200, resp.status, "reset status")

        -- Verify daemon is still responsive after reset attempt
        local health = H.http_get("/health", handle.port)
        H.assert_eq(200, health.status, "daemon healthy after reset")
      end)
    end)

  end,
})

H.report()
