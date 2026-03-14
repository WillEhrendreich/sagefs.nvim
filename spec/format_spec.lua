-- =============================================================================
-- Result Formatting Tests — sagefs/format.lua
-- =============================================================================
-- Expert panel test plan:
--
-- **Wlaschin**: Result is a discriminated union: Success(output) | Error(msg).
--   In Lua we model this as {ok=true, output=...} | {ok=false, error=...}.
--   Every display function must handle both cases.
--
-- **Carmack**: Keep formatting dead simple. Truncate long output. Users can
--   always scroll to the SageFs window for the full thing.
--
-- **DeVries**: Extmark virtual text has constraints — single line, limited
--   width. Format for THAT display, not for a terminal.
-- =============================================================================

local format = require("sagefs.format")

-- ─── parse_exec_response: parse JSON from /exec endpoint ─────────────────────

describe("format.parse_exec_response", function()
  it("parses successful response", function()
    local json = '{"success":true,"result":"val it: int = 42"}'
    local result = format.parse_exec_response(json)
    assert.is_true(result.ok)
    assert.are.equal("val it: int = 42", result.output)
  end)

  it("parses error response", function()
    local json = '{"success":false,"result":"error FS0001: The type int does not match the type string"}'
    local result = format.parse_exec_response(json)
    assert.is_false(result.ok)
    assert.are.equal("error FS0001: The type int does not match the type string", result.error)
  end)

  it("handles malformed JSON gracefully", function()
    local result = format.parse_exec_response("not json at all")
    assert.is_false(result.ok)
    assert.is_not_nil(result.error)
  end)

  it("handles empty string", function()
    local result = format.parse_exec_response("")
    assert.is_false(result.ok)
  end)

  it("handles nil input", function()
    local result = format.parse_exec_response(nil)
    assert.is_false(result.ok)
  end)

  it("handles response with missing fields", function()
    local json = '{"success":true}'
    local result = format.parse_exec_response(json)
    assert.is_true(result.ok)
    assert.are.equal("", result.output)
  end)
end)

-- ─── format_inline: format result for extmark virtual text ───────────────────

