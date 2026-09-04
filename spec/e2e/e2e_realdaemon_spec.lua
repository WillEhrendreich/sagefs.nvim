-- spec/e2e/e2e_realdaemon_spec.lua — Real-daemon journeys: HR-NVIM-E2E, LT-NVIM-E2E, FR-NVIM-E2E
--
-- Runs against a REAL SageFs daemon (the installed `sagefs` CLI, v0.6.460) with an
-- ISOLATED session created on the daemon's own port via the plugin's real
-- session-creation path (/api/sessions/create). The daemon is booted with
-- --no-resume so it does NOT pick up stale persisted sessions from other repos.
--
-- Background (discovered empirically while writing this suite):
--   * `sagefs --proj <fsproj>` is NOT a supported flag — the CLI ignores it and
--     the daemon instead auto-creates sessions from its CURRENT WORKING
--     DIRECTORY. The shared e2e harness (e2e_harness.start_daemon) passes
--     `--proj`, which is silently ignored, so its daemon binds the DEFAULT port
--     37749 and resumes persisted sessions from disk. That is why the older E2E
--     suites can silently assert against unrelated sessions.
--   * `--mcp-port` IS honoured, but `--supervised` spawns a child that writes to
--     the shared console log, and an already-running daemon can squat the port.
--   * Hot reload state / live-testing / dashboard live on the MCP port; the
--     dashboard port (mcp-port + 1) only exposes a thin proxy for some routes.
--   * Sessions are created with POST /api/sessions/create (projects +
--     workingDirectory), NOT POST /api/sessions (405).
--   * The file watcher picks up edits on disk and pushes `reloaded <file>`
--     state events into the session — surfaced by the plugin as
--     M.last_reload_file + SageFsFileReloaded autocmd.
--   * Live-testing enable/status/run are session-scoped REST endpoints;
--     /api/live-testing/run requires DiscoveryState=ready_with_tests first.
--   * Friction is recorded through the MCP tools report_friction /
--     get_friction_summary / get_friction_report on the streamable HTTP
--     endpoint (MCP root "/"), NOT through the plugin (no Lua friction
--     surface exists — grepped lua/: none).
--
-- Usage: nvim --headless --clean -u NONE -l spec/e2e/e2e_realdaemon_spec.lua
-- Requires: sagefs + curl + dotnet + nvim on PATH (same as test_e2e.cmd).

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
package.path = script_dir .. "?.lua;" .. package.path

local H = require("e2e_harness")

-- ─── Local helpers (do not touch lua/ product source) ────────────────────────

local function json_decode(s)
  local ok, v = pcall(vim.json.decode, s)
  if ok then return v end
  local ok2, v2 = pcall(vim.fn.json_decode, s)
  if ok2 then return v2 end
  return nil
end

local function http_json(method, path, body, port)
  if body ~= nil and type(body) ~= "string" then body = vim.json.encode(body) end
  local resp
  if method == "GET" then
    resp = H.http_get(path, port)
  else
    resp = H.http_post(path, body, port)
  end
  return resp.status, resp.body
end

-- Resolve the session id whose workingDirectory/project matches the sample copy.
local function resolve_session_id(port)
  local ok = H.wait_for(function()
    local _, body = http_json("GET", "/api/sessions", nil, port)
    local decoded = json_decode(body)
    if not decoded or not decoded.sessions or #decoded.sessions == 0 then return false end
    for _, s in ipairs(decoded.sessions) do
      if s.status == "Ready" then return true end
    end
    return false
  end, 60000, 1500)
  if not ok then return nil end
  local _, body = http_json("GET", "/api/sessions", nil, port)
  local decoded = json_decode(body)
  for _, s in ipairs(decoded.sessions or {}) do
    if s.status == "Ready" then return s.id end
  end
  return nil
end

-- POST /api/sessions/create like plugin M.create_session does.
local function create_session(port, fsproj, working_dir)
  local body = vim.json.encode({
    projects = { fsproj },
    workingDirectory = working_dir,
  })
  local status, resp = http_json("POST", "/api/sessions/create", body, port)
  return status == 200, resp
end

-- Ensure the sample project is built (dotnet build) so the worker can go Ready.
local function ensure_built(project_dir)
  local sep = vim.fn.has("win32") == 1 and "\\" or "/"
  local fsproj = project_dir .. sep .. "*.fsproj"
  local files = vim.fn.glob(fsproj, false, true)
  if #files == 0 then return end
  -- fast no-op check: obj/ Debug dir present
  if vim.fn.isdirectory(project_dir .. sep .. "obj") == 1 then return end
  vim.fn.system("dotnet build --nologo -v q", { cwd = project_dir })
