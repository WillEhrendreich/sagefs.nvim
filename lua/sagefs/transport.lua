-- sagefs/transport.lua — HTTP and SSE transport layer
-- Owns HTTP/SSE connections. No state awareness — fires callbacks.

local sse_parser = require("sagefs.sse")

local M = {}

-- ─── HTTP JSON (vim.uv TCP — no curl process spawn) ──────────────────────

--- Parse a URL into host, port, path
---@param url string
---@return string host, number port, string path
local function parse_url(url)
  local host, port, path = url:match("^https?://([^:/]+):?(%d*)(/?.*)")
  host = host or "127.0.0.1"
  -- libuv tcp:connect requires numeric IP, not hostnames
  if host == "localhost" then host = "127.0.0.1" end
  port = tonumber(port) or 80
  path = (path and path ~= "") and path or "/"
  return host, port, path
end

--- Build the HTTP/1.1 request text. `headers` are extra request headers (an MCP
--- client needs Accept and Mcp-Session-Id); a caller header of the same name as a
--- standard one replaces it. With no extra headers this is byte for byte the
--- request http_json always sent.
---@param req { method: string, host: string, port: number, path: string, headers: table<string,string>|nil, body: string|nil }
---@return string
function M.build_request(req)
  local extra = req.headers or {}
  local extra_lower = {}
  for name in pairs(extra) do extra_lower[name:lower()] = true end
  local parts = {
    req.method .. " " .. req.path .. " HTTP/1.1\r\n",
    "Host: " .. req.host .. ":" .. req.port .. "\r\n",
  }
  local names = {}
  for name in pairs(extra) do table.insert(names, name) end
  table.sort(names)
  for _, name in ipairs(names) do
    table.insert(parts, name .. ": " .. extra[name] .. "\r\n")
  end
  if req.body then
    if not extra_lower["content-type"] then
      table.insert(parts, "Content-Type: application/json\r\n")
    end
    table.insert(parts, "Content-Length: " .. #req.body .. "\r\n")
  end
  table.insert(parts, "Connection: close\r\n")
  table.insert(parts, "\r\n")
  if req.body then table.insert(parts, req.body) end
  return table.concat(parts)
end

--- Read a raw HTTP response: status, header map (names lower-cased), and the body
--- with chunked transfer encoding undone. nil when it is not an HTTP response.
---@param raw string
---@return { status: integer, headers: table<string,string>, body: string }|nil
function M.parse_response(raw)
  if type(raw) ~= "string" or raw == "" then return nil end
  local body_start = raw:find("\r\n\r\n", 1, true)
  if not body_start then return nil end
  local head = raw:sub(1, body_start - 1)
  local status_line = head:match("^[^\r]*")
  local status = tonumber(status_line:match("^HTTP/%d+%.?%d* (%d+)"))
  if not status then return nil end
  local headers = {}
  for line in head:gmatch("\r\n([^\r]*)") do
    local name, value = line:match("^([^:]+):%s*(.-)%s*$")
    if name then headers[name:lower()] = value end
  end
  local body = raw:sub(body_start + 4)
  if (headers["transfer-encoding"] or ""):lower():find("chunked", 1, true) then
    local decoded = {}
    local pos = 1
    while pos <= #body do
      local chunk_end = body:find("\r\n", pos, true)
      if not chunk_end then break end
      local chunk_size = tonumber(body:sub(pos, chunk_end - 1), 16) or 0
      if chunk_size == 0 then break end
      table.insert(decoded, body:sub(chunk_end + 2, chunk_end + 1 + chunk_size))
      pos = chunk_end + 2 + chunk_size + 2
    end
    body = table.concat(decoded)
  end
  return { status = status, headers = headers, body = body }
end

--- Generic HTTP JSON request via vim.uv TCP (eliminates curl process spawn).
--- `headers` adds request headers. The callback also receives a third argument,
--- { status = integer, headers = table } (header names lower-cased), once a
--- response was read; it is nil for a failure before one arrived.
---@param opts { method: string, url: string, body: table|string|nil, headers: table<string,string>|nil, timeout: number|nil, callback: fun(ok: boolean, raw: string, meta: table|nil) }
function M.http_json(opts)
  local host, port, path = parse_url(opts.url)
  local body_str = nil
  if opts.body then
    body_str = type(opts.body) == "table" and vim.json.encode(opts.body) or opts.body
  end

  local tcp = vim.uv.new_tcp()
  if not tcp then
    vim.schedule(function() opts.callback(false, "failed to create TCP handle") end)
    return
  end

  -- Timeout watchdog
  local timeout_ms = (opts.timeout or 5) * 1000
  local timer = vim.uv.new_timer()
  local completed = false

  local function finish(ok, data, meta)
    if completed then return end
    completed = true
    if timer then pcall(timer.stop, timer); pcall(timer.close, timer) end
    pcall(tcp.read_stop, tcp)
    if not tcp:is_closing() then tcp:close() end
    vim.schedule(function() opts.callback(ok, data, meta) end)
  end

  if timer then
    timer:start(timeout_ms, 0, function()
      finish(false, "timeout")
    end)
  end

  tcp:connect(host, port, function(err)
    if err then finish(false, "connect: " .. tostring(err)); return end

    local request_text = M.build_request({
      method = opts.method, host = host, port = port, path = path,
      headers = opts.headers, body = body_str,
    })

    tcp:write(request_text, function(write_err)
      if write_err then finish(false, "write: " .. tostring(write_err)); return end

      local response_parts = {}
      tcp:read_start(function(read_err, chunk)
        if read_err then
          finish(false, "read: " .. tostring(read_err))
        elseif chunk then
          table.insert(response_parts, chunk)
        else
          -- EOF — parse response
          local raw = table.concat(response_parts)
          if raw == "" then
            finish(false, "empty response")
            return
          end
          local response = M.parse_response(raw)
          if response then
            local meta = { status = response.status, headers = response.headers }
            finish(response.status >= 200 and response.status < 300, response.body, meta)
          else
            finish(false, raw)
          end
        end
      end)
    end)
  end)
end

-- ─── SSE Connection ───────────────────────────────────────────────────────────

--- Create a managed SSE connection with auto-reconnect
---@param url string
---@param opts { on_events: fun(events: table[]), on_connect: fun()|nil, on_disconnect: fun(code: number)|nil, on_reconnecting: fun(attempt: number, status: string)|nil, auto_reconnect: boolean|nil }
---@return { start: fun(), stop: fun(), active: fun(): boolean }
function M.connect_sse(url, opts)
  local inactivity_ms = (opts.inactivity_timeout or 60) * 1000
  local handle = { job_id = nil, _buffer_parts = {}, _stopped = false, _attempt = 0, _connected = false, _partial = "", _inactivity_timer = nil }

  local function reset_inactivity_timer()
    if handle._inactivity_timer then
      pcall(vim.fn.timer_stop, handle._inactivity_timer)
      handle._inactivity_timer = nil
    end
    if handle._connected and not handle._stopped then
      handle._inactivity_timer = vim.fn.timer_start(inactivity_ms, function()
        if handle._connected and not handle._stopped then
          vim.schedule(function()
            if handle.job_id then
              pcall(vim.fn.jobstop, handle.job_id)
            end
          end)
        end
      end)
    end
  end

  local function connect()
    if handle._stopped then return end
    handle._buffer_parts = {}
    handle._partial = ""
    handle._connected = false
    handle._attempt = handle._attempt + 1
    local job_id, spawn_err = require("sagefs.spawn").jobstart(
      { "curl", "--no-buffer", "-N", "--compressed", url, "--silent", "--show-error" },
      {
        on_stdout = function(_, data)
          if not data then return end
          if not handle._connected then
            handle._connected = true
            handle._attempt = 0
            if opts.on_connect then opts.on_connect() end
          end
          reset_inactivity_timer()
          -- Neovim splits stdout on newlines: last element is a partial line
          -- that continues into the next callback. Join it with the previous partial.
          data[1] = handle._partial .. data[1]
          handle._partial = data[#data]
          for i = 1, #data - 1 do
            table.insert(handle._buffer_parts, data[i])
            table.insert(handle._buffer_parts, "\n")
          end
          local buffer = table.concat(handle._buffer_parts)
          local events, remainder = sse_parser.parse_chunk(buffer)
          handle._buffer_parts = { remainder }
          if #events > 0 and opts.on_events then
            opts.on_events(events)
          end
        end,
        on_exit = function(_, code)
          handle.job_id = nil
          if handle._inactivity_timer then
            pcall(vim.fn.timer_stop, handle._inactivity_timer)
            handle._inactivity_timer = nil
          end
          local was_connected = handle._connected
          handle._connected = false
          if not handle._stopped and was_connected and opts.on_disconnect then
            opts.on_disconnect(code)
          end
          if not handle._stopped and opts.auto_reconnect then
            local reconnect_attempt = was_connected and 1 or handle._attempt
            local status = sse_parser.connection_status(reconnect_attempt)
            if opts.on_reconnecting then
              opts.on_reconnecting(reconnect_attempt, status)
            end
            -- After threshold (5+ attempts), fire on_disconnect even if never connected
            if not was_connected and status == "disconnected" and opts.on_disconnect then
              opts.on_disconnect(code)
            end
            local delay = sse_parser.reconnect_delay(reconnect_attempt)
            vim.defer_fn(connect, delay)
          end
        end,
      }
    )
    if not job_id then
      -- curl is missing or cannot be spawned. Retrying cannot fix that, so
      -- report once and stop instead of looping or raising.
      handle.job_id = nil
      handle._stopped = true
      if opts.on_spawn_error then
        opts.on_spawn_error(spawn_err)
      end
      return
    end
    handle.job_id = job_id
  end

  function handle.start()
    handle._stopped = false
    connect()
  end

  function handle.stop()
    handle._stopped = true
    if handle._inactivity_timer then
      pcall(vim.fn.timer_stop, handle._inactivity_timer)
      handle._inactivity_timer = nil
    end
    if handle.job_id then
      pcall(vim.fn.jobstop, handle.job_id)
      handle.job_id = nil
    end
  end

  function handle.active()
    return handle.job_id ~= nil and handle.job_id > 0
  end

  return handle
end

return M
