-- sagefs/hotreload.lua — Hot reload file selection for Neovim
-- Shows hot-reload file state via signs + provides toggle/watch-all/unwatch-all commands

local M = {}

-- ─── State ───────────────────────────────────────────────────────────────────

M.files = {}       -- { path = string, watched = bool }[]
M.watched_count = 0
local ns = nil     -- sign namespace
local dashboard_port = 37750

-- ─── HTTP Helpers ────────────────────────────────────────────────────────────

local function hot_reload_url(session_id, endpoint)
  return string.format(
    "http://localhost:%d/api/sessions/%s/hotreload%s",
    dashboard_port, session_id, endpoint or ""
  )
end

local function http_get(url, callback)
  local stdout_data = {}
  vim.fn.jobstart(
    { "curl", "-s", "--max-time", "5", url },
    {
      stdout_buffered = true,
      on_stdout = function(_, data)
        if data then stdout_data = data end
      end,
      on_exit = function(_, exit_code)
        vim.schedule(function()
          callback(exit_code == 0, table.concat(stdout_data, "\n"))
        end)
      end,
    }
  )
end

local function http_post(url, body, callback)
  local json = body and vim.fn.json_encode(body) or "{}"
  local stdout_data = {}
  vim.fn.jobstart(
    { "curl", "-X", "POST", url, "-H", "Content-Type: application/json",
      "-d", json, "--max-time", "5", "-s" },
    {
      stdout_buffered = true,
      on_stdout = function(_, data)
        if data then stdout_data = data end
      end,
      on_exit = function(_, exit_code)
        vim.schedule(function()
          if callback then
            callback(exit_code == 0, table.concat(stdout_data, "\n"))
          end
        end)
      end,
    }
  )
end

-- ─── API ─────────────────────────────────────────────────────────────────────

function M.fetch_state(session_id, callback)
  http_get(hot_reload_url(session_id, ""), function(ok, raw)
    if ok and raw ~= "" then
      local decoded = vim.fn.json_decode(raw)
      if decoded and decoded.files then
        M.files = decoded.files
        M.watched_count = decoded.watchedCount or 0
      end
    else
      M.files = {}
      M.watched_count = 0
    end
    if callback then callback() end
  end)
end

function M.toggle(session_id, path, callback)
  http_post(hot_reload_url(session_id, "/toggle"), { path = path }, function(ok)
    if ok then
      M.fetch_state(session_id, callback)
    elseif callback then
      callback()
    end
  end)
end

function M.watch_all(session_id, callback)
  http_post(hot_reload_url(session_id, "/watch-all"), nil, function(ok)
    if ok then
      M.fetch_state(session_id, callback)
    elseif callback then
      callback()
    end
  end)
end

function M.unwatch_all(session_id, callback)
  http_post(hot_reload_url(session_id, "/unwatch-all"), nil, function(ok)
    if ok then
      M.fetch_state(session_id, callback)
    elseif callback then
      callback()
    end
  end)
end

-- ─── Telescope-style Picker ──────────────────────────────────────────────────

function M.picker(session_id)
  if not session_id then
    vim.notify("[SageFs] No active session", vim.log.levels.WARN)
    return
  end

  M.fetch_state(session_id, function()
    if #M.files == 0 then
      vim.notify("[SageFs] No project files found", vim.log.levels.WARN)
      return
    end

    local items = {}
    local lookup = {}

    for _, f in ipairs(M.files) do
      local icon = f.watched and "●" or "○"
      local label = string.format("%s %s", icon, f.path)
      table.insert(items, label)
      lookup[label] = f.path
    end

    -- Add bulk actions
    local watch_all_label = "▶ Watch All"
    local unwatch_all_label = "■ Unwatch All"
    table.insert(items, 1, watch_all_label)
    table.insert(items, 2, unwatch_all_label)

    vim.ui.select(items, {
      prompt = string.format("Hot Reload Files (%d/%d watched):", M.watched_count, #M.files),
    }, function(choice)
      if not choice then return end

      if choice == watch_all_label then
        M.watch_all(session_id, function()
          vim.notify(string.format("[SageFs] Watching all %d files", #M.files))
        end)
      elseif choice == unwatch_all_label then
        M.unwatch_all(session_id, function()
          vim.notify("[SageFs] Unwatched all files")
        end)
      else
        local path = lookup[choice]
        if path then
          M.toggle(session_id, path, function()
            -- Re-open picker to show updated state
            M.picker(session_id)
          end)
        end
      end
    end)
  end)
end

-- ─── Setup ───────────────────────────────────────────────────────────────────

function M.setup(port)
  dashboard_port = port or 37750
  ns = vim.api.nvim_create_namespace("sagefs_hotreload")
end

return M
