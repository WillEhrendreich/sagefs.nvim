-- spec/dashboard/eval_heartbeat_spec.lua — the daemon's ~500ms eval_heartbeat
--
-- Wire shape (SageFs/SageFs.Core/SseWriter.fs formatEvalHeartbeatEvent):
--   { FilePath, BlockStartLine, ElapsedMs }  — PascalCase on the wire.
-- The plugin reads both casings, like eval_result does.
--
-- Covers: the SSE classification + autocmd pattern that carry it, the state
-- fold (elapsed recorded, foreign file/line ignored, eval_result clears the
-- ticking), and the Output section that shows it.

require("spec.helper")
local sse = require("sagefs.sse")
local events = require("sagefs.events")
local state_mod = require("sagefs.dashboard.state")
local output_section = require("sagefs.dashboard.sections.output")

describe("eval_heartbeat — SSE side", function()
  it("classifies the daemon's eval_heartbeat frame", function()
    local r = sse.classify_event({ type = "eval_heartbeat", data = "{}" })
    assert.are.equal("eval_heartbeat", r.action)
  end)

  it("maps to a User autocmd pattern so the dashboard can hear it", function()
    local evt = events.build_autocmd_data("eval_heartbeat", { ElapsedMs = 500 })
    assert.is_table(evt)
    assert.are.equal("SageFsEvalHeartbeat", evt.pattern)
    assert.are.equal(500, evt.data.ElapsedMs)
  end)
end)

describe("eval_heartbeat — state", function()
  local s

  before_each(function()
    s = state_mod.new()
  end)

  it("records the elapsed time of the running eval (wire PascalCase)", function()
    s = state_mod.update(s, "eval_heartbeat", {
      FilePath = "src/A.fs", BlockStartLine = 12, ElapsedMs = 500,
    })
    assert.is_table(s.eval.heartbeat)
    assert.are.equal("src/A.fs", s.eval.heartbeat.file)
    assert.are.equal(12, s.eval.heartbeat.line)
    assert.are.equal(500, s.eval.heartbeat.elapsed_ms)

    s = state_mod.update(s, "eval_heartbeat", {
      FilePath = "src/A.fs", BlockStartLine = 12, ElapsedMs = 1000,
    })
    assert.are.equal(1000, s.eval.heartbeat.elapsed_ms, "each beat advances the recorded elapsed")
  end)

  it("reads camelCase too, like eval_result does", function()
    s = state_mod.update(s, "eval_heartbeat", {
      filePath = "src/A.fs", blockStartLine = 12, elapsedMs = 750,
    })
    assert.are.equal(750, s.eval.heartbeat.elapsed_ms)
    assert.are.equal("src/A.fs", s.eval.heartbeat.file)
  end)

  it("ignores a heartbeat for a different file/line while one is running", function()
    s = state_mod.update(s, "eval_heartbeat", {
      FilePath = "src/A.fs", BlockStartLine = 12, ElapsedMs = 500,
    })
    -- Another eval's heartbeat (other file, other block) must not corrupt it
    s = state_mod.update(s, "eval_heartbeat", {
      FilePath = "src/B.fs", BlockStartLine = 99, ElapsedMs = 9000,
    })
    assert.are.equal("src/A.fs", s.eval.heartbeat.file)
    assert.are.equal(12, s.eval.heartbeat.line)
    assert.are.equal(500, s.eval.heartbeat.elapsed_ms)

    -- Same file but a different block start line is another eval as well
    s = state_mod.update(s, "eval_heartbeat", {
      FilePath = "src/A.fs", BlockStartLine = 13, ElapsedMs = 9000,
    })
    assert.are.equal(500, s.eval.heartbeat.elapsed_ms)

    -- The real eval keeps ticking afterwards
    s = state_mod.update(s, "eval_heartbeat", {
      FilePath = "src/A.fs", BlockStartLine = 12, ElapsedMs = 1000,
    })
    assert.are.equal(1000, s.eval.heartbeat.elapsed_ms)
  end)

  it("a following eval_result clears the heartbeat", function()
    s = state_mod.update(s, "eval_heartbeat", {
      FilePath = "src/A.fs", BlockStartLine = 12, ElapsedMs = 500,
    })
    s = state_mod.update(s, "eval_result", {
      filePath = "src/A.fs", blockStartLine = 12,
      output = "val it: int = 42", durationMs = 812,
    })
    assert.is_nil(s.eval.heartbeat, "finished eval must not keep the ticking heartbeat")
    assert.are.equal("val it: int = 42", s.eval.output)
    assert.are.equal(812, s.eval.duration_ms)
  end)

  it("handles a nil payload without erroring", function()
    s = state_mod.update(s, "eval_heartbeat", {
      FilePath = "src/A.fs", BlockStartLine = 12, ElapsedMs = 500,
    })
    s = state_mod.update(s, "eval_heartbeat", nil)
    assert.are.equal(500, s.eval.heartbeat.elapsed_ms)
  end)

  it("is in handled_events so the event index can reach it", function()
    local found = false
    for _, e in ipairs(state_mod.handled_events()) do
      if e == "eval_heartbeat" then found = true; break end
    end
    assert.is_true(found)
  end)
end)

describe("eval_heartbeat — Output section", function()
  it("declares eval_heartbeat so the section re-renders on every beat", function()
    local found = false
    for _, e in ipairs(output_section.events) do
      if e == "eval_heartbeat" then found = true; break end
    end
    assert.is_true(found)
  end)

  it("shows the elapsed time while the eval is running", function()
    local s = state_mod.new()
    s = state_mod.update(s, "eval_heartbeat", {
      FilePath = "src/A.fs", BlockStartLine = 12, ElapsedMs = 3500,
    })
    local out = output_section.render(s)
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("Evaluating", 1, true), "running eval says so:\n" .. joined)
    assert.truthy(joined:find("3.5s", 1, true), "elapsed from the heartbeat:\n" .. joined)
  end)

  it("ticks forward with each beat", function()
    local s = state_mod.new()
    s = state_mod.update(s, "eval_heartbeat", {
      FilePath = "src/A.fs", BlockStartLine = 12, ElapsedMs = 3500,
    })
    s = state_mod.update(s, "eval_heartbeat", {
      FilePath = "src/A.fs", BlockStartLine = 12, ElapsedMs = 4000,
    })
    local joined = table.concat(output_section.render(s).lines, "\n")
    assert.truthy(joined:find("4.0s", 1, true), joined)
    assert.is_nil(joined:find("3.5s", 1, true), "old value must be gone:\n" .. joined)
  end)

  it("stops after eval_result: the finished eval's duration replaces the heartbeat", function()
    local s = state_mod.new()
    s = state_mod.update(s, "eval_heartbeat", {
      FilePath = "src/A.fs", BlockStartLine = 12, ElapsedMs = 3500,
    })
    s = state_mod.update(s, "eval_result", {
      output = "val it: int = 42", cellId = 3, durationMs = 3600,
    })
    local joined = table.concat(output_section.render(s).lines, "\n")
    assert.is_nil(joined:find("Evaluating", 1, true), "ticking line must stop:\n" .. joined)
    assert.is_nil(joined:find("3.5s", 1, true), "last heartbeat value must not linger:\n" .. joined)
    assert.truthy(joined:find("3600ms", 1, true), "shows the completed eval instead:\n" .. joined)
  end)
end)
