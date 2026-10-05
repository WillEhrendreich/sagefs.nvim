-- spec/e2e/e2e_nudge_spec.lua — E2E: nudge a value from Neovim, against a real daemon
--
-- A REAL daemon (its own port, its own SAGEFS_DATA_DIR, --no-resume, owned by this
-- Neovim) and a REAL isolated session on a copy of the Minimal sample whose
-- Library.fs is rewritten to hold values worth nudging. The plugin's own command
-- and maps are driven in a real buffer: the daemon rewrites the file on disk, and
-- the buffer shows what it wrote.
--
-- Usage: nvim --headless --clean -u NONE -l spec/e2e/e2e_nudge_spec.lua

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
package.path = script_dir .. "?.lua;" .. package.path

local H = require("e2e_harness")

local LIBRARY = table.concat({
  "module Library",
  "",
  "type Tuning = { JumpVelocity: float; Gravity: float; Cap: int }",
  "",
  "let tuning =",
  "  { JumpVelocity = 12.5",
  "    Gravity = 9.8",
  "    Cap = 12 }",
  "",
  "let speed = 1.0",
  "let drag = 1.0",
  "let enabled = true",
  "let mask = 0x1F",
  "",
  "[<Measure>] type m",
  "let reach = 12.5<m>",
  "",
  "type Mode = Easy | Hard",
  "let mode = Hard",
  "",
  "let pair = (5, 5)",
  "let add x y = x + y",
  "",
}, "\n")

local function json_decode(s)
  local ok, v = pcall(vim.json.decode, s)
  if ok then return v end
  return nil
end

