-- sagefs/mcp_client.lua — a small MCP client over the daemon's streamable HTTP transport
--
-- Some daemon surfaces have no REST route (get_cohort_status is one). The daemon
-- serves MCP at its root URL: POST initialize, take the `Mcp-Session-Id` response
-- header, POST the `notifications/initialized` notification, then POST
-- `tools/call`. Replies come SSE-framed (`event: message` / `data: <json-rpc>`).
--
-- The request/response framing is pure and tested (parse_body, the body builders);
-- the session handling takes its `request` function from outside (transport.http_json
-- in production), so it is tested with a scripted one. The client holds one MCP
-- session and reuses it; if the daemon no longer knows it (404), it starts a new
-- one once and retries.

local member_token = require("sagefs.member_token")

local M = {}

local PROTOCOL_VERSION = "2025-06-18"

-- ─── Pure: bodies and replies ────────────────────────────────────────────────

-- Lua cannot tell {} from []: an empty table must be marked as a JSON object, or
-- `arguments` goes out as `[]` and the daemon answers "An error occurred.".
local function object(t)
  if (t == nil or next(t) == nil) and vim.empty_dict then return vim.empty_dict() end
  return t or {}
end

function M.initialize_body(id)
  return {
    jsonrpc = "2.0", id = id, method = "initialize",
    params = {
      protocolVersion = PROTOCOL_VERSION,
      capabilities = object({}),
      clientInfo = { name = "sagefs.nvim", version = "1" },
    },
  }
end

function M.initialized_body()
  return { jsonrpc = "2.0", method = "notifications/initialized" }
end

function M.call_body(id, name, arguments)
  return {
    jsonrpc = "2.0", id = id, method = "tools/call",
    params = { name = name, arguments = object(arguments) },
  }
end

local function decode(s)
  local ok, data = pcall(vim.json.decode, s)
  if ok and type(data) == "table" then return data end
  return nil
end

--- Read a reply body, SSE-framed or bare JSON, into a json-rpc outcome. When a
--- stream carries several messages the last `data:` payload that has a result or
--- an error wins.
---@param raw string|nil
---@return { ok: boolean, result: table|nil, id: any, error: string|nil }
function M.parse_body(raw)
  if type(raw) ~= "string" or raw == "" then
    return { ok = false, error = "empty reply from the daemon" }
  end
  local payloads = {}
  if raw:find("^%s*{") then
    payloads[1] = raw
  else
    for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
      local data = line:match("^data:%s?(.*)$")
      if data and data ~= "" then table.insert(payloads, data) end
    end
  end
  local chosen
  for i = #payloads, 1, -1 do
    local msg = decode(payloads[i])
    if msg == nil then
      return { ok = false, error = "unreadable reply from the daemon" }
    end
    if msg.result ~= nil or msg.error ~= nil then chosen = msg; break end
  end
  if not chosen then return { ok = false, error = "the daemon's reply carried no result" } end
  if chosen.error ~= nil then
    local message = type(chosen.error) == "table" and chosen.error.message or tostring(chosen.error)
    return { ok = false, error = message or "the daemon returned an error", id = chosen.id }
  end
  return { ok = true, result = chosen.result, id = chosen.id }
end

--- A tools/call result's answer: its FIRST text block. When the daemon saw events
--- since the caller's last call it adds the "SageFs events since last call" echo as
--- one more block after the answer (docs/mcp-tools.md, "Reading a tool reply"), so
--- a later block is the daemon talking, never part of the answer, and a tool whose
--- answer is JSON is valid JSON on its own.
---@param result table|nil
---@return string
function M.tool_text(result)
  if type(result) == "table" and type(result.content) == "table" then
    for _, block in ipairs(result.content) do
      if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
        return block.text
      end
    end
  end
  return ""
end

function M.tool_is_error(result)
  return type(result) == "table" and result.isError == true
end

-- ─── The client ──────────────────────────────────────────────────────────────

