-- Gap 3: POST /exec carries the structured replFreshness the plugin needs.
--
-- The daemon already knows, for every session, whether the REPL and live tests run
-- the same build as the app (`SageFs.ReplFreshness`, sent on /api/sessions and in
-- get_session_status). An eval goes through POST /exec, and that reply carried
-- neither the object nor any hint of it, so an editor could not say "the REPL is
-- BEHIND the app" at the moment it matters: right after the eval that ran the old
-- body.
--
-- The rule that shapes these tests: the daemon Will runs is whatever was last
-- installed, and the plugin reaches users commit by commit against it. A daemon
-- older than this field sends no `replFreshness` at all, and the plugin must show
-- NOTHING then, not an error and not a false "in sync".

local format = require("sagefs.format")
local repl_freshness = require("sagefs.repl_freshness")

describe("format.parse_exec_response reads the structured replFreshness off /exec", function()
  it("carries the object when the daemon sends it, so an eval can warn about the REPL being behind", function()
    local body = '{"success":true,"result":"41","replFreshness":{"state":"BehindApp","savesSince":2,"declarations":["Foo.bar","Baz"],"message":"The REPL is BEHIND the app."}}'
    local result = format.parse_exec_response(body)
    assert.is_true(result.ok)
    assert.are.equal("41", result.output)

    local f = repl_freshness.parse(result.replFreshness)
    assert.is_table(f, "the /exec reply carried a parsable replFreshness")
    assert.are.equal("BehindApp", f.state)
    assert.are.equal(2, f.saves_since)
    assert.are.same({ "Foo.bar", "Baz" }, f.declarations)
    assert.is_true(repl_freshness.is_behind(f))
  end)

  it("reads the level state too, and does not call it behind", function()
    local body = '{"success":true,"result":"1","replFreshness":{"state":"InSync"}}'
    local result = format.parse_exec_response(body)
    local f = repl_freshness.parse(result.replFreshness)
    assert.is_table(f)
    assert.are.equal("InSync", f.state)
    assert.is_false(repl_freshness.is_behind(f))
    assert.are.equal("", repl_freshness.segment(f))
  end)

  it("still reads the result when the daemon sends a freshness it does not know", function()
    local body = '{"success":true,"result":"1","replFreshness":{"state":"AheadOfDisk"}}'
    local result = format.parse_exec_response(body)
    assert.is_true(result.ok)
    assert.are.equal("1", result.output)
    local f = repl_freshness.parse(result.replFreshness)
    assert.is_table(f)
    assert.is_false(f.known, "an unknown state is shown as unknown, never guessed at")
    assert.is_false(repl_freshness.is_behind(f))
  end)
end)

describe("a DEPRECATED daemon that sends no replFreshness on /exec degrades quietly", function()
  -- This is the hard requirement, not a nicety: the plugin ships commit by commit
  -- against whatever daemon the user last installed. A missing field must be
  -- absent, never an error and never read as "in sync".

  it("leaves replFreshness nil on an older daemon's reply", function()
    local body = '{"success":true,"result":"41"}'
    local result = format.parse_exec_response(body)
    assert.is_true(result.ok, "the reply still parses and the eval still succeeded")
    assert.are.equal("41", result.output)
    assert.is_nil(result.replFreshness, "nothing is invented for a daemon that sent nothing")
  end)

  it("renders no statusline segment and no eval message for an absent state", function()
    local f = repl_freshness.parse(nil)
    assert.is_nil(f)
    assert.are.equal("", repl_freshness.segment(f))
    assert.is_nil(repl_freshness.eval_message(f))
    assert.are.same({}, repl_freshness.lines(f))
  end)

  it("renders no eval message for a malformed field rather than failing", function()
    local result = format.parse_exec_response('{"success":true,"result":"1","replFreshness":"BehindApp"}')
    assert.is_true(result.ok)
    assert.is_nil(result.replFreshness)
    assert.are.equal("", repl_freshness.segment(repl_freshness.parse(result.replFreshness)))
  end)

  it("renders no eval message when the object has no state", function()
    local result = format.parse_exec_response('{"success":true,"result":"1","replFreshness":{"savesSince":1}}')
    assert.is_true(result.ok)
    assert.is_nil(result.replFreshness, "an object without a state is not a freshness")
  end)

  it("still carries the eval output on a failed eval from an older daemon", function()
    local body = '{"success":false,"result":"Ticker.fs(12,3): error FS0039","error":"Ticker.fs(12,3): error FS0039"}'
    local result = format.parse_exec_response(body)
    assert.is_false(result.ok)
    assert.are.equal("Ticker.fs(12,3): error FS0039", result.error)
    assert.is_nil(result.replFreshness)
  end)
end)
