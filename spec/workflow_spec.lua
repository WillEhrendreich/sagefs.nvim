-- Tests: sagefs.workflow, the pure half of :SageFsWorkflow (which session
-- workflow to switch to, the request, the daemon's answer). The wire is read off
-- a 0.6.892 daemon:
--   POST /api/sessions/{sid}/workflow {"workflow": "hotreload"}
--   200 {"message":"Hard reset accepted — replacement worker spawning.","sessionId":"9e4357e0","success":true,"workflow":"Hot Reload"}
--   400 {"error":"Error: unknown workflow 'bogus'. Valid values: 'interactive' (REPL), 'livetesting' (Live Testing), 'hotreload' (Hot Reload)","success":false}
--   400 {"error":"invalid session ID format: 'zzz'","success":false}
--   404 {"case":"SessionNotFound","fields":{"sessionId":"deadbeef"},"message":"Session 'deadbeef' not found. ...","suggestedAction":"Run list_sessions ..."}
require("spec.helper")

local W = require("sagefs.workflow")

describe("workflow.CHOICES", function()
  it("are the daemon's three workflows, under the names its error lists", function()
    local tokens = {}
    for _, c in ipairs(W.CHOICES) do table.insert(tokens, c.token) end
    assert.are.same({ "interactive", "livetesting", "hotreload" }, tokens)
  end)

  it("each carries the label the daemon answers with and a sentence about it", function()
    local labels = {}
    for _, c in ipairs(W.CHOICES) do
      labels[c.token] = c.label
      assert.is_true(#c.blurb > 10, c.token)
    end
    assert.are.equal("REPL", labels.interactive)
    assert.are.equal("Live Testing", labels.livetesting)
    assert.are.equal("Hot Reload", labels.hotreload)
  end)
end)

describe("workflow.build_request", function()
  it("posts the workflow to the session's workflow route", function()
    local req = W.build_request("9e4357e0", "hotreload")
    assert.are.equal("POST", req.method)
    assert.are.equal("/api/sessions/9e4357e0/workflow", req.path)
    assert.are.same({ workflow = "hotreload" }, req.body)
  end)

  it("sends what was typed, trimmed and lower-cased, because the daemon owns the aliases", function()
    assert.are.same({ workflow = "live" }, W.build_request("s", "  Live ").body)
    assert.are.same({ workflow = "repl" }, W.build_request("s", "REPL").body)
  end)
end)

describe("workflow.parse_response", function()
  it("reads the accepted switch: the daemon's message and the label it now runs", function()
    local r = W.parse_response(true, '{"message":"Hard reset accepted \\u2014 replacement worker spawning.","sessionId":"9e4357e0","success":true,"workflow":"Hot Reload"}')
    assert.is_true(r.ok)
    assert.are.equal("Hot Reload", r.label)
    assert.are.equal("9e4357e0", r.session_id)
    assert.is_truthy(r.message:find("replacement worker spawning", 1, true))
  end)

  it("shows the daemon's words for an unknown workflow", function()
    local r = W.parse_response(false, [[{"error":"Error: unknown workflow 'bogus'. Valid values: 'interactive' (REPL), 'livetesting' (Live Testing), 'hotreload' (Hot Reload)","success":false}]])
    assert.is_false(r.ok)
    assert.is_truthy(r.error:find("Valid values", 1, true))
  end)

  it("shows the structured error and what to do for a session that is not there", function()
    local r = W.parse_response(false, [[{"case":"SessionNotFound","fields":{"sessionId":"deadbeef"},"message":"Session 'deadbeef' not found. Use list_sessions to see available sessions.","suggestedAction":"Run list_sessions to see available sessions"}]])
    assert.is_false(r.ok)
    assert.is_truthy(r.error:find("not found", 1, true))
    assert.is_truthy(r.error:find("list_sessions", 1, true))
  end)

  it("treats success=false on a 200 as a refusal", function()
    local r = W.parse_response(true, '{"success":false,"error":"nope"}')
    assert.is_false(r.ok)
    assert.are.equal("nope", r.error)
  end)

  it("never raises on a body that is not JSON", function()
    local r = W.parse_response(false, "timeout")
    assert.is_false(r.ok)
    assert.is_truthy(r.error:find("timeout", 1, true))
    assert.is_false(W.parse_response(true, "").ok)
  end)
end)

describe("workflow.complete", function()
  it("offers every name for an empty lead, and only the matching ones for a prefix", function()
    assert.are.same({ "interactive", "livetesting", "hotreload" }, W.complete(""))
    assert.are.same({ "hotreload" }, W.complete("hot"))
    assert.are.same({ "livetesting" }, W.complete("LIVE"))
    assert.are.same({}, W.complete("zzz"))
  end)
end)

describe("workflow.accepted_notice", function()
  it("says the session is now in the workflow, that it restarts in place, and what the daemon said", function()
    local text = W.accepted_notice("abc12345", { label = "Hot Reload", message = "Hard reset accepted - replacement worker spawning." })
    assert.is_truthy(text:find("abc12345", 1, true))
    assert.is_truthy(text:find("Hot Reload", 1, true))
    assert.is_truthy(text:find("restarts in place", 1, true))
    assert.is_truthy(text:find("replacement worker spawning", 1, true))
  end)

  it("does not invent a label or an empty daemon sentence", function()
    local text = W.accepted_notice("abc12345", { label = "", message = "" })
    assert.is_nil(text:find("now \n", 1, true))
    assert.is_nil(text:find("The daemon says", 1, true))
  end)
end)

describe("workflow.picker_items", function()
  it("lists the three choices with the current one marked", function()
    local items = W.picker_items("Hot Reload")
    assert.are.equal(3, #items)
    local marked = 0
    for _, i in ipairs(items) do
      if i.text:find("(current)", 1, true) then marked = marked + 1; assert.are.equal("hotreload", i.token) end
    end
    assert.are.equal(1, marked)
  end)

  it("marks nothing when the current workflow is not known", function()
    for _, i in ipairs(W.picker_items(nil)) do assert.is_nil(i.text:find("(current)", 1, true)) end
  end)
end)