--- `token` is a member capability token or a function returning one (read on every
--- request); with none, no token header is sent. `log` receives one line per
--- request, with the token left out.
---@param opts { port: number, request: fun(opts: table), token: string|fun():string|nil, log: fun(line: string)|nil }
function M.new(opts)
  local raw_request = opts.request
  local log = opts.log
  local url = string.format("http://localhost:%d/", opts.port)
  local client = {}
  local session_id = nil
  local next_id = 1

  local function current_token()
    local t = opts.token
    if type(t) == "function" then
      local ok, value = pcall(t)
      t = ok and value or nil
    end
    return member_token.resolve(t, nil)
  end

  local function headers(with_session)
    local h = { ["Accept"] = "application/json, text/event-stream" }
    if with_session and session_id then h["Mcp-Session-Id"] = session_id end
    local token = current_token()
    if token then h[member_token.HEADER] = token end
    return h
  end

  local function describe_headers(h)
    local names = {}
    for name in pairs(h) do names[#names + 1] = name end
    table.sort(names)
    local parts = {}
    local safe = member_token.redact_headers(h)
    for _, name in ipairs(names) do
      if name ~= "Accept" and name ~= "Mcp-Session-Id" then parts[#parts + 1] = name .. ": " .. safe[name] end
    end
    return table.concat(parts, ", ")
  end

  local function request(o)
    if log then
      local what = type(o.body) == "table" and (o.body.method or "") or ""
      if what == "tools/call" and o.body.params then what = "tools/call " .. tostring(o.body.params.name) end
      local extra = describe_headers(o.headers or {})
      log(string.format("MCP %s %s %s%s", o.method, o.url, what, extra ~= "" and (" [" .. extra .. "]") or ""))
    end
    raw_request(o)
  end

  -- A failure text can carry whatever the transport or the daemon echoed; a
  -- token in it is hidden. A successful reply is left whole: a mint reply holds
  -- the token on purpose.
  local function fail(cb, text)
    cb(false, member_token.redact(text, current_token()))
  end

  local function take_id()
    local id = next_id
    next_id = next_id + 1
    return id
  end

  local function open_session(cb)
    request({
      method = "POST", url = url, headers = headers(false), body = M.initialize_body(take_id()), timeout = 10,
      callback = function(ok, body, meta)
        if not ok then fail(cb, tostring(body)); return end
        local sid = meta and meta.headers and meta.headers["mcp-session-id"]
        if not sid or sid == "" then
          cb(false, "the daemon did not hand out an MCP session")
          return
        end
        local parsed = M.parse_body(body)
        if not parsed.ok then fail(cb, parsed.error); return end
        session_id = sid
        request({
          method = "POST", url = url, headers = headers(true), body = M.initialized_body(), timeout = 10,
          callback = function(ok2, body2)
            if not ok2 then session_id = nil; fail(cb, tostring(body2)); return end
            cb(true)
          end,
        })
      end,
    })
  end

  local function call(name, args, cb, retried)
    request({
      method = "POST", url = url, headers = headers(true), body = M.call_body(take_id(), name, args), timeout = 30,
      callback = function(ok, body, meta)
        if not ok then
          if meta and meta.status == 404 and not retried then
            session_id = nil
            client.call_tool(name, args, cb, true)
            return
          end
          fail(cb, tostring(body))
          return
        end
        local parsed = M.parse_body(body)
        if not parsed.ok then fail(cb, parsed.error); return end
        local text = M.tool_text(parsed.result)
        if M.tool_is_error(parsed.result) then fail(cb, text) else cb(true, text) end
      end,
    })
  end

  --- Call a tool; cb(ok, text_or_error).
  function client.call_tool(name, args, cb, retried)
    if session_id then
      call(name, args, cb, retried)
      return
    end
    open_session(function(ok, err)
      if not ok then cb(false, err); return end
      call(name, args, cb, true)
    end)
  end

  --- End the MCP session this client opened, if any.
  function client.close()
    if not session_id then return end
    local sid = session_id
    session_id = nil
    local close_headers = headers(false)
    close_headers["Accept"] = nil
    close_headers["Mcp-Session-Id"] = sid
    request({
      method = "DELETE", url = url, headers = close_headers, timeout = 3,
      callback = function() end,
    })
  end

  return client
end

--- The production client: transport.http_json against the daemon's MCP port. The
--- token is read on every request (member_token.current by default); the debug
--- log is off unless `vim.g.sagefs_debug` is set.
---@param port number
---@param token string|fun():string|nil
function M.connect(port, token)
  return M.new({
    port = port,
    request = require("sagefs.transport").http_json,
    token = token or member_token.current,
    log = function(line)
      if vim.g.sagefs_debug then vim.notify("[SageFs debug] " .. line, vim.log.levels.DEBUG) end
    end,
  })
end

return M
