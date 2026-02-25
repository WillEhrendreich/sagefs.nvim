-- spec/e2e/e2e_sse_spec.lua — E2E tests for SSE event streaming
-- Runs against a real SageFs daemon with the Minimal sample project.
-- Usage: nvim --headless --clean -u NONE -l spec/e2e/e2e_sse_spec.lua

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
package.path = script_dir .. "?.lua;" .. package.path

local H = require("e2e_harness")

H.run_suite({
  name = "SSE",
  sample = "Minimal",
  port = 47750,

  fn = function(sagefs, temp, handle)

    H.describe("SSE /events endpoint", function()
      H.it("returns SSE content-type", function()
        -- Use curl with timeout to check headers
        local url = string.format("http://localhost:%d/events", handle.port)
        local result = vim.fn.system({
          "curl", "-s", "-m", "5", "-D", "-", url
        })
        H.assert_truthy(
          result:find("text/event%-stream") or result:find("text/event-stream")
            or result:find("event:") or result:find("data:"),
          "should have SSE content-type or SSE event data"
        )
      end)

      H.it("receives state event after eval", function()
        -- Start a background curl SSE listener with timeout
        local url = string.format("http://localhost:%d/events", handle.port)
        local sse_output = {}
        local sse_job = vim.fn.jobstart({
          "curl", "-s", "-N", "-m", "10", url
        }, {
          on_stdout = function(_, data)
            for _, line in ipairs(data) do
              if line ~= "" then table.insert(sse_output, line) end
            end
          end,
        })

        -- Give SSE connection time to establish
        vim.wait(2000, function() return false end)

        -- Trigger an eval (use H.eval for session resolution)
        H.eval("let sseTest = 1;;", handle.port)

        -- Wait for SSE events
        local got_event = H.wait_for(function()
          for _, line in ipairs(sse_output) do
            if line:find("event:") or line:find("data:") then
              return true
            end
          end
          return false
        end, 10000)

        -- Cleanup SSE listener
        pcall(function() vim.fn.jobstop(sse_job) end)

        H.assert_truthy(got_event, "should receive at least one SSE event after eval")
      end)
    end)

    H.describe("plugin state after setup", function()
      H.it("has plugin state initialized", function()
        -- After setup_plugin(), the plugin state should exist
        H.assert_truthy(sagefs, "plugin module should be loaded")
        -- Check that basic state structures exist
        H.assert_truthy(type(sagefs) == "table", "plugin should be a table module")
      end)
    end)

  end,
})

H.report()