describe("format.format_inline", function()
  it("formats success with short output", function()
    local result = format.format_inline({ ok = true, output = "val it: int = 42" })
    assert.is_not_nil(result)
    assert.is_not_nil(result.text)
    assert.is_not_nil(result.hl)
    assert.is_true(result.text:find("42") ~= nil)
  end)

  it("formats error with message", function()
    local result = format.format_inline({ ok = false, error = "type mismatch" })
    assert.is_not_nil(result)
    assert.is_true(result.text:find("type mismatch") ~= nil)
  end)

  it("truncates long output", function()
    local long_output = string.rep("x", 500)
    local result = format.format_inline({ ok = true, output = long_output })
    assert.is_true(#result.text < 200)
    assert.is_true(result.text:find("…") ~= nil or result.text:find("%.%.%.") ~= nil)
  end)

  it("uses success highlight for ok results", function()
    local result = format.format_inline({ ok = true, output = "val it: int = 42" })
    assert.are.equal("SageFsSuccess", result.hl)
  end)

  it("uses error highlight for failed results", function()
    local result = format.format_inline({ ok = false, error = "error" })
    assert.are.equal("SageFsError", result.hl)
  end)

  it("handles multiline output by taking first line", function()
    local result = format.format_inline({
      ok = true,
      output = "val it: int = 42\nval it2: string = \"hello\"",
    })
    -- Should show first line, indicate more lines exist
    assert.is_not_nil(result.text)
  end)

  it("strips carriage returns from Windows line endings", function()
    local result = format.format_inline({ ok = true, output = "val it: int = 42\r" })
    assert.is_falsy(result.text:find("\r"))
    assert.is_truthy(result.text:find("42"))
  end)

  it("appends duration when duration_ms is present", function()
    local result = format.format_inline({
      ok = true, output = "val it: int = 42", duration_ms = 150,
    })
    assert.is_truthy(result.text:find("150ms"))
  end)

  it("formats sub-second durations in ms", function()
    local result = format.format_inline({
      ok = true, output = "val it: int = 42", duration_ms = 42,
    })
    assert.is_truthy(result.text:find("42ms"))
  end)

  it("formats multi-second durations with decimal seconds", function()
    local result = format.format_inline({
      ok = true, output = "val it: int = 42", duration_ms = 2500,
    })
    assert.is_truthy(result.text:find("2%.5s"))
  end)

  it("omits duration when nil", function()
    local result = format.format_inline({ ok = true, output = "val it: int = 42" })
    assert.is_falsy(result.text:find("ms"))
    assert.is_falsy(result.text:find("%ds"))
  end)

  it("shows duration for errors too", function()
    local result = format.format_inline({
      ok = false, error = "type mismatch", duration_ms = 80,
    })
    assert.is_truthy(result.text:find("80ms"))
  end)
end)

-- ─── format_virtual_lines: format result for virtual lines below ;; ──────────

describe("format.format_virtual_lines", function()
  it("returns lines for single-line output", function()
    local result = format.format_virtual_lines({ ok = true, output = "val it: int = 42" })
    assert.are.equal(1, #result)
    assert.is_true(result[1].text:find("42") ~= nil)
  end)

  it("returns multiple lines for multiline output", function()
    local output = "val x: int = 1\nval y: int = 2\nval z: int = 3"
    local result = format.format_virtual_lines({ ok = true, output = output })
    assert.are.equal(3, #result)
  end)

  it("caps maximum lines", function()
    local lines = {}
    for i = 1, 50 do
      lines[i] = "val v" .. i .. ": int = " .. i
    end
    local output = table.concat(lines, "\n")
    local result = format.format_virtual_lines({ ok = true, output = output })
    assert.is_true(#result <= 20)
  end)

  it("uses correct highlight groups", function()
    local result = format.format_virtual_lines({ ok = true, output = "val it: int = 42" })
    assert.are.equal("SageFsOutput", result[1].hl)

    local err_result = format.format_virtual_lines({ ok = false, error = "error FS0001" })
    assert.are.equal("SageFsError", err_result[1].hl)
  end)

  it("handles empty output", function()
    local result = format.format_virtual_lines({ ok = true, output = "" })
    assert.are.equal(1, #result)
    -- Should show something like "(no output)"
  end)

  it("strips carriage returns from Windows line endings", function()
    local result = format.format_virtual_lines({ ok = true, output = "line1\r\nline2\r" })
    for _, line in ipairs(result) do
      assert.is_falsy(line.text:find("\r"))
    end
  end)
end)

-- ─── format_gutter_sign: format the gutter indicator ─────────────────────────

describe("format.gutter_sign", function()
  it("returns checkmark for success", function()
    local result = format.gutter_sign("success")
    assert.are.equal("✓", result.text)
    assert.are.equal("SageFsSuccess", result.hl)
  end)

  it("returns X for error", function()
    local result = format.gutter_sign("error")
    assert.are.equal("✖", result.text)
    assert.are.equal("SageFsError", result.hl)
  end)

  it("returns spinner for running", function()
    local result = format.gutter_sign("running")
    assert.are.equal("⏳", result.text)
    assert.are.equal("SageFsRunning", result.hl)
  end)

  it("returns tilde for stale", function()
    local result = format.gutter_sign("stale")
    assert.are.equal("~", result.text)
    assert.are.equal("SageFsStale", result.hl)
  end)

  it("returns empty for idle", function()
    local result = format.gutter_sign("idle")
    assert.are.equal(" ", result.text)
  end)
end)

-- ─── Snapshot tests: exact formatting output ─────────────────────────────────

describe("format.format_inline [snapshot]", function()
  it("success with simple int: → val it: int = 42", function()
    local result = format.format_inline({ ok = true, output = "val it: int = 42" })
    assert.are.equal("→ val it: int = 42", result.text)
    assert.are.equal("SageFsSuccess", result.hl)
  end)

  it("success with multiline: first line + ellipsis", function()
    local result = format.format_inline({ ok = true, output = "val it: int = 42\nval it2: string = \"hi\"" })
    assert.are.equal("→ val it: int = 42 …", result.text)
  end)

  it("error with simple message: ✖ prefix", function()
    local result = format.format_inline({ ok = false, error = "type mismatch" })
    assert.are.equal("✖ type mismatch", result.text)
    assert.are.equal("SageFsError", result.hl)
  end)

  it("success with empty output: → (empty string)", function()
    local result = format.format_inline({ ok = true, output = "" })
    assert.are.equal("→ ", result.text)
  end)

  it("error with nil message: ✖ error", function()
    local result = format.format_inline({ ok = false })
    assert.are.equal("✖ error", result.text)
  end)
end)

describe("format.format_virtual_lines [snapshot]", function()
  it("single line output indented", function()
    local result = format.format_virtual_lines({ ok = true, output = "val it: int = 42" })
    assert.are.equal(1, #result)
    assert.are.equal("  val it: int = 42", result[1].text)
    assert.are.equal("SageFsOutput", result[1].hl)
  end)

  it("empty output shows (no output)", function()
    local result = format.format_virtual_lines({ ok = true, output = "" })
    assert.are.equal(1, #result)
    assert.are.equal("(no output)", result[1].text)
  end)

  it("multiline output preserves each line", function()
    local result = format.format_virtual_lines({ ok = true, output = "line1\nline2\nline3" })
    assert.are.equal(3, #result)
    assert.are.equal("  line1", result[1].text)
    assert.are.equal("  line2", result[2].text)
    assert.are.equal("  line3", result[3].text)
  end)
end)

-- ─── gutter_sign exhaustive: every status maps correctly ─────────────────────

describe("format.gutter_sign [exhaustive]", function()
  local expected = {
    success = { text = "✓", hl = "SageFsSuccess" },
    error   = { text = "✖", hl = "SageFsError" },
    running = { text = "⏳", hl = "SageFsRunning" },
    stale   = { text = "~", hl = "SageFsStale" },
    idle    = { text = " ", hl = "Normal" },
  }

  for status, exp in pairs(expected) do
    it("status '" .. status .. "' → sign '" .. exp.text .. "'", function()
      local result = format.gutter_sign(status)
      assert.are.equal(exp.text, result.text)
      assert.are.equal(exp.hl, result.hl)
    end)
  end

  it("unknown status falls through to space/Normal", function()
    local result = format.gutter_sign("banana")
    assert.are.equal(" ", result.text)
    assert.are.equal("Normal", result.hl)
  end)
end)

describe("format.build_render_options", function()
  it("gives stale codelens the stale highlight group", function()
    local opts = format.build_render_options({
      status = "stale",
      output = "old value",
    }, 6)

    assert.is_table(opts)
    assert.is_table(opts.codelens)
    assert.are.equal("▶ Eval", opts.codelens.text)
    assert.are.equal("SageFsCodeLensStale", opts.codelens.hl)
  end)
end)

-- ─── format_status_report ─────────────────────────────────────────────────────

describe("format_status_report", function()
  local testing = require("sagefs.testing")
  local coverage = require("sagefs.coverage")
  local model = require("sagefs.model")
  local daemon = require("sagefs.daemon")

  it("shows disconnected when no session and idle state", function()
    local lines = format.format_status_report({
      state = model.new(),
      testing_state = testing.new(),
      coverage_state = coverage.new(),
      daemon_state = daemon.new(),
      active_session = nil,
      config = { port = 37749, dashboard_port = 37750, check_on_save = false },
    })
    assert.is_table(lines)
    assert.is_true(#lines > 0)
    -- first line should be a header
    local joined = table.concat(lines, "\n")
    assert.is_truthy(joined:find("SageFs Status"))
  end)

  it("shows active session info when session is set", function()
    local lines = format.format_status_report({
      state = model.new(),
      testing_state = testing.new(),
      coverage_state = coverage.new(),
      daemon_state = daemon.new(),
      active_session = { id = "abc123", name = "MyProject.fsproj" },
      config = { port = 37749, dashboard_port = 37750, check_on_save = true },
    })
    local joined = table.concat(lines, "\n")
    assert.is_truthy(joined:find("MyProject"))
    assert.is_truthy(joined:find("check_on_save"))
  end)

  it("includes test summary when tests exist", function()
    local ts = testing.new()
    ts = testing.update_test(ts, { testId = "t1", fullName = "A", status = "Passed" })
    ts = testing.update_test(ts, { testId = "t2", fullName = "B", status = "Failed" })
    local lines = format.format_status_report({
      state = model.new(),
      testing_state = ts,
      coverage_state = coverage.new(),
      daemon_state = daemon.new(),
      active_session = nil,
      config = { port = 37749, dashboard_port = 37750, check_on_save = false },
    })
    local joined = table.concat(lines, "\n")
    assert.is_truthy(joined:find("1 passed"))
    assert.is_truthy(joined:find("1 failed"))
  end)

  it("includes daemon state", function()
    local ds = daemon.new()
    ds = daemon.mark_starting(ds, "MyProj.fsproj", 37749)
    ds = daemon.mark_running(ds, 1234)
    local lines = format.format_status_report({
      state = model.new(),
      testing_state = testing.new(),
      coverage_state = coverage.new(),
      daemon_state = ds,
      active_session = nil,
      config = { port = 37749, dashboard_port = 37750, check_on_save = false },
    })
    local joined = table.concat(lines, "\n")
    assert.is_truthy(joined:find("running") or joined:find("1234"))
  end)
end)


-- ─── parse_bindings: extract FSI val declarations ────────────────────────────

describe("format.parse_bindings", function()
  it("parses a simple val binding", function()
    local bs = format.parse_bindings("val x : int = 42")
    assert.are.equal(1, #bs)
    assert.are.equal("x", bs[1].name)
    assert.are.equal("int", bs[1].type_sig)
  end)

  it("parses multiple bindings", function()
    local bs = format.parse_bindings("val x : int = 42\nval name : string = \"hello\"")
    assert.are.equal(2, #bs)
    assert.are.equal("x", bs[1].name)
    assert.are.equal("name", bs[2].name)
    assert.are.equal("string", bs[2].type_sig)
  end)

  it("parses binding without value", function()
    local bs = format.parse_bindings("val myFunc : int -> string")
    assert.are.equal(1, #bs)
    assert.are.equal("myFunc", bs[1].name)
    assert.are.equal("int -> string", bs[1].type_sig)
  end)

  it("returns empty for non-binding output", function()
    local bs = format.parse_bindings("it = 42")
    assert.are.equal(0, #bs)
  end)

  it("returns empty for nil", function()
    local bs = format.parse_bindings(nil)
    assert.are.equal(0, #bs)
  end)

  it("skips val mutable declarations", function()
    local bs = format.parse_bindings("val mutable x : int = 0")
    assert.are.equal(0, #bs)
  end)

  it("skips val it (REPL auto-binding)", function()
    local bs = format.parse_bindings("val it : int = 42")
    assert.are.equal(0, #bs)
  end)

  it("skips tuple pattern bindings", function()
    local bs = format.parse_bindings("val (x, y) : int * string")
    assert.are.equal(0, #bs)
  end)
end)

-- ─── binding tracker: detect shadowing ───────────────────────────────────────

describe("format.update_bindings", function()
  it("returns no shadows on first binding", function()
    local tracker = format.new_binding_tracker()
    tracker, shadows = format.update_bindings(tracker, "val x : int = 42")
    assert.are.equal(0, #shadows)
    assert.are.equal("int", tracker.bindings["x"].type_sig)
  end)

  it("detects shadow on rebinding", function()
    local tracker = format.new_binding_tracker()
    tracker = format.update_bindings(tracker, "val x : int = 42")
    local shadows
    tracker, shadows = format.update_bindings(tracker, "val x : int = 99")
    assert.are.equal(1, #shadows)
    assert.are.equal("x", shadows[1].name)
    assert.are.equal("int", shadows[1].old_type)
    assert.are.equal("int", shadows[1].new_type)
  end)

  it("detects shadow with type change", function()
    local tracker = format.new_binding_tracker()
    tracker = format.update_bindings(tracker, "val x : int = 42")
    local shadows
    tracker, shadows = format.update_bindings(tracker, "val x : string = \"hello\"")
    assert.are.equal(1, #shadows)
    assert.are.equal("int", shadows[1].old_type)
    assert.are.equal("string", shadows[1].new_type)
  end)

  it("tracks count on repeated shadowing", function()
    local tracker = format.new_binding_tracker()
    tracker = format.update_bindings(tracker, "val x : int = 1")
    tracker = format.update_bindings(tracker, "val x : int = 2")
    tracker = format.update_bindings(tracker, "val x : int = 3")
    assert.are.equal(3, tracker.bindings["x"].count)
  end)
end)

-- ─── format_duration: human-readable eval timing ─────────────────────────────

describe("format.format_duration", function()
  it("formats sub-second as milliseconds", function()
    assert.are.equal("42ms", format.format_duration(42))
  end)

  it("formats exactly 1 second", function()
    assert.are.equal("1.0s", format.format_duration(1000))
  end)

  it("formats multi-second with one decimal", function()
    assert.are.equal("2.5s", format.format_duration(2500))
  end)

  it("formats large durations", function()
    assert.are.equal("10.0s", format.format_duration(10000))
  end)

  it("returns nil for nil input", function()
    assert.is_nil(format.format_duration(nil))
  end)

  it("returns nil for zero", function()
    assert.is_nil(format.format_duration(0))
  end)
end)
