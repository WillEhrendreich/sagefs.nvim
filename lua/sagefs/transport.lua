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

--- Generic HTTP JSON request via vim.uv TCP (eliminates curl process spawn)
---@param opts { method: string, url: string, body: table|string|nil, timeout: number|nil, callback: fun(ok: boolean, raw: string) }
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

  local function finish(ok, data)
    if completed then return end
    completed = true
    if timer then pcall(timer.stop, timer); pcall(timer.close, timer) end
    pcall(tcp.read_stop, tcp)
    if not tcp:is_closing() then tcp:close() end
    vim.schedule(function() opts.callback(ok, data) end)
  end

  if timer then
    timer:start(timeout_ms, 0, function()
      finish(false, "timeout")
    end)
  end

  tcp:connect(host, port, function(err)
    if err then finish(false, "connect: " .. tostring(err)); return end

    -- Build HTTP/1.1 request
    local req_parts = {
      opts.method .. " " .. path .. " HTTP/1.1\r\n",
      "Host: " .. host .. ":" .. port .. "\r\n",
    }
    if body_str then
      table.insert(req_parts, "Content-Type: application/json\r\n")
      table.insert(req_parts, "Content-Length: " .. #body_str .. "\r\n")
      table.insert(req_parts, "Connection: close\r\n")
      table.insert(req_parts, "\r\n")
      table.insert(req_parts, body_str)
    else
      table.insert(req_parts, "Connection: close\r\n")
      table.insert(req_parts, "\r\n")
    end

    tcp:write(table.concat(req_parts), function(write_err)
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
          -- Strip HTTP headers (find \r\n\r\n boundary)
          local body_start = raw:find("\r\n\r\n")
          if body_start then
            local status_line = raw:sub(1, raw:find("\r\n") or 0)
            local status_code = tonumber(status_line:match("HTTP/%d+%.?%d* (%d+)")) or 0
            local response_body = raw:sub(body_start + 4)
            -- Handle chunked transfer encoding
            if raw:lower():find("transfer%-encoding:%s*chunked") then
              local decoded = {}
              local pos = 1
              while pos <= #response_body do
                local chunk_end = response_body:find("\r\n", pos)
                if not chunk_end then break end
                local chunk_size = tonumber(response_body:sub(pos, chunk_end - 1), 16) or 0
                if chunk_size == 0 then break end
                local chunk_data = response_body:sub(chunk_end + 2, chunk_end + 1 + chunk_size)
                table.insert(decoded, chunk_data)
                pos = chunk_end + 2 + chunk_size + 2
              end
              response_body = table.concat(decoded)
            end
            finish(status_code >= 200 and status_code < 300, response_body)
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
    handle.job_id = vim.fn.jobstart(
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
            local status = sse_parser.connection_status(handle._attempt)
            if opts.on_reconnecting then
              opts.on_reconnecting(handle._attempt, status)
            end
            -- After threshold (5+ attempts), fire on_disconnect even if never connected
            if not was_connected and status == "disconnected" and opts.on_disconnect then
              opts.on_disconnect(code)
            end
            local delay = sse_parser.reconnect_delay(handle._attempt)
            vim.defer_fn(connect, delay)
          end
        end,
      }
    )
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
