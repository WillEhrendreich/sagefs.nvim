-- transport's HTTP framing, pulled out of http_json so it can be tested without a
-- socket: building a request with extra headers, and reading a response's status,
-- headers and (possibly chunked) body. The raw response below is what the dev
-- daemon sent for an MCP `initialize` on 2026-10-02.
require("spec.helper")
local transport = require("sagefs.transport")

local CHUNK_BODY = 'event: message\ndata: {"result":{"protocolVersion":"2025-06-18"},"id":1,"jsonrpc":"2.0"}\n\n'
local RAW = table.concat({
  "HTTP/1.1 200 OK\r\n",
  "Content-Type: text/event-stream\r\n",
  "Date: Thu, 01 Oct 2026 23:44:20 GMT\r\n",
  "Server: Kestrel\r\n",
  "Cache-Control: no-cache,no-store\r\n",
  "Transfer-Encoding: chunked\r\n",
  "Mcp-Session-Id: 13xDR1rxvkYpGWbddrjnjg\r\n",
  "X-Accel-Buffering: no\r\n",
  "\r\n",
  string.format("%x\r\n%s\r\n0\r\n\r\n", #CHUNK_BODY, CHUNK_BODY),
})

describe("transport.parse_response", function()
  it("reads the status, lower-cased header names, and the de-chunked body", function()
    local r = transport.parse_response(RAW)
    assert.are.equal(200, r.status)
    assert.are.equal("13xDR1rxvkYpGWbddrjnjg", r.headers["mcp-session-id"])
    assert.are.equal("text/event-stream", r.headers["content-type"])
    assert.are.equal(CHUNK_BODY, r.body)
  end)

  it("reads a plain Content-Length response", function()
    local r = transport.parse_response("HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n")
    assert.are.equal(202, r.status)
    assert.are.equal("", r.body)
  end)

  it("reads a 404 with no body", function()
    local r = transport.parse_response("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
    assert.are.equal(404, r.status)
  end)

  it("returns nil for something that is not an HTTP response", function()
    assert.is_nil(transport.parse_response("garbage"))
    assert.is_nil(transport.parse_response(""))
  end)
end)

describe("transport.build_request", function()
  it("adds caller headers after the standard ones and sets the length from the body", function()
    local req = transport.build_request({
      method = "POST", host = "127.0.0.1", port = 37749, path = "/",
      headers = { ["Accept"] = "application/json, text/event-stream", ["Mcp-Session-Id"] = "abc" },
      body = '{"a":1}',
    })
    assert.truthy(req:find("^POST / HTTP/1.1\r\n"))
    assert.truthy(req:find("Host: 127.0.0.1:37749\r\n", 1, true))
    assert.truthy(req:find("Accept: application/json, text/event-stream\r\n", 1, true))
    assert.truthy(req:find("Mcp-Session-Id: abc\r\n", 1, true))
    assert.truthy(req:find("Content-Type: application/json\r\n", 1, true))
    assert.truthy(req:find("Content-Length: 7\r\n", 1, true))
    assert.truthy(req:find('\r\n\r\n{"a":1}$'))
  end)

  it("builds the same request http_json always built when there are no extra headers", function()
    local req = transport.build_request({ method = "GET", host = "127.0.0.1", port = 80, path = "/api/sessions" })
    assert.are.equal("GET /api/sessions HTTP/1.1\r\nHost: 127.0.0.1:80\r\nConnection: close\r\n\r\n", req)
  end)

  it("lets a caller override Content-Type", function()
    local req = transport.build_request({
      method = "POST", host = "h", port = 1, path = "/", headers = { ["Content-Type"] = "text/plain" }, body = "x",
    })
    assert.truthy(req:find("Content-Type: text/plain\r\n", 1, true))
    assert.is_nil(req:find("Content-Type: application/json", 1, true))
  end)
end)
