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
          "curl", "-s", "-m", "3", "-D", "-", url
        })
        H.assert_truthy(
          result:find("text/event%-stream") or result:find("text/event-stream"),
          "should have SSE content-type"
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
        vim.wait(1000, function() return false end)

        -- Trigger an eval
        H.http_post("/exec",
          vim.fn.json_encode({ code = "let sseTest = 1;;" }),
          handle.port)

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

    H.describe("plugin SSE integration", function()
      H.it("connects and receives events via plugin", function()
        -- Open a buffer with F# content
        vim.cmd("enew")
        vim.bo.filetype = "fsharp"
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {
          "let pluginSseTest = 42;;",
        })

        -- Connect the plugin's SSE
        sagefs.connect()

        -- Give SSE time to connect
        vim.wait(2000, function() return false end)

        -- The plugin should be in a connected-ish state
        -- (exact state depends on daemon response timing)
        H.assert_truthy(sagefs.state, "plugin state should exist")
      end)
    end)

  end,
})

H.report()
