-- spec/e2e/e2e_debug_spec.lua — E2E: debug a failing test from Neovim, real everything
--
-- A REAL daemon (its own port, its own SAGEFS_DATA_DIR, --no-resume, owned by this
-- Neovim), a REAL isolated session on the WithTests sample, REAL nvim-dap and a
-- REAL netcoredbg attaching to the real test host. Nothing is faked: the daemon
-- holds the failing test, the plugin attaches the debugger and releases it, the
-- test runs under the debugger and the daemon answers with the verdict.
--
-- Needs, besides what the other e2e suites need: nvim-dap on the runtimepath
-- (SAGEFS_E2E_NVIM_DAP, default ~/.local/share/nvim/lazy/nvim-dap) and netcoredbg
-- (on PATH, or SAGEFS_E2E_NETCOREDBG). Without either the suite says it was
-- SKIPPED and why, and exits 0: a machine without a debugger has nothing to
-- check here, and that is said, not hidden.
--
-- Usage: nvim --headless --clean -u NONE -l spec/e2e/e2e_debug_spec.lua

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
package.path = script_dir .. "?.lua;" .. package.path

local H = require("e2e_harness")

local home = os.getenv("HOME") or ""
local dap_dir = os.getenv("SAGEFS_E2E_NVIM_DAP") or (home .. "/.local/share/nvim/lazy/nvim-dap")
local netcoredbg = os.getenv("SAGEFS_E2E_NETCOREDBG")
if not netcoredbg or netcoredbg == "" then
  netcoredbg = vim.fn.exepath("netcoredbg")
end

if vim.fn.isdirectory(dap_dir) ~= 1 or netcoredbg == "" then
  io.write("\n=== E2E Suite: Debug a failing test ===\n")
  io.write("  SKIPPED: needs nvim-dap (" .. dap_dir .. ") and netcoredbg on PATH or in SAGEFS_E2E_NETCOREDBG\n")
  vim.cmd("cquit 0")
end

vim.opt.rtp:prepend(dap_dir)

local function json_decode(s)
  local ok, v = pcall(vim.json.decode, s)
  if ok then return v end
  return nil
end

local function post(path, body, port)
  local resp = H.http_post(path, type(body) == "string" and body or vim.json.encode(body), port)
  return resp.status, json_decode(resp.body), resp.body
end

local function get(path, port)
  local resp = H.http_get(path, port)
  return resp.status, json_decode(resp.body), resp.body
end

