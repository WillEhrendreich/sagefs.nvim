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

    H.describe("POST /api/completions", function()
      H.it("returns completions for System.String", function()
        local body = vim.fn.json_encode({
          code = "System.String.",
          cursor_position = 14,
        })
        local resp = H.http_post("/api/completions", body, handle.port)
        H.assert_eq(200, resp.status, "completions status")
        -- Should contain common string members
        H.assert_truthy(
          resp.body:find("Length") or resp.body:find("Concat") or resp.body:find("Empty"),
          "should return String members"
        )
      end)

      H.it("returns completions for F# List module", function()
        local body = vim.fn.json_encode({
          code = "List.",
          cursor_position = 5,
        })
        local resp = H.http_post("/api/completions", body, handle.port)
        H.assert_eq(200, resp.status, "completions status")
        H.assert_truthy(
          resp.body:find("map") or resp.body:find("filter") or resp.body:find("fold"),
          "should return List functions"
        )
      end)

      H.it("returns completions for project module", function()
        local body = vim.fn.json_encode({
          code = "Library.",
          cursor_position = 8,
        })
        local resp = H.http_post("/api/completions", body, handle.port)
        H.assert_eq(200, resp.status, "completions status")
        H.assert_truthy(
          resp.body:find("add") or resp.body:find("greet") or resp.body:find("factorial"),
          "should return Library module members"
        )
      end)
    end)

  end,
})

H.report()
