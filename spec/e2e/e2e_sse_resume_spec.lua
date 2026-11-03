-- spec/e2e/e2e_sse_resume_spec.lua — a dropped /events stream resumes by Last-Event-ID
-- Real Neovim, the plugin's real transport (curl), a real daemon with a bare session.
-- Usage: nvim --headless --clean -u NONE -l spec/e2e/e2e_sse_resume_spec.lua
--
-- The daemon numbers every pushed frame `<epoch>:<seq>`. A client that comes back with the last id it saw
-- is sent what it missed. The transport handle keeps that id across a stop and a start, so stopping the
-- stream, evaluating while it is down, and starting it again is the same code path as a drop, with the
-- timing under the test's control instead of a reconnect timer's.
--
-- What it asserts is the ids themselves: after the reconnect the numbered frames pick up at exactly the
-- next seq and run without a gap or a repeat. Marker text would not do, because the snapshots a
-- connection is also sent re-carry earlier text.

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
package.path = script_dir .. "?.lua;" .. package.path

local H = require("e2e_harness")

local function json_decode(s)
  local ok, v = pcall(vim.json.decode, s)
  if ok then return v end
  return nil
end

local function session_row(port, sid)
  local data = json_decode(H.http_get("/api/sessions", port).body)
  for _, s in ipairs(data and data.sessions or {}) do
    if s.id == sid then return s end
  end
  return nil
end

--- "<epoch>:<seq>" -> epoch, seq. The seq is whatever follows the last colon.
local function split_id(id)
  local epoch, seq = id:match("^(.*):(%d+)$")
  return epoch, tonumber(seq)
end

--- The numbered events after position `from`, in order. Snapshots carry no id and are left out.
local function numbered_after(seen, from)
  local out = {}
  for i = from + 1, #seen do
    if seen[i].id then table.insert(out, seen[i]) end
  end
  return out
end

local function carrying(events, marker)
  for _, event in ipairs(events) do
    if event.data and event.data:find(marker, 1, true) then return true end
  end
  return false
end

local function open_stream(port, seen, on_connect, last_event_id)
  local transport = require("sagefs.transport")
  local sse = transport.connect_sse(string.format("http://localhost:%d/events", port), {
    on_events = function(events)
      for _, event in ipairs(events) do table.insert(seen, event) end
    end,
    on_connect = on_connect,
    auto_reconnect = false,
  })
  sse._last_event_id = last_event_id
  return sse
end

H.run_suite({
  name = "SSE resume",
  sample = "Minimal",
  port = 47751,
  -- The daemon starts bare. Numbered frames only flow once a session exists, so the suite makes one.
  warmup = false,

  fn = function(sagefs, temp, handle)

    H.describe("a session to evaluate in", function()
      H.it("the daemon creates a bare session and it reaches Ready", function()
        local r = H.http_post("/api/sessions/create", vim.json.encode({
          projects = vim.empty_dict(), workingDirectory = temp.project,
        }), handle.port)
        H.assert_eq(200, r.status, "create status: " .. r.body)
        local sid = json_decode(r.body).message
        H.assert_truthy(vim.wait(120000, function()
          local row = session_row(handle.port, sid)
          return row and row.status == "Ready"
        end, 100), "the session reached Ready")
      end)
    end)

    H.describe("a stream that was down while the daemon pushed frames", function()
      H.it("is sent what it missed, from the very next seq, with no gap and no repeat", function()
        local seen = {}
        local connects = 0
        local sse = open_stream(handle.port, seen, function() connects = connects + 1 end, nil)

        sse.start()
        H.assert_truthy(H.wait_for(function() return connects >= 1 end, 15000), "the first connection opens")

        H.eval("let resumeBefore = 111;;", handle.port)
        H.assert_truthy(
          H.wait_for(function() return carrying(numbered_after(seen, 0), "resumeBefore") end, 15000),
          "the eval pushed while connected arrives live, numbered")
        H.assert_truthy(sse._last_event_id, "the transport remembered an id")

        -- Down. Let the old curl's last bytes drain, then note where this stream got to.
        sse.stop()
        H.assert_truthy(H.wait_for(function() return not sse.active() end, 5000), "the stream is down")
        vim.wait(1000, function() return false end)
        local epoch, seq_before = split_id(sse._last_event_id)
        H.assert_truthy(epoch and seq_before, "the id is <epoch>:<seq>: " .. tostring(sse._last_event_id))
        local mark = #seen

        -- The daemon pushes while nobody is listening.
        H.eval("let resumeMissed = 222;;", handle.port)
        vim.wait(1000, function() return false end)
        H.assert_eq(mark, #seen, "nothing reached the stopped stream")

        -- Back, with the id it held.
        connects = 0
        sse.start()
        H.assert_truthy(H.wait_for(function() return connects >= 1 end, 15000), "the stream reconnects")
        H.assert_truthy(
          H.wait_for(function() return carrying(numbered_after(seen, mark), "resumeMissed") end, 15000),
          "the frames pushed while the stream was down are replayed")

        local after = numbered_after(seen, mark)
        local expected = seq_before + 1
        for _, event in ipairs(after) do
          local e, s = split_id(event.id)
          H.assert_eq(epoch, e, "same run of the daemon")
          H.assert_eq(expected, s, "numbered frames run without a gap or a repeat")
          expected = expected + 1
        end
        H.assert_truthy(#after >= 1, "at least one frame was replayed")

        sse.stop()
      end)

      H.it("connects plainly when the id is from another run, and still receives what is pushed next", function()
        local seen = {}
        local connects = 0
        local sse = open_stream(handle.port, seen, function() connects = connects + 1 end, "some-other-run:1")

        sse.start()
        H.assert_truthy(H.wait_for(function() return connects >= 1 end, 15000), "it connects with a stale id")
        local mark = #seen
        H.eval("let resumeAfterStale = 333;;", handle.port)
        H.assert_truthy(
          H.wait_for(function() return carrying(numbered_after(seen, mark), "resumeAfterStale") end, 15000),
          "and still receives what is pushed next")
        sse.stop()
      end)
    end)

  end,
})

H.report()