local function read(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

H.run_suite({
  name = "Nudge a value (real daemon)",
  sample = "Minimal",
  port = 47792,
  warmup = false,
  fn = function(sagefs, temp, handle)
    local port = handle.port
    local library = temp.project .. "/Library.fs"
    local f = assert(io.open(library, "wb"))
    f:write(LIBRARY)
    f:close()

    local notes = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level) table.insert(notes, { msg = tostring(msg), level = level }) end
    local function said(fragment)
      for _, n in ipairs(notes) do
        if n.msg:find(fragment, 1, true) then return n end
      end
      return nil
    end
    local function wait_said(fragment, timeout)
      return H.wait_for(function() return said(fragment) end, timeout or 60000, 50)
    end
    local function dump()
      for _, n in ipairs(notes) do io.write("      note: " .. n.msg .. "\n") end
    end

    vim.system({ "dotnet", "build", "--nologo", "-v", "q" }, { cwd = temp.project }):wait()

    H.describe("a real session on a file with values in it", function()
      H.it("creates the session and it reaches Ready", function()
        local fsproj = H.find_fsproj(temp.project)
        local resp = H.http_post("/api/sessions/create", vim.json.encode({
          projectSelection = "these", projects = { fsproj }, workingDirectory = temp.project,
        }), port)
        H.assert_eq(200, resp.status, "create: " .. tostring(resp.body))
        local sid
        H.assert_truthy(H.wait_for(function()
          local decoded = json_decode(H.http_get("/api/sessions", port).body)
          for _, s in ipairs(decoded and decoded.sessions or {}) do
            if s.status == "Ready" then sid = s.id; return true end
          end
          return false
        end, 120000, 1500), "the session reached Ready")
        sagefs.active_session = { id = sid, working_directory = temp.project }
      end)

      H.it("the daemon's inspect lists the values, as the plugin reads it", function()
        local client = require("sagefs.mcp_client").connect(port)
        local got
        client.call_tool("nudge_value", { action = "inspect", file = library, working_directory = temp.project },
          function(ok, text) got = { ok = ok, text = text } end)
        H.assert_truthy(H.wait_for(function() return got end, 30000, 50), "inspect answered")
        io.write("      inspect: " .. tostring(got.text):sub(1, 700) .. "\n")
        local reply = require("sagefs.nudge").parse_reply(got.ok, got.text)
        H.assert_eq("Inspected", reply.outcome, "reply: " .. tostring(got.text))
        H.assert_truthy(#reply.items >= 5, "the file's values are listed")
        client.close()
      end)
    end)

    vim.cmd("edit " .. vim.fn.fnameescape(library))
    vim.bo.filetype = "fsharp"
    local buf = vim.api.nvim_get_current_buf()

    local function put_cursor(pattern, offset)
      for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        local s = line:find(pattern, 1, true)
        if s then
          vim.api.nvim_win_set_cursor(0, { i, s - 1 + (offset or 0) })
          return i
        end
      end
      error("no line with " .. pattern)
    end
    local function line_with(pattern)
      for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find(pattern, 1, true) then return line end
      end
    end
    local function disk_has(text) return read(library):find(text, 1, true) ~= nil end

    H.describe(":SageFsNudge in a real buffer", function()
      H.it("bumps the number under the cursor, and the buffer shows what the daemon wrote", function()
        notes = {}
        local row = put_cursor("12.5", 1)
        vim.cmd("SageFsNudge up")
        H.assert_truthy(wait_said("12.6"), "the notice shows the new value")
        dump()
        H.assert_truthy(disk_has("JumpVelocity = 12.6"), "the daemon wrote the file")
        H.assert_truthy(H.wait_for(function() return line_with("JumpVelocity =") == "  { JumpVelocity = 12.6" end, 5000, 50),
          "the buffer was reloaded: " .. tostring(line_with("JumpVelocity =")))
        H.assert_eq(row, vim.api.nvim_win_get_cursor(0)[1], "the cursor stayed on its line")
        H.assert_falsy(vim.bo[buf].modified, "the reloaded buffer is not modified")
        H.assert_falsy(disk_has("Gravity = 9.9"), "nothing else was touched")
      end)

      H.it("a count with the namespaced map moves it that many steps (3<leader>rk-)", function()
        notes = {}
        put_cursor("12.6", 1)
        local leader = vim.g.mapleader or "\\"
        H.assert_truthy(vim.fn.maparg(leader .. "rk-", "n", false, true).buffer == 1, "the map is buffer-local")
        vim.cmd("normal 3" .. leader .. "rk-")
        H.assert_truthy(wait_said("12.3"), "three steps down")
        H.assert_truthy(H.wait_for(function() return disk_has("JumpVelocity = 12.3") end, 5000, 50), "on disk")
      end)

      H.it("an integer goes by one, and a typed value is set as it is", function()
        notes = {}
        put_cursor("= 12 }", 3)
        vim.cmd("SageFsNudge up")
        H.assert_truthy(wait_said("13"), "the integer went up by one")
        H.assert_truthy(H.wait_for(function() return disk_has("Cap = 13") end, 5000, 50), "on disk")
        notes = {}
        put_cursor("Gravity = 9.8", 12)
        vim.cmd("SageFsNudge set 4.5")
        H.assert_truthy(wait_said("4.5"), "set to the typed value")
        H.assert_truthy(H.wait_for(function() return disk_has("Gravity = 4.5") end, 5000, 50), "on disk")
      end)

      H.it("a bool toggles", function()
        notes = {}
        put_cursor("true", 1)
        vim.cmd("SageFsNudge up")
        H.assert_truthy(wait_said("false"), "toggled")
        H.assert_truthy(H.wait_for(function() return disk_has("let enabled = false") end, 5000, 50), "on disk")
      end)

      H.it("two values with the same text are told apart by where the cursor is", function()
        -- speed and drag are both 1.0; the cursor is on drag's
        notes = {}
        put_cursor("let drag = 1.0", 13)
        vim.cmd("SageFsNudge up")
        H.assert_truthy(wait_said("Library.drag"), "it was drag that moved: " .. vim.inspect(notes))
        H.assert_truthy(H.wait_for(function() return disk_has("let drag = 1.1") end, 5000, 50), "drag is 1.1 on disk")
        H.assert_truthy(disk_has("let speed = 1.0"), "speed was not touched")
        notes = {}
        put_cursor("let speed = 1.0", 13)
        vim.cmd("SageFsNudge up")
        H.assert_truthy(wait_said("Library.speed"), "and now speed")
        H.assert_truthy(H.wait_for(function() return disk_has("let speed = 1.1") end, 5000, 50), "on disk")
        H.assert_truthy(disk_has("let drag = 1.1"), "drag stayed where it was put")
      end)

      H.it("hex goes up as the number it is and stays hex; a unit of measure is kept", function()
        notes = {}
        put_cursor("0x1F", 2)
        vim.cmd("SageFsNudge up")
        H.assert_truthy(wait_said("Library.mask"), "mask moved")
        H.assert_truthy(H.wait_for(function() return disk_has("let mask = 0x20") end, 5000, 50),
          "0x1F + 1 is 0x20, written in hex: " .. (line_with("let mask") or "?"))
        notes = {}
        put_cursor("12.5<m>", 1)
        vim.cmd("SageFsNudge up")
        H.assert_truthy(wait_said("Library.reach"), "reach moved")
        H.assert_truthy(H.wait_for(function() return disk_has("let reach = 12.6<m>") end, 5000, 50),
          "the unit survived: " .. (line_with("let reach") or "?"))
      end)

      H.it("five bumps typed without waiting land as five steps, in order, none refused", function()
        notes = {}
        put_cursor("12.6<m>", 1)
        for _ = 1, 5 do vim.cmd("SageFsNudge up") end
        H.assert_truthy(H.wait_for(function() return disk_has("let reach = 13.1<m>") end, 60000, 50),
          "12.6 + 5 steps is 13.1: " .. (line_with("let reach") or "?"))
        H.assert_truthy(H.wait_for(function() return line_with("let reach") == "let reach = 13.1<m>" end, 5000, 50), "and the buffer has it")
        H.assert_falsy(said("changed while"), "no flow was refused for the buffer changing under it: " .. vim.inspect(notes))
        H.assert_falsy(said("refused"), "and the daemon refused none")
      end)

      H.it("a union case is set by name", function()
        notes = {}
        put_cursor("= Hard", 3)
        vim.cmd("SageFsNudge set Easy")
        H.assert_truthy(wait_said("Library.mode"), "mode moved: " .. vim.inspect(notes))
        H.assert_truthy(H.wait_for(function() return disk_has("let mode = Easy") end, 5000, 50), "on disk")
        notes = {}
        put_cursor("= Easy", 3)
        vim.cmd("SageFsNudge up")
        H.assert_truthy(wait_said("SageFsNudge set"), "a case is not bumped, and the message says what to do instead")
        H.assert_falsy(disk_has("let mode = Hard"), "and nothing was written")
      end)

      H.it("two values nothing can tell apart are offered, and the one picked moves", function()
        notes = {}
        local offered
        local real_select = vim.ui.select
        vim.ui.select = function(items, opts, cb)
          offered = items
          cb(items[2])
        end
        put_cursor("(5, 5)", 4) -- on the second 5
        vim.cmd("SageFsNudge up")
        H.assert_truthy(H.wait_for(function() return offered end, 30000, 50), "the picker was shown")
        H.assert_eq(2, #offered, "both are offered")
        H.assert_truthy(H.wait_for(function() return disk_has("let pair = (5, 6)") end, 5000, 50),
          "the picked one moved: " .. (line_with("let pair") or "?"))
        vim.ui.select = real_select
      end)

      H.it("list shows the values of the file, and the one picked is set to what is typed", function()
        notes = {}
        local shown
        local real_select, real_input = vim.ui.select, vim.ui.input
        vim.ui.select = function(items, opts, cb)
          shown = items
          for _, it in ipairs(items) do
            if it.address == "Library.tuning/{Cap}" then cb(it) return end
          end
          cb(nil)
        end
        vim.ui.input = function(opts, cb) cb("77") end
        vim.cmd("SageFsNudge list")
        local landed = H.wait_for(function() return disk_has("Cap = 77") end, 30000, 50)
        vim.ui.select, vim.ui.input = real_select, real_input
        if not landed then dump() end
        H.assert_truthy(landed, "Cap is 77 on disk: " .. (line_with("Cap =") or "?"))
        H.assert_truthy(shown and #shown >= 8, "every value of the file was offered")
      end)

      H.it("expr replaces the value with an expression, and says it was not type-checked", function()
        notes = {}
        put_cursor("let speed = 1.1", 13)
        vim.cmd("SageFsNudge expr 2.0 * 3.0")
        H.assert_truthy(wait_said("type-checked"), "the daemon's note is passed on")
        H.assert_truthy(H.wait_for(function() return disk_has("let speed = 2.0 * 3.0") end, 5000, 50), "on disk")
      end)

      H.it("undo and redo step through what was written, and the buffer follows", function()
        notes = {}
        vim.cmd("SageFsNudge undo")
        H.assert_truthy(wait_said("undone"), "undone")
        H.assert_truthy(H.wait_for(function() return disk_has("let speed = 1.1") end, 5000, 50), "the expression is gone from disk")
        H.assert_truthy(H.wait_for(function() return line_with("let speed") == "let speed = 1.1" end, 5000, 50), "and from the buffer")
        notes = {}
        vim.cmd("SageFsNudge redo")
        H.assert_truthy(wait_said("redone"), "redone")
        H.assert_truthy(H.wait_for(function() return line_with("let speed") == "let speed = 2.0 * 3.0" end, 5000, 50), "the buffer has it again")
      end)

      H.it("a buffer with unsaved edits is refused by name, and the file is not touched", function()
        notes = {}
        local before = read(library)
        vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "// an edit the daemon has not seen" })
        vim.cmd("SageFsNudge up")
        H.assert_truthy(said("unsaved"), "refused: " .. vim.inspect(notes))
        vim.wait(500, function() return false end)
        H.assert_eq(before, read(library), "the file on disk is byte-identical")
        vim.cmd("silent! edit!")
        H.assert_falsy(vim.bo[buf].modified, "the edit was dropped")
      end)

      H.it("a file the session does not own is refused by the daemon with its rule and next action", function()
        notes = {}
        local other = vim.fn.tempname() .. "-Other.fs"
        vim.fn.writefile({ "module Other", "let x = 1.0" }, other)
        vim.cmd("edit " .. vim.fn.fnameescape(other))
        vim.bo.filetype = "fsharp"
        vim.api.nvim_win_set_cursor(0, { 2, 10 })
        vim.cmd("SageFsNudge up")
        H.assert_truthy(wait_said("NotOwned"), "the refusal's token")
        local note = said("NotOwned")
        H.assert_truthy(note.msg:find("source file of any project", 1, true), "the daemon's rule: " .. note.msg)
        H.assert_truthy(note.msg:find("Next:", 1, true), "and its next action")
        H.assert_eq(vim.log.levels.WARN, note.level)
        vim.cmd("buffer " .. buf)
      end)

      H.it("a stale hash is refused by the daemon and nothing is written (the value moved under us)", function()
        -- inspect, change the file on disk behind the plugin's back, then set with the old hash
        local client = require("sagefs.mcp_client").connect(port)
        local reply
        client.call_tool("nudge_value", { action = "inspect", file = library, address = "Library.speed", working_directory = temp.project },
          function(ok, text) reply = require("sagefs.nudge").parse_reply(ok, text) end)
        H.assert_truthy(H.wait_for(function() return reply end, 30000, 50), "inspect answered")
        local seen = reply.items[1].hash
        local text = read(library):gsub("2.0 %* 3.0", "7.5")
        local w = assert(io.open(library, "wb")); w:write(text); w:close()
        local result
        client.call_tool("nudge_value", { action = "set", file = library, address = "Library.speed", seen = seen, literal = "9.9", working_directory = temp.project },
          function(ok, body) result = require("sagefs.nudge").parse_reply(ok, body) end)
        H.assert_truthy(H.wait_for(function() return result end, 30000, 50), "set answered")
        H.assert_eq("Refused", result.outcome)
        H.assert_eq("SourceMoved", result.refusal)
        local shown = require("sagefs.nudge").describe(result)
        io.write("      shown: " .. shown .. "\n")
        H.assert_truthy(shown:find("7.5", 1, true), "the text that is there now is in the notice")
        H.assert_truthy(disk_has("let speed = 7.5"), "the file is as the other writer left it")
        client.close()
        vim.cmd("silent! edit!")
      end)
    end)

    vim.notify = real_notify
  end,
})

H.report()
