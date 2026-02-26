-- sagefs/transport.lua — HTTP and SSE transport layer
-- Owns curl job management. No state awareness — fires callbacks.

local sse_parser = require("sagefs.sse")

local M = {}

-- ─── HTTP JSON ────────────────────────────────────────────────────────────────

--- Generic HTTP JSON request via curl
---@param opts { method: string, url: string, body: table|string|nil, timeout: number|nil, callback: fun(ok: boolean, raw: string) }
function M.http_json(opts)
  local cmd = {
    "curl", "-X", opts.method, opts.url,
    "-H", "Content-Type: application/json",
    "--max-time", tostring(opts.timeout or 5),
    "--silent", "--show-error",
  }

  local temp_file = nil
  if opts.body then
    local body_str = type(opts.body) == "table"
      and vim.fn.json_encode(opts.body) or opts.body
    if #body_str > 7000 then
      temp_file = vim.fn.tempname() .. ".json"
      local f = io.open(temp_file, "w")
      if f then f:write(body_str); f:close() end
      table.insert(cmd, "-d")
      table.insert(cmd, "@" .. temp_file)
    else
      table.insert(cmd, "-d")
      table.insert(cmd, body_str)
    end
  end

  local stdout_data = {}
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then stdout_data = data end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if temp_file then os.remove(temp_file) end
        local raw = table.concat(stdout_data, "\n")
        opts.callback(exit_code == 0, raw)
      end)
    end,
  })
end

-- ─── SSE Connection ───────────────────────────────────────────────────────────

--- Create a managed SSE connection with auto-reconnect
---@param url string
---@param opts { on_events: fun(events: table[]), on_connect: fun()|nil, on_disconnect: fun(code: number)|nil, auto_reconnect: boolean|nil, reconnect_delay: number|nil }
---@return { start: fun(), stop: fun(), active: fun(): boolean }
function M.connect_sse(url, opts)
  local handle = { job_id = nil, _buffer_parts = {}, _stopped = false, _attempt = 0, _connected = false, _partial = "" }

  local function connect()
    if handle._stopped then return end
    handle._buffer_parts = {}
    handle._partial = ""
    handle._connected = false
    handle._attempt = handle._attempt + 1
    handle.job_id = vim.fn.jobstart(
      { "curl", "--no-buffer", "-N", url, "--silent", "--show-error" },
      {
        on_stdout = function(_, data)
          if not data then return end
          if not handle._connected then
            handle._connected = true
            handle._attempt = 0
            if opts.on_connect then opts.on_connect() end
          end
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
          local was_connected = handle._connected
          handle._connected = false
          if not handle._stopped and was_connected and opts.on_disconnect then
            opts.on_disconnect(code)
          end
          if not handle._stopped and opts.auto_reconnect then
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
