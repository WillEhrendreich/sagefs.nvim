-- spec/e2e/e2e_testing_spec.lua — E2E tests for live testing pipeline
-- Runs against a real SageFs daemon with the WithTests sample project.
-- Usage: nvim --headless --clean -u NONE -l spec/e2e/e2e_testing_spec.lua

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
package.path = script_dir .. "?.lua;" .. package.path

local H = require("e2e_harness")

H.run_suite({
  name = "Live Testing",
  sample = "WithTests",
  port = 47752,

  fn = function(sagefs, temp, handle)

    H.describe("live testing toggle", function()
      H.it("toggles live testing via HTTP", function()
        local resp = H.http_post("/api/live-testing/toggle", nil, handle.port)
        H.assert_eq(200, resp.status, "toggle status")
      end)
    end)

    H.describe("test execution", function()
      H.it("runs tests and returns results", function()
        -- Ensure live testing is enabled
        H.http_post("/api/live-testing/toggle", nil, handle.port)
        vim.wait(2000, function() return false end)

        -- Trigger test run
        local resp = H.http_post("/api/live-testing/run", nil, handle.port)
        H.assert_eq(200, resp.status, "run tests status")

        -- Wait for tests to complete
        vim.wait(10000, function() return false end)

        -- Check test status
        local status = H.http_get("/api/live-testing/status", handle.port)
        H.assert_eq(200, status.status, "test status endpoint")
        H.assert_truthy(#status.body > 10, "test status should have content")
      end)
    end)

    H.describe("test policy", function()
      H.it("sets run policy for a category", function()
        local body = vim.fn.json_encode({
          category = "unit",
          policy = "demand",
        })
        local resp = H.http_post("/api/live-testing/policy", body, handle.port)
        H.assert_eq(200, resp.status, "policy status")
      end)
    end)

    H.describe("test status SSE events", function()
      H.it("receives test_summary event after test run", function()
        -- Start SSE listener
        local url = string.format("http://localhost:%d/events", handle.port)
        local sse_output = {}
        local sse_job = vim.fn.jobstart({
          "curl", "-s", "-N", "-m", "20", url
        }, {
          on_stdout = function(_, data)
            for _, line in ipairs(data) do
              if line ~= "" then table.insert(sse_output, line) end
            end
          end,
        })

        vim.wait(1000, function() return false end)

        -- Trigger test run
        H.http_post("/api/live-testing/run", nil, handle.port)

        -- Wait for test-related SSE events
        local got_test_event = H.wait_for(function()
          for _, line in ipairs(sse_output) do
            if line:find("test_summary") or line:find("test_results") then
              return true
            end
          end
          return false
        end, 15000)

        pcall(function() vim.fn.jobstop(sse_job) end)

        H.assert_truthy(got_test_event,
          "should receive test_summary or test_results SSE event after test run")
      end)
    end)

  end,
})

H.report()
