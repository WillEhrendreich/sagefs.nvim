-- A small MCP client over the daemon's streamable HTTP transport, so the plugin
-- can call a tool (get_cohort_status) that has no REST route. The daemon answers
-- with SSE framing (`event: message` / `data: {json-rpc}`) and hands out the
-- session in an `Mcp-Session-Id` response header; both were captured with curl
-- from the dev daemon on 2026-10-02.
require("spec.helper")
local mcp = require("sagefs.mcp_client")
local fx = require("spec.wire_fixtures")

local SSE_RESULT = 'event: message\ndata: {"result":{"content":[{"type":"text","text":"Cohort ledger head: v13853\\nConductor: x\\n"}]},"id":2,"jsonrpc":"2.0"}\n\n'

describe("mcp_client request bodies", function()
  it("initialize names the protocol and the client", function()
    local b = mcp.initialize_body(1)
    assert.are.equal("2.0", b.jsonrpc)
    assert.are.equal("initialize", b.method)
    assert.are.equal(1, b.id)
    assert.are.equal("2025-06-18", b.params.protocolVersion)
    assert.are.equal("sagefs.nvim", b.params.clientInfo.name)
  end)

  it("initialized is a notification: no id", function()
    local b = mcp.initialized_body()
    assert.are.equal("notifications/initialized", b.method)
    assert.is_nil(b.id)
  end)

  it("sends empty arguments as a JSON object, not an array (Lua cannot tell {} from [])", function()
    -- Found live: `arguments = {}` went out as `[]` and the daemon answered "An error occurred."
    local original = vim.empty_dict
    local marker = setmetatable({}, { __tag = "empty_dict" })
    vim.empty_dict = function() return marker end
    local ok, err = pcall(function()
      assert.are.equal(marker, mcp.call_body(1, "get_cohort_status", {}).params.arguments)
      assert.are.equal(marker, mcp.call_body(1, "get_cohort_status", nil).params.arguments)
      assert.are.same({ a = 1 }, mcp.call_body(1, "x", { a = 1 }).params.arguments)
    end)
    vim.empty_dict = original
    assert(ok, err)
  end)

  it("tools/call carries the tool name and arguments", function()
    local b = mcp.call_body(7, "get_cohort_status", {})
    assert.are.equal("tools/call", b.method)
    assert.are.equal(7, b.id)
    assert.are.equal("get_cohort_status", b.params.name)
    assert.are.same({}, b.params.arguments)
  end)
end)

describe("mcp_client.parse_body", function()
  it("reads an SSE-framed json-rpc result", function()
    local r = mcp.parse_body(SSE_RESULT)
    assert.is_true(r.ok)
    assert.are.equal(2, r.id)
    assert.are.equal("Cohort ledger head: v13853\nConductor: x\n", mcp.tool_text(r.result))
  end)

  it("reads a bare JSON body", function()
    local r = mcp.parse_body('{"result":{"content":[{"type":"text","text":"hi"}]},"id":3,"jsonrpc":"2.0"}')
    assert.is_true(r.ok)
    assert.are.equal("hi", mcp.tool_text(r.result))
  end)

  it("reads a json-rpc error as a failure with its message", function()
    local r = mcp.parse_body('event: message\ndata: {"error":{"code":-32602,"message":"Unknown tool"},"id":4,"jsonrpc":"2.0"}\n\n')
    assert.is_false(r.ok)
    assert.are.equal("Unknown tool", r.error)
  end)

  it("takes the last data line when a stream carries several messages", function()
    local body = 'event: message\ndata: {"method":"notifications/message","jsonrpc":"2.0"}\n\n'
      .. 'event: message\ndata: {"result":{"content":[{"type":"text","text":"final"}]},"id":5,"jsonrpc":"2.0"}\n\n'
    assert.are.equal("final", mcp.tool_text(mcp.parse_body(body).result))
  end)

  it("fails readably on an empty or unparseable body", function()
    assert.is_false(mcp.parse_body("").ok)
    assert.is_false(mcp.parse_body(nil).ok)
    assert.is_false(mcp.parse_body("event: message\ndata: {not json\n\n").ok)
  end)

  it("flags a tool result the tool itself marked as an error", function()
    local r = mcp.parse_body('{"result":{"isError":true,"content":[{"type":"text","text":"Error: no cohort owner"}]},"id":6,"jsonrpc":"2.0"}')
    assert.is_true(r.ok)
    assert.is_true(mcp.tool_is_error(r.result))
    assert.are.equal("Error: no cohort owner", mcp.tool_text(r.result))
  end)
end)