H.run_suite({
  name = "Debug a failing test (real daemon, nvim-dap, netcoredbg)",
  sample = "WithTests",
  port = 47791,
  warmup = false,
  fn = function(sagefs, temp, handle)
    local port = handle.port
    local notes = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level) table.insert(notes, { msg = tostring(msg), level = level }); end

    local function said(fragment)
      for _, n in ipairs(notes) do
        if n.msg:find(fragment, 1, true) then return n end
      end
      return nil
    end

    -- A debug build, so there is a PDB for netcoredbg to bind in.
    vim.system({ "dotnet", "build", "--nologo", "-v", "q", "-c", "Debug" }, { cwd = temp.project }):wait()

    local sid
    H.describe("a failing test in a real session", function()
      H.it("creates the session and it reaches Ready", function()
        local fsproj = H.find_fsproj(temp.project)
        local status, _, raw = post("/api/sessions/create", {
          projectSelection = "these", projects = { fsproj }, workingDirectory = temp.project,
        }, port)
        H.assert_eq(200, status, "create: " .. tostring(raw))
        H.assert_truthy(H.wait_for(function()
          local _, decoded = get("/api/sessions", port)
          for _, s in ipairs(decoded and decoded.sessions or {}) do
            if s.status == "Ready" then sid = s.id; return true end
          end
          return false
        end, 120000, 1500), "the session reached Ready")
        sagefs.active_session = { id = sid, working_directory = temp.project }
      end)

      H.it("live testing discovers the tests", function()
        local status, _, raw = post("/api/live-testing/enable", { sessionId = sid }, port)
        H.assert_eq(200, status, "enable: " .. tostring(raw))
        local last = ""
        local ok = H.wait_for(function()
          local _, decoded, text = get("/api/live-testing/status?sessionId=" .. sid, port)
          last = text or ""
          return decoded and decoded.Summary and (decoded.Summary.Total or 0) > 0
        end, 120000, 2000)
        H.assert_truthy(ok, "tests discovered; last status: " .. last:sub(1, 300))
      end)
    end)

    local dt = require("sagefs.debug_test")
    local dap = require("dap")
    local helpers = { base_url = function() return "http://localhost:" .. port end }

    local function finished()
      local run = dt.current()
      return run == nil or run.state() == "finished"
    end

    --- Hold a test the way a plugin with no nvim-dap does: the hold, the pid and the
    --- instruction, and the release left to :SageFsDebugRelease.
    local function hold_by_hand(pattern)
      local deps = dt.default_deps(sagefs, helpers, nil)
      deps.dap = nil
      local run = dt.start(deps, { pattern = pattern })
      H.assert_truthy(H.wait_for(function() return run.held() ~= nil end, 60000, 100), "the daemon held the test")
      return run
    end

    H.describe(":SageFsDebugTest against the real daemon", function()
      H.it("holds the test, attaches netcoredbg, releases it, and the verdict comes back", function()
        dt._reset()
        vim.cmd("SageFsDebugTest deliberately failing")
        H.assert_truthy(H.wait_for(finished, 120000, 250), "the debug run finished")
        H.assert_truthy(said("deliberately failing"), "the verdict names the test")
        H.assert_truthy(said("failed"), "the test ran under the debugger and failed")
        H.assert_truthy(said("this should fail"), "the verdict carries the assertion's own message")
        H.assert_truthy(H.wait_for(function() return dap.session() == nil end, 15000, 100),
          "the debug session is over: the debugger detached")
      end)

      H.it("a hold another client has open is refused by name, with the ticket in the way, and nothing is leaked", function()
        dt._reset()
        notes = {}
        -- another client (a script, another editor) holds the host's one slot
        local status, held = post("/api/live-testing/debug", { pattern = "deliberately failing", sessionId = sid }, port)
        H.assert_eq(200, status, "the other client's hold")
        H.assert_eq("held", held.status)
        vim.cmd("SageFsDebugTest add works")
        H.assert_truthy(H.wait_for(function() return said("already held") end, 30000, 100),
          "the daemon's refusal reaches the user")
        H.assert_truthy(said(held.ticket), "it names the ticket of the hold that is in the way: " .. vim.inspect(notes))
        H.assert_truthy(H.wait_for(finished, 5000, 50), "the refused run is over, so :SageFsDebugRelease has nothing to leak")
        -- free the slot the other client held
        local _, freed = post("/api/live-testing/debug/continue", { ticket = held.ticket, sessionId = sid }, port)
        H.assert_eq("released_without_debugger", freed.status, "the daemon frees the slot and says no debugger was attached")
      end)

      H.it("the plugin's own run is one at a time, and :SageFsDebugRelease frees it, with the daemon's words", function()
        dt._reset()
        notes = {}
        local first = hold_by_hand("deliberately failing")
        vim.cmd("SageFsDebugTest add works")
        H.assert_truthy(said("already open"), "the second run in this editor is turned away at once")
        H.assert_eq("held", first.state(), "the first hold is untouched")
        notes = {}
        vim.cmd("SageFsDebugRelease")
        H.assert_truthy(H.wait_for(function() return first.state() == "finished" end, 30000, 100), "the hold was released")
        H.assert_truthy(said("no debugger was attached"), "the daemon's refusal for an unattached release is shown: " .. vim.inspect(notes))
      end)

      H.it("with the hold freed, the next debug run works again", function()
        dt._reset()
        notes = {}
        vim.cmd("SageFsDebugTest deliberately failing")
        H.assert_truthy(H.wait_for(finished, 120000, 250), "the debug run finished")
        H.assert_truthy(said("failed"), "the test ran under the debugger again")
      end)
    end)

    -- The hold window is two minutes (Timeouts.debugHold, not tunable), so this one
    -- is slow. SAGEFS_E2E_SLOW=1 runs it: nobody attaches, and the plugin has to
    -- release the hold itself when the window runs out.
    if os.getenv("SAGEFS_E2E_SLOW") == "1" then
      H.describe("a hold nobody attaches to", function()
        H.it("is released by the plugin when the hold window runs out, and the host takes the next test", function()
          dt._reset()
          notes = {}
          local run = hold_by_hand("deliberately failing")
          io.write(string.format("      holdMs = %s\n", tostring(run.held().holdMs)))
          H.assert_truthy(H.wait_for(function() return run.state() == "finished" end, (run.held().holdMs or 120000) + 90000, 500),
            "the run ended on its own")
          io.write("      said: " .. table.concat(vim.tbl_map(function(n) return n.msg end, notes), " | ") .. "\n")
          local _, again = post("/api/live-testing/debug", { pattern = "add works", sessionId = sid }, port)
          H.assert_eq("held", again.status, "the host's slot is free again")
          post("/api/live-testing/debug/continue", { ticket = again.ticket, sessionId = sid }, port)
        end)
      end)
    end

    -- Last: it kills the test host.
    H.describe("a test host that exits", function()
      H.it("while the test is held is said in words, with what to do", function()
        dt._reset()
        notes = {}
        local run = hold_by_hand("deliberately failing")
        local pid = run.held().pid
        H.assert_truthy(pid and pid > 0, "the hold names a process")
        vim.uv.kill(pid, "sigkill")
        vim.wait(1500, function() return false end)
        vim.cmd("SageFsDebugRelease")
        H.assert_truthy(H.wait_for(function() return run.state() == "finished" end, 60000, 100), "the run ended")
        local text = table.concat(vim.tbl_map(function(n) return n.msg end, notes), "\n")
        io.write("      said: " .. text:gsub("\n", " | ") .. "\n")
        H.assert_truthy(text:find("SageFs debug:", 1, true), "the user is told something: " .. text)
        H.assert_falsy(text:find("transport_error", 1, true), "not a raw status token: " .. text)
      end)
    end)

    vim.notify = real_notify
  end,
})

H.report()
