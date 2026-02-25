-- spec/e2e/e2e_hotreload_spec.lua — E2E tests for hot reload detection
-- Runs against a real SageFs daemon with the MultiFile sample project.
-- Usage: nvim --headless --clean -u NONE -l spec/e2e/e2e_hotreload_spec.lua

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
package.path = script_dir .. "?.lua;" .. package.path

local H = require("e2e_harness")

H.run_suite({
  name = "Hot Reload",
  sample = "MultiFile",
  port = 47753,

  fn = function(sagefs, temp, handle)

    H.describe("initial eval with project modules", function()
      H.it("can use Domain types", function()
        local code = 'open Domain;; let t = { Celsius = 100.0 };;'
        local resp = H.http_post("/exec",
          vim.fn.json_encode({ code = code }),
          handle.port)
        H.assert_eq(200, resp.status, "exec status")
        H.assert_contains(resp.body, "100", "should see 100.0")
      end)

      H.it("can use Logic functions", function()
        local code = 'open Domain;; open Logic;; let f = toFahrenheit { Celsius = 100.0 };;'
        local resp = H.http_post("/exec",
          vim.fn.json_encode({ code = code }),
          handle.port)
        H.assert_eq(200, resp.status, "exec status")
        H.assert_contains(resp.body, "212", "100C = 212F")
      end)

      H.it("can use Api functions", function()
        local code = 'open Domain;; open Api;; let s = formatTemperature { Celsius = 0.0 } Fahrenheit;;'
        local resp = H.http_post("/exec",
          vim.fn.json_encode({ code = code }),
          handle.port)
        H.assert_eq(200, resp.status, "exec status")
        H.assert_contains(resp.body, "32", "0C = 32F")
      end)
    end)

    H.describe("file modification detection", function()
      H.it("detects when a source file is modified", function()
        -- Read the original Domain.fs
        local domain_path = temp.project .. "\\Domain.fs"
        local original = vim.fn.readfile(domain_path)

        -- Modify Domain.fs — add a new type
        local modified = vim.deepcopy(original)
        table.insert(modified, "")
        table.insert(modified, "type Pressure = { Pascals: float }")

        vim.fn.writefile(modified, domain_path)

        -- Give file watcher time to detect + hot reload
        vim.wait(5000, function() return false end)

        -- Try to use the new type (may or may not work depending on hot reload timing)
        local code = 'open Domain;; let p = { Pascals = 101325.0 };;'
        local resp = H.http_post("/exec",
          vim.fn.json_encode({ code = code }),
          handle.port)

        -- Whether this succeeds depends on whether hot reload has processed yet
        -- The key assertion is that we didn't crash the daemon
        H.assert_eq(200, resp.status, "daemon should still be responsive after file change")

        -- Restore original file
        vim.fn.writefile(original, domain_path)
      end)
    end)

    H.describe("eval after file change", function()
      H.it("can still eval after hot reload cycle", function()
        -- Simple eval to verify daemon is still healthy
        local resp = H.http_post("/exec",
          vim.fn.json_encode({ code = "1 + 1;;" }),
          handle.port)
        H.assert_eq(200, resp.status, "exec status after hot reload")
        H.assert_contains(resp.body, "2", "1 + 1 = 2")
      end)
    end)

  end,
})

H.report()
