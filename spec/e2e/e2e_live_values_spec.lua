-- spec/e2e/e2e_live_values_spec.lua: the live bindings pane, Safe mode and the
-- click to run one getter, and :SageFsWorkflow, against a real daemon.
--
-- Run as the user would: a bare session, an eval that defines a class with getters,
-- :SageFsBindings, <CR> on a held getter, m to change the mode, and
-- :SageFsWorkflow to move the session to Hot Reload.
--
-- Usage: nvim --headless --clean -u NONE -l spec/e2e/e2e_live_values_spec.lua
-- Isolation: its own daemon and SAGEFS_DATA_DIR, owned by this Neovim (daemon_launch.lua).

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
package.path = script_dir .. "?.lua;" .. package.path

local H = require("e2e_harness")

local function json_decode(s)
  local ok, v = pcall(vim.json.decode, s)
  if ok then return v end
  return nil
end

local function wait(predicate, ms)
  return vim.wait(ms or 30000, predicate, 100)
end

local function session_row(port, sid)
  local data = json_decode(H.http_get("/api/sessions", port).body)
  for _, s in ipairs(data and data.sessions or {}) do
    if s.id == sid then return s end
  end
  return nil
end

local function pane_text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

local function goto_line(needle)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l:find(needle, 1, true) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return true
    end
  end
  return false
end

local CLASS = table.concat({
  "type Box(n:int) =",
  "  member _.Size = n",
  "  member _.RunsCode = System.String.Join(\",\", [n; n+1])",
  "  member _.Boom : int = failwith \"kaput\"",
  "",
  "let box = Box(7);;",
}, "\n")

H.run_suite({
  name = "Live values pane and workflow switch",
  sample = "Minimal",
  port = 47811,
  warmup = false,
  fn = function(sagefs, temp, handle)
    local port = handle.port
    local sid

    H.describe("a bare session with a class bound in it", function()
      H.it("the daemon creates a bare session and it reaches Ready", function()
        local r = H.http_post("/api/sessions/create", vim.json.encode({
          projects = vim.empty_dict(), workingDirectory = temp.project,
        }), port)
        H.assert_eq(200, r.status, "create status: " .. r.body)
        sid = json_decode(r.body).message
        H.assert_truthy(wait(function()
          local row = session_row(port, sid)
          return row and row.status == "Ready"
        end, 120000), "the session reached Ready")
      end)

      H.it("the plugin follows the session and the eval binds the class", function()
        sagefs.config.port = port
        sagefs.start_sse()
        local listed = false
        sagefs.list_sessions(function() listed = true end)
        H.assert_truthy(wait(function() return listed end, 15000), "session list read")
        for _, s in ipairs(sagefs.session_list) do
          if s.id == sid then sagefs.active_session = s end
        end
        H.assert_truthy(sagefs.active_session and sagefs.active_session.id == sid, "session active")
        local r = H.eval(CLASS, port)
        H.assert_eq(200, r.status, "eval status: " .. r.body)
        H.assert_contains(r.body, "val box", "the binding exists")
      end)
    end)

    H.describe(":SageFsBindings in Safe mode", function()
      H.it("lists the held getters and says they run only on a click", function()
        vim.cmd("SageFsBindings")
        H.assert_truthy(wait(function() return pane_text():find("RunsCode : String", 1, true) ~= nil end, 15000),
          "the tree arrived: " .. pane_text())
        H.assert_contains(pane_text(), "mode Safe", "the header says Safe")
        H.assert_contains(pane_text(), "[<CR> run]", "a held getter offers the click")
      end)

      H.it("<CR> on RunsCode runs that one getter and shows its value and the containment line", function()
        H.assert_truthy(goto_line("RunsCode : String"), "the RunsCode row is there")
        vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
        -- The new tree arrives on the event stream and the answer to the click on
        -- the HTTP reply, in either order: wait for both, and for the running line to go.
        H.assert_truthy(wait(function()
          local t = pane_text()
          return t:find('RunsCode : String  = "7,8"', 1, true) ~= nil
            and t:find("ran under a syscall filter", 1, true) ~= nil
            and t:find("running box.", 1, true) == nil
        end, 20000), "the value, the containment line and no running line: " .. pane_text())
      end)

      H.it("a getter that throws shows unknown and the reason, never an empty row", function()
        H.assert_truthy(goto_line("Boom : Int32"), "the Boom row is there")
        vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
        H.assert_truthy(wait(function() return pane_text():find("unknown (not evaluated: the getter threw: kaput)", 1, true) ~= nil end, 20000),
          "the throw is the answer: " .. pane_text())
      end)

      H.it("the cursor is still on the row it was on after the lines above changed", function()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
        H.assert_contains(line, "Boom", "the cursor stayed on Boom")
      end)

      H.it("m switches to Off, and the header says so", function()
        local original = vim.ui.select
        vim.ui.select = function(items, _, cb)
          for i, item in ipairs(items) do
            if item == "Off" then cb(item, i) return end
          end
          cb(nil, nil)
        end
        vim.api.nvim_feedkeys("m", "x", false)
        vim.ui.select = original
        H.assert_truthy(wait(function() return pane_text():find("mode Off", 1, true) ~= nil end, 20000),
          "the header shows Off: " .. pane_text())
      end)

      H.it("and back to Safe", function()
        local original = vim.ui.select
        vim.ui.select = function(items, _, cb)
          for i, item in ipairs(items) do
            if item == "Safe" then cb(item, i) return end
          end
          cb(nil, nil)
        end
        vim.api.nvim_feedkeys("m", "x", false)
        vim.ui.select = original
        H.assert_truthy(wait(function() return pane_text():find("mode Safe", 1, true) ~= nil end, 20000),
          "the header shows Safe: " .. pane_text())
        vim.cmd("close")
      end)
    end)

    H.describe(":SageFsWorkflow", function()
      H.it("an unknown name comes back in the daemon's words and the session is untouched", function()
        local notes = {}
        local original = vim.notify
        vim.notify = function(m) table.insert(notes, m) end
        vim.cmd("SageFsWorkflow bogus")
        local got = wait(function()
          for _, n in ipairs(notes) do if n:find("Valid values", 1, true) then return true end end
          return false
        end, 15000)
        vim.notify = original
        H.assert_truthy(got, "the refusal names the valid values: " .. table.concat(notes, " | "))
        local row = session_row(port, sid)
        H.assert_eq("Ready", row.status, "the session was not restarted")
      end)

      H.it("hotreload restarts the session in place, and the statusline names Hot Reload", function()
        vim.cmd("SageFsWorkflow hotreload")
        local done = wait(function()
          local row = session_row(port, sid)
          return row and row.status == "Ready" and row.workflowLabel == "Hot Reload"
        end, 90000)
        H.assert_truthy(done, "the daemon reports the session Ready as Hot Reload")
        -- the plugin reads the session list again after an accepted switch
        local ok = wait(function() return sagefs.statusline():find("[Hot Reload]", 1, true) ~= nil end, 15000)
        H.assert_truthy(ok, "statusline: " .. sagefs.statusline())
      end)

      H.it("the session id the plugin holds is still the session", function()
        H.assert_eq(sid, sagefs.active_session.id, "same id after the in-place restart")
      end)
    end)
  end,
})

H.report()
