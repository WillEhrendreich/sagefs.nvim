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

--- The text blocks of a tools/call result, joined.
---@param result table|nil
---@return string
function M.tool_text(result)
  local out = {}
  if type(result) == "table" and type(result.content) == "table" then
    for _, block in ipairs(result.content) do
      if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
        table.insert(out, block.text)
      end
    end
  end
  return table.concat(out, "\n")
end

function M.tool_is_error(result)
  return type(result) == "table" and result.isError == true
end

-- ─── The client ──────────────────────────────────────────────────────────────

---@param opts { port: number, request: fun(opts: table) }
function M.new(opts)
  local request = opts.request
  local url = string.format("http://localhost:%d/", opts.port)
  local client = {}
  local session_id = nil
  local next_id = 1

  local function headers(with_session)
    local h = { ["Accept"] = "application/json, text/event-stream" }
    if with_session and session_id then h["Mcp-Session-Id"] = session_id end
    return h
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
        if not ok then cb(false, tostring(body)); return end
        local sid = meta and meta.headers and meta.headers["mcp-session-id"]
        if not sid or sid == "" then
          cb(false, "the daemon did not hand out an MCP session")
          return
        end
        local parsed = M.parse_body(body)
        if not parsed.ok then cb(false, parsed.error); return end
        session_id = sid
        request({
          method = "POST", url = url, headers = headers(true), body = M.initialized_body(), timeout = 10,
          callback = function(ok2, body2)
            if not ok2 then session_id = nil; cb(false, tostring(body2)); return end
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
          cb(false, tostring(body))
          return
        end
        local parsed = M.parse_body(body)
        if not parsed.ok then cb(false, parsed.error); return end
        local text = M.tool_text(parsed.result)
        cb(not M.tool_is_error(parsed.result), text)
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
    request({
      method = "DELETE", url = url, headers = { ["Mcp-Session-Id"] = sid }, timeout = 3,
      callback = function() end,
    })
  end

  return client
end

--- The production client: transport.http_json against the daemon's MCP port.
---@param port number
function M.connect(port)
  return M.new({ port = port, request = require("sagefs.transport").http_json })
end

return M
