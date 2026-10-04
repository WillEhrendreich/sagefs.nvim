-- spec/e2e/e2e_reload_display_spec.lua: what the plugin SHOWS for each verdict a
-- save to a running app gets, against a real daemon and a real app.
--
-- The pure folds and the captured wire have their own specs. What none of them
-- can show is the plugin, in a real Neovim, following a real run_app app through
-- the sequence a user sees:
--
--   save a function the app calls      compiling -> "applied, not run yet" -> "patched (ran)"
--   save a function nothing calls      compiling -> "applied, not run yet" -> "applied, never ran"
--                                      (after the daemon's ten second bound), naming the function
--
-- Usage: nvim --headless --clean -u NONE -l spec/e2e/e2e_reload_display_spec.lua
-- Isolation: its own daemon, its own SAGEFS_DATA_DIR, owned by this Neovim (see
-- daemon_launch.lua). Requires sagefs, dotnet, curl and nvim on PATH.

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
package.path = script_dir .. "?.lua;" .. package.path

local H = require("e2e_harness")

local function json_decode(s)
  local ok, v = pcall(vim.json.decode, s)
  if ok then return v end
  return nil
end

--- Wait until `predicate()` is truthy, letting Neovim's event loop run.
local function wait(predicate, ms)
  return vim.wait(ms or 30000, predicate, 100)
end

local function session_row(port, sid)
  local r = H.http_get("/api/sessions", port)
  local data = json_decode(r.body)
  for _, s in ipairs(data and data.sessions or {}) do
    if s.id == sid then return s end
  end
  return nil
end

--- Replace `from` with `to` in a file on disk, the way a save from another editor would.
local function save_edit(path, from, to)
  local lines = vim.fn.readfile(path)
  local changed = false
  for i, l in ipairs(lines) do
    local new, n = l:gsub(from, to)
    if n > 0 then lines[i] = new; changed = true end
  end
  H.assert_truthy(changed, "the fixture has '" .. from .. "' to replace")
  vim.fn.writefile(lines, path)
end

H.run_suite({
  name = "Reload display: pending, patched and never entered",
  sample = "HotReloadLoop",
  port = 47801,
  warmup = false,
  fn = function(sagefs, temp, handle)
    local port = handle.port
    local logic = temp.project .. "/Logic.fs"
    local sid

    H.describe("a hot reload session running the app", function()
      H.it("the daemon creates a hot reload session for the fixture", function()
        local fsproj = H.find_fsproj(temp.project)
        local r = H.http_post("/api/sessions/create", vim.json.encode({
          projects = { fsproj }, workingDirectory = temp.project, workflow = "hotreload",
        }), port)
        H.assert_eq(200, r.status, "create status: " .. r.body)
        sid = json_decode(r.body).message
        H.assert_truthy(sid and #sid == 8, "a session id came back: " .. tostring(sid))
        local ready = wait(function()
          local row = session_row(port, sid)
          return row and row.status == "Ready"
        end, 120000)
        H.assert_truthy(ready, "the session reached Ready")
      end)

      H.it("run-app starts the app, and the plugin follows the session", function()
        local r = H.http_post("/api/sessions/" .. sid .. "/run-app", "{}", port)
        H.assert_eq(200, r.status, "run-app status: " .. r.body)
        local running = wait(function()
          local row = session_row(port, sid)
          return row and row.app and row.app.state == "Running"
        end, 120000)
        H.assert_truthy(running, "the app is Running")

        sagefs.config.port = port
        sagefs.start_sse()
        local listed = false
        sagefs.list_sessions(function() listed = true end)
        H.assert_truthy(wait(function() return listed end, 15000), "the plugin read the session list")
        for _, s in ipairs(sagefs.session_list) do
          if s.id == sid then sagefs.active_session = s end
        end
        H.assert_truthy(sagefs.active_session and sagefs.active_session.id == sid, "the plugin has the session active")
        vim.cmd("edit " .. vim.fn.fnameescape(logic))
        vim.wait(1500, function() return false end)
      end)
    end)

    H.describe("a save to a function the app calls", function()
      H.it("shows applied-not-run-yet and then patched, never a stale label", function()
        local seen = {}
        local function note()
          -- The HR segment, cut at the next " │ ". Plain finds: the icon and the bar
          -- are multibyte, and a Lua character class works on bytes.
          local sl = sagefs.statusline()
          local from = sl:find("HR ", 1, true)
          if from then
            local rest = sl:sub(from)
            local to = rest:find(" │ ", 1, true)
            local what = to and rest:sub(1, to - 1) or rest
            if seen[#seen] ~= what then table.insert(seen, what) end
          end
        end
        local before = sagefs.statusline()
        save_edit(logic, "hello v1", "hello v2")
        local done = wait(function()
          note()
          return sagefs.statusline():find("patched (ran)", 1, true) ~= nil
        end, 40000)
        H.assert_truthy(done, "the statusline reached 'patched (ran)'; it showed: " .. table.concat(seen, " -> "))
        local joined = table.concat(seen, " -> ")
        H.assert_truthy(joined:find("applied, not run yet", 1, true) or joined:find("compiling", 1, true),
          "it did not jump straight to patched: " .. joined .. " (before the save: " .. before .. ")")
        H.assert_falsy(joined:find("never ran", 1, true), "a call that happens is not 'never ran': " .. joined)
      end)

      H.it(":SageFsReloadStatus says patched, by metadata delta", function()
        local lines = sagefs.wire_runtime().report_lines()
        local text = {}
        for _, l in ipairs(lines) do table.insert(text, l.text) end
        local joined = table.concat(text, "\n")
        H.assert_contains(joined, "patched (ran)", "the panel's first line")
        H.assert_contains(joined, "via metadata delta", "the mechanism")
      end)
    end)

    H.describe("a save to a function nothing calls", function()
      H.it("goes to applied-never-ran, and says which function", function()
        local seen_pending = false
        save_edit(logic, "unused v1", "unused v2")
        -- The daemon waits ten seconds (SAGEFS_PATCH_CONFIRM_SECONDS) before it says never entered.
        local done = wait(function()
          local sl = sagefs.statusline()
          if sl:find("applied, not run yet", 1, true) then seen_pending = true end
          return sl:find("applied, never ran", 1, true) ~= nil
        end, 45000)
        H.assert_truthy(done, "the statusline reached 'applied, never ran': " .. sagefs.statusline())
        H.assert_truthy(seen_pending, "it passed through 'applied, not run yet' on the way")
      end)

      H.it("the panel names Logic.neverCalled in the daemon's words", function()
        local text = {}
        for _, l in ipairs(sagefs.wire_runtime().report_lines()) do table.insert(text, l.text) end
        H.assert_contains(table.concat(text, "\n"), "Logic.neverCalled", "the function that did not run")
      end)

      H.it("the first line of the saved file carries the verdict as virtual text", function()
        local ns = vim.api.nvim_create_namespace("sagefs_reload")
        local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
        H.assert_truthy(#marks > 0, "a mark is drawn")
        local vt = marks[1][4].virt_text[1][1]
        H.assert_contains(vt, "never ran", "the mark says what happened")
      end)
    end)
  end,
})

H.report()
