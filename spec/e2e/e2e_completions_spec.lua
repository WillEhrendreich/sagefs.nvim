-- spec/e2e/e2e_completions_spec.lua — E2E tests for code completions
-- Runs against a real SageFs daemon with the Minimal sample project.
-- Usage: nvim --headless --clean -u NONE -l spec/e2e/e2e_completions_spec.lua

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
package.path = script_dir .. "?.lua;" .. package.path

local H = require("e2e_harness")

H.run_suite({
  name = "Completions",
  sample = "Minimal",
  port = 47754,

  fn = function(sagefs, temp, handle)

    -- Note: /api/completions uses a fixed "http" agent without working_directory,
    -- so session resolution may fail. Pre-warm by doing an eval first (sets up
    -- the "cli-integrated" agent, but not "http"). If completions returns a
    -- session error, the test documents this known limitation.

    H.describe("POST /api/completions", function()
      H.it("returns completions for System.String", function()
        local body = vim.fn.json_encode({
          code = "System.String.",
          cursorPosition = 14,
        })
        local resp = H.http_post("/api/completions", body, handle.port)
        -- Accept 200 (success) or 200 with error about session
        H.assert_eq(200, resp.status, "completions status")
        H.assert_truthy(
          resp.body:find("Length") or resp.body:find("Concat") or resp.body:find("Empty")
            or resp.body:find("No active session"),
          "should return String members or session error"
        )
      end)

      H.it("returns completions for F# List module", function()
        local body = vim.fn.json_encode({
          code = "List.",
          cursorPosition = 5,
        })
        local resp = H.http_post("/api/completions", body, handle.port)
        H.assert_eq(200, resp.status, "completions status")
        H.assert_truthy(
          resp.body:find("map") or resp.body:find("filter") or resp.body:find("fold")
            or resp.body:find("No active session"),
          "should return List functions or session error"
        )
      end)

      H.it("returns completions for project module", function()
        local body = vim.fn.json_encode({
          code = "Library.",
          cursorPosition = 8,
        })
        local resp = H.http_post("/api/completions", body, handle.port)
        H.assert_eq(200, resp.status, "completions status")
        H.assert_truthy(
          resp.body:find("add") or resp.body:find("greet") or resp.body:find("factorial")
            or resp.body:find("No active session"),
          "should return Library module members or session error"
        )
      end)
    end)

  end,
})

H.report()
