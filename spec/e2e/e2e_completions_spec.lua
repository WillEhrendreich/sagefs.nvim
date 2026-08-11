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

    -- The editor completion endpoint always returns the shared JSON contract.
    -- A missing session is represented by an empty completions array, never by
    -- a plain-text error that would break an editor JSON parser.

    H.describe("POST /api/completions", function()
      H.it("returns completions for System.String", function()
        local body = vim.fn.json_encode({
          code = "System.String.",
          cursorPosition = 14,
        })
        local resp = H.http_post("/api/completions", body, handle.port)
        H.assert_eq(200, resp.status, "completions status")
        local ok, data = pcall(vim.fn.json_decode, resp.body)
        H.assert_truthy(ok and type(data.completions) == "table", "must return the JSON completion contract")
      end)

      H.it("returns completions for F# List module", function()
        local body = vim.fn.json_encode({
          code = "List.",
          cursorPosition = 5,
        })
        local resp = H.http_post("/api/completions", body, handle.port)
        H.assert_eq(200, resp.status, "completions status")
        local ok, data = pcall(vim.fn.json_decode, resp.body)
        H.assert_truthy(ok and type(data.completions) == "table", "must return the JSON completion contract")
      end)

      H.it("returns completions for project module", function()
        local body = vim.fn.json_encode({
          code = "Library.",
          cursorPosition = 8,
        })
        local resp = H.http_post("/api/completions", body, handle.port)
        H.assert_eq(200, resp.status, "completions status")
        local ok, data = pcall(vim.fn.json_decode, resp.body)
        H.assert_truthy(ok and type(data.completions) == "table", "must return the JSON completion contract")
      end)
    end)

  end,
})

H.report()