describe("mcp_client client: initialize once, reuse the session, recover when it is gone", function()
  local function scripted(responses)
    local calls = {}
    local i = 0
    local function request(opts)
      i = i + 1
      table.insert(calls, opts)
      local r = responses[i]
      assert(r, "unexpected request #" .. i .. " " .. tostring(opts.method))
      opts.callback(r.ok, r.body or "", r.meta or { status = r.ok and 200 or 500, headers = {} })
    end
    return request, calls
  end

  local INIT = { ok = true, body = 'event: message\ndata: {"result":{"protocolVersion":"2025-06-18"},"id":1,"jsonrpc":"2.0"}\n\n',
    meta = { status = 200, headers = { ["mcp-session-id"] = "sess-1" } } }
  local ACK = { ok = true, body = "", meta = { status = 202, headers = {} } }
  local RESULT = { ok = true, body = SSE_RESULT, meta = { status = 200, headers = {} } }

  it("runs initialize, the initialized notification, then the call, each to the root URL with the right headers", function()
    local request, calls = scripted({ INIT, ACK, RESULT })
    local client = mcp.new({ port = 37749, request = request })
    local got
    client.call_tool("get_cohort_status", {}, function(ok, text) got = { ok = ok, text = text } end)
    assert.is_true(got.ok)
    assert.are.equal("Cohort ledger head: v13853\nConductor: x\n", got.text)
    assert.are.equal(3, #calls)
    for _, c in ipairs(calls) do
      assert.are.equal("http://localhost:37749/", c.url)
      assert.are.equal("POST", c.method)
      assert.are.equal("application/json, text/event-stream", c.headers["Accept"])
    end
    assert.is_nil(calls[1].headers["Mcp-Session-Id"])
    assert.are.equal("sess-1", calls[2].headers["Mcp-Session-Id"])
    assert.are.equal("sess-1", calls[3].headers["Mcp-Session-Id"])
    assert.are.equal("initialize", calls[1].body.method)
    assert.are.equal("notifications/initialized", calls[2].body.method)
    assert.are.equal("tools/call", calls[3].body.method)
  end)

  it("reuses the session for the next call: one request, not three", function()
    local request, calls = scripted({ INIT, ACK, RESULT, RESULT })
    local client = mcp.new({ port = 37749, request = request })
    client.call_tool("get_cohort_status", {}, function() end)
    client.call_tool("get_cohort_status", {}, function() end)
    assert.are.equal(4, #calls)
  end)

  it("starts a new session once when the daemon no longer knows the old one (404), then retries the call", function()
    local GONE = { ok = false, body = "", meta = { status = 404, headers = {} } }
    local request, calls = scripted({ INIT, ACK, RESULT, GONE, INIT, ACK, RESULT })
    local client = mcp.new({ port = 37749, request = request })
    client.call_tool("get_cohort_status", {}, function() end)
    local got
    client.call_tool("get_cohort_status", {}, function(ok, text) got = { ok = ok, text = text } end)
    assert.is_true(got.ok)
    assert.are.equal(7, #calls)
  end)

  it("reports a failed initialize, and does not pretend it has a session", function()
    local request = scripted({ { ok = false, body = "connect: ECONNREFUSED", meta = nil } })
    local client = mcp.new({ port = 37749, request = request })
    local got
    client.call_tool("get_cohort_status", {}, function(ok, err) got = { ok = ok, err = err } end)
    assert.is_false(got.ok)
    assert.truthy(got.err:find("ECONNREFUSED", 1, true))
  end)

  it("reports an initialize answer that carries no session header", function()
    local request = scripted({ { ok = true, body = INIT.body, meta = { status = 200, headers = {} } } })
    local client = mcp.new({ port = 37749, request = request })
    local got
    client.call_tool("x", {}, function(ok, err) got = { ok = ok, err = err } end)
    assert.is_false(got.ok)
    assert.truthy(got.err:find("session", 1, true))
  end)

  it("passes a tool-level error through as a failure with the tool's words", function()
    local TOOL_ERR = { ok = true, body = '{"result":{"isError":true,"content":[{"type":"text","text":"Error: no cohort owner"}]},"id":2,"jsonrpc":"2.0"}', meta = { status = 200, headers = {} } }
    local request = scripted({ INIT, ACK, TOOL_ERR })
    local client = mcp.new({ port = 37749, request = request })
    local got
    client.call_tool("get_cohort_status", {}, function(ok, text) got = { ok = ok, text = text } end)
    assert.is_false(got.ok)
    assert.are.equal("Error: no cohort owner", got.text)
  end)

  it("close ends the MCP session it opened, with the session header", function()
    local DELETED = { ok = true, body = "", meta = { status = 200, headers = {} } }
    local request, calls = scripted({ INIT, ACK, RESULT, DELETED })
    local client = mcp.new({ port = 37749, request = request })
    client.call_tool("get_cohort_status", {}, function() end)
    client.close()
    assert.are.equal("DELETE", calls[4].method)
    assert.are.equal("sess-1", calls[4].headers["Mcp-Session-Id"])
  end)

  it("close with no session sends nothing", function()
    local request, calls = scripted({})
    local client = mcp.new({ port = 37749, request = request })
    client.close()
    assert.are.equal(0, #calls)
  end)

  it("uses the real captured status text end to end", function()
    local text = fx.read("cohort-status-idle.txt")
    local body = 'event: message\ndata: ' .. vim.json.encode({ result = { content = { { type = "text", text = text } } }, id = 2, jsonrpc = "2.0" }) .. '\n\n'
    local request = scripted({ INIT, ACK, { ok = true, body = body, meta = { status = 200, headers = {} } } })
    local client = mcp.new({ port = 37749, request = request })
    local got
    client.call_tool("get_cohort_status", {}, function(ok, t) got = { ok = ok, text = t } end)
    assert.are.equal(text, got.text)
  end)
end)