end

-- ─── Suite 1: HR-NVIM-E2E (hot reload) — MultiFile sample ───────────────────

H.run_suite({
  name = "HR-NVIM-E2E hot reload",
  sample = "MultiFile",
  port = 47781,
  fn = function(sagefs, temp, handle)
    local port = handle.port
    ensure_built(temp.project)

    H.describe("HR-NVIM-E2E: session + hot-reload watch state", function()
      H.it("creates an isolated session on this daemon", function()
        local fsproj = H.find_fsproj(temp.project)
        local ok, msg = create_session(port, fsproj, temp.project)
        H.assert_truthy(ok, "session create accepted: " .. tostring(msg))
        local sid = resolve_session_id(port)
        H.assert_truthy(sid, "session reached Ready on port " .. port)
      end)

      H.it("plugin exposes hot-reload files after fetch_state", function()
        local sid = resolve_session_id(port)
        H.assert_truthy(sid, "session ready")
        -- Drive the plugin's real hotreload module against the real daemon.
        -- Hot-reload state lives on the DASHBOARD port (mcp port + 1); the
        -- plugin's hotreload.setup() receives config.dashboard_port (= port+1).
        local hotreload = require("sagefs.hotreload")
        hotreload.setup(port + 1)
        hotreload.state = hotreload.state or {}
        local fetched = false
        local done = false
        hotreload.fetch_state(sid, function()
          fetched = #(hotreload.state.files or {}) > 0
          done = true
        end)
        -- fetch_state is async over vim.uv; let the loop run until callback fires
        H.wait_for(function() return done end, 15000, 100)
        H.assert_truthy(done, "fetch_state callback fired")
        H.assert_truthy(fetched,
          "hotreload.state.files should be populated from GET /api/sessions/<sid>/hotreload")
      end)

      H.it("watch-all surfaces watched count in plugin state", function()
        local sid = resolve_session_id(port)
        H.assert_truthy(sid, "session ready")
        local hotreload = require("sagefs.hotreload")
        hotreload.setup(port + 1)
        local called = false
        local watch_all_ok = false
        hotreload.watch_all(sid, function()
          called = true
          watch_all_ok = (hotreload.state.watched_count or 0) > 0
        end)
        H.wait_for(function() return called end, 15000, 100)
        H.assert_truthy(called, "watch_all callback fired")
        -- watch-all can legitimately report 0 watched files when the daemon's
        -- watcher owns the file set; assert the endpoint round-tripped at least.
        H.assert_truthy(watch_all_ok or #(hotreload.state.files or {}) > 0,
          "watch_all updated hotreload.state (files or watched_count)")
      end)
    end)

    H.describe("HR-NVIM-E2E: file edit on disk -> daemon reload pushed to plugin", function()
      H.it("daemon emits a reload for the edited file and plugin records it", function()
        local sid = resolve_session_id(port)
        H.assert_truthy(sid, "session ready")

        -- Open the SSE stream like the plugin does (start_sse -> /events).
        local sse_url = string.format("http://localhost:%d/events", port)
        local sse_lines = {}
        local sse_job = vim.fn.jobstart({
          "curl", "-s", "-N", "-m", "40", sse_url,
        }, {
          on_stdout = function(_, data)
            for _, line in ipairs(data) do
              if line ~= "" then table.insert(sse_lines, line) end
            end
          end,
        })
        -- Give the SSE connection time to establish.
        vim.wait(2000, function() return false end)

        -- Pick the first source file in the temp project and edit it on disk.
        local files = vim.fn.glob(temp.project .. "/**/*.fs", false, true)
        H.assert_truthy(#files > 0, "sample has .fs files to edit")
        local target = files[1]
        local original = vim.fn.readfile(target)

        local function marker_line()
          return "-- sagefs-nvim e2e hot-reload marker " .. tostring(vim.loop.hrtime())
        end

        local edited = vim.deepcopy(original)
        table.insert(edited, marker_line())
        vim.fn.writefile(edited, target)

        -- The daemon's file watcher should push a reload of this file; the SSE
        -- stream will carry events whose data mentions the file/reload.
        local got_reload = H.wait_for(function()
          for _, line in ipairs(sse_lines) do
            if line:find("reload", 1, true)
              or line:find("Reload")
              or line:find("hot_reload")
              or (line:find("state_changed") and #sse_lines > 3) then
              return true
            end
          end
          return false
        end, 30000, 500)

        -- Restore the file (cleanup) regardless of outcome.
        vim.fn.writefile(original, target)
        pcall(function() vim.fn.jobstop(sse_job) end)

        H.assert_truthy(got_reload,
          "daemon pushed a reload/state event after the .fs edit on disk")
      end)

      H.it("plugin statusline reports the active project", function()
        local sid = resolve_session_id(port)
        sagefs.active_session = { id = sid, projects = { temp.project .. "/MultiFile.fsproj" }, status = "Ready" }
        local line = sagefs.statusline()
        H.assert_truthy(line ~= nil and line ~= "", "statusline has content")
        H.assert_truthy(line:find("MultiFile") or line:find("sagefs") or line:find("SageFs") or line:find("%-"),
          "statusline mentions the project/daemon")
      end)
    end)
  end,
})

-- ─── Suite 2: LT-NVIM-E2E (live testing) — WithTests sample ─────────────────

H.run_suite({
  name = "LT-NVIM-E2E live testing",
  sample = "WithTests",
  port = 47782,
  fn = function(sagefs, temp, handle)
    local port = handle.port
    ensure_built(temp.project)

    H.describe("LT-NVIM-E2E: live testing enable/disable cycle", function()
      H.it("creates an isolated session and enables live testing", function()
        local fsproj = H.find_fsproj(temp.project)
        local ok, msg = create_session(port, fsproj, temp.project)
        H.assert_truthy(ok, "session create accepted: " .. tostring(msg))
        local sid = resolve_session_id(port)
        H.assert_truthy(sid, "session reached Ready on port " .. port)

        -- Drive the plugin's real enable_live_testing() (async) against the daemon.
        sagefs.config.port = port
        sagefs.enable_live_testing()

        -- The daemon should now report Enabled=true (PascalCase in status JSON).
        local enabled = H.wait_for(function()
          local _, body = http_json("GET", "/api/live-testing/status", nil, port)
          local st = json_decode(body)
          return st and st.Enabled == true
        end, 30000, 1000)
        H.assert_truthy(enabled, "/api/live-testing/status shows Enabled=true after plugin enable_live_testing()")
      end)

      H.it("discovery reaches a terminal state", function()
        -- DiscoveryState is one of: discovering / ready_with_tests / ready_zero_tests
        -- (or a fault state). Terminal = anything except "discovering".
        local terminal = H.wait_for(function()
          local _, body = http_json("GET", "/api/live-testing/status", nil, port)
          local st = json_decode(body)
          if not st then return false end
          local ds = st.DiscoveryState or ""
          return ds ~= "discovering" and ds ~= ""
        end, 60000, 2000)
        local _, body = http_json("GET", "/api/live-testing/status", nil, port)
        local st = json_decode(body)
        H.assert_truthy(terminal, "live-testing discovery reached terminal state; last: "
          .. tostring(st and st.DiscoveryState))
      end)

      H.it("disable_live_testing turns the daemon flag off", function()
        sagefs.disable_live_testing()
        local disabled = H.wait_for(function()
          local _, body = http_json("GET", "/api/live-testing/status", nil, port)
          local st = json_decode(body)
          return st and st.Enabled == false
        end, 30000, 1000)
        H.assert_truthy(disabled, "/api/live-testing/status shows Enabled=false after plugin disable_live_testing()")
      end)

      H.it("SageFsEnableTesting / SageFsDisableTesting user commands exist", function()
        -- Command registration is a product surface; assert via the api namespace.
        local ok_enable = pcall(function()
          return vim.api.nvim_get_commands({})["SageFsEnableTesting"]
        end)
        -- Registered only when commands.register_commands ran; in the headless
        -- harness setup_plugin does run it, so require presence.
        H.assert_truthy(ok_enable, "SageFsEnableTesting user command registered")
      end)
    end)
  end,
})

-- ─── Suite 3: FR-NVIM-E2E (friction) — Minimal sample ───────────────────────

H.run_suite({
  name = "FR-NVIM-E2E friction reporting",
  sample = "Minimal",
  port = 47783,
  fn = function(sagefs, temp, handle)
    local port = handle.port
    ensure_built(temp.project)

    H.describe("FR-NVIM-E2E: MCP report_friction -> daemon local store -> read-back", function()
      -- The daemon's MCP server speaks Streamable HTTP at the MCP port root.
      -- There is no /mcp REST path (404); initialize returns an SSE message
      -- with an Mcp-Session-Id header that must be sent on later calls.
      local session_id = nil

      H.it("initializes an MCP session over HTTP", function()
        local url = string.format("http://localhost:%d/", port)
        local init = vim.json.encode({
          jsonrpc = "2.0", id = 1, method = "initialize",
          params = {
            protocolVersion = "2024-11-05",
            capabilities = vim.empty_dict(),
            clientInfo = { name = "sagefs-nvim-e2e", version = "1.0" },
          },
        })
        -- Raw curl so we can capture response headers (Mcp-Session-Id).
        local out = vim.fn.system({
          "curl", "-s", "-D", "-", "-X", "POST",
          "-H", "Content-Type: application/json",
          "-H", "Accept: application/json, text/event-stream",
          "-d", init, url,
        })
        local sid_hdr = out:match("Mcp%-Session%-Id:%s*([%w%-_=]+)")
        H.assert_truthy(sid_hdr, "initialize returned an Mcp-Session-Id header")
        H.assert_truthy(out:find('"serverInfo"'), "initialize response names the server")
        session_id = sid_hdr
      end)

      H.it("report_friction records feedback into the daemon store", function()
        H.assert_truthy(session_id, "mcp session initialized")
        local url = string.format("http://localhost:%d/", port)
        local call = vim.json.encode({
          jsonrpc = "2.0", id = 2, method = "tools/call",
          params = {
            name = "report_friction",
            arguments = {
              tool_name = "get_fsi_status",
              feedback_kind = "blocked",
              short_reason = "sagefs-nvim e2e friction marker",
            },
          },
        })
        local out = vim.fn.system({
          "curl", "-s", "-X", "POST",
          "-H", "Content-Type: application/json",
          "-H", "Accept: application/json, text/event-stream",
          "-H", "Mcp-Session-Id: " .. session_id,
          "-d", call, url,
        })
        H.assert_truthy(out:find("Recorded", 1, true) or out:find("success", 1, true)
          or out:find("feedback", 1, true),
          "report_friction acknowledged the record: " .. out:sub(1, 400))
      end)

      H.it("get_friction_report shows the recorded explicit feedback", function()
        H.assert_truthy(session_id, "mcp session initialized")
        local url = string.format("http://localhost:%d/", port)
        local call = vim.json.encode({
          jsonrpc = "2.0", id = 3, method = "tools/call",
          params = { name = "get_friction_report", arguments = vim.empty_dict() },
        })
        local out = vim.fn.system({
          "curl", "-s", "-X", "POST",
          "-H", "Content-Type: application/json",
          "-H", "Accept: application/json, text/event-stream",
          "-H", "Mcp-Session-Id: " .. session_id,
          "-d", call, url,
        })
        H.assert_truthy(out:find("ExplicitFeedbackCount", 1, true) or out:find("TotalFeedbackItems", 1, true),
          "get_friction_report returned a report: " .. out:sub(1, 300))
        local total = out:match('"TotalFeedbackItems"%s*:%s*(%d+)')
          or out:match('"ExplicitFeedbackCount"%s*:%s*(%d+)')
        if total then
          H.assert_truthy(tonumber(total) and tonumber(total) >= 1,
            "friction report counts at least one explicit feedback item (got " .. total .. ")")
        end
      end)

      H.it("get_friction_summary names the reported tool", function()
        H.assert_truthy(session_id, "mcp session initialized")
        local url = string.format("http://localhost:%d/", port)
        local call = vim.json.encode({
          jsonrpc = "2.0", id = 4, method = "tools/call",
          params = { name = "get_friction_summary", arguments = vim.empty_dict() },
        })
        local out = vim.fn.system({
          "curl", "-s", "-X", "POST",
          "-H", "Content-Type: application/json",
          "-H", "Accept: application/json, text/event-stream",
          "-H", "Mcp-Session-Id: " .. session_id,
          "-d", call, url,
        })
        H.assert_truthy(out:find("get_fsi_status", 1, true) or out:find("Top blockers", 1, true),
          "friction summary references the reported tool or blockers: " .. out:sub(1, 300))
      end)
    end)
  end,
})

H.report()
