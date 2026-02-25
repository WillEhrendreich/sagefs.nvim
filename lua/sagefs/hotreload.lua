-- sagefs/hotreload.lua — Hot reload file selection for Neovim
-- Uses transport.lua for HTTP, hotreload_model.lua for pure logic

local transport = require("sagefs.transport")
local hr_model = require("sagefs.hotreload_model")

local M = {}

-- ─── State ───────────────────────────────────────────────────────────────────

M.state = hr_model.new()
local dashboard_port = 37750

-- ─── API ─────────────────────────────────────────────────────────────────────

function M.fetch_state(session_id, callback)
  transport.http_json({
    method = "GET",
    url = hr_model.build_url(dashboard_port, session_id, ""),
    callback = function(ok, raw)
      if ok and raw ~= "" then
        local decoded = vim.fn.json_decode(raw)
        hr_model.apply_response(M.state, decoded)
      else
        M.state = hr_model.new()
      end
      if callback then callback() end
    end,
  })
end

function M.toggle(session_id, path, callback)
  transport.http_json({
    method = "POST",
    url = hr_model.build_url(dashboard_port, session_id, "/toggle"),
    body = { path = path },
    callback = function(ok)
      if ok then
        M.fetch_state(session_id, callback)
      elseif callback then
        callback()
      end
    end,
  })
end

function M.watch_all(session_id, callback)
  transport.http_json({
    method = "POST",
    url = hr_model.build_url(dashboard_port, session_id, "/watch-all"),
    callback = function(ok)
      if ok then
        M.fetch_state(session_id, callback)
      elseif callback then
        callback()
      end
    end,
  })
end

function M.unwatch_all(session_id, callback)
  transport.http_json({
    method = "POST",
    url = hr_model.build_url(dashboard_port, session_id, "/unwatch-all"),
    callback = function(ok)
      if ok then
        M.fetch_state(session_id, callback)
      elseif callback then
        callback()
      end
    end,
  })
end

-- ─── Picker ──────────────────────────────────────────────────────────────────

function M.picker(session_id)
  if not session_id then
    vim.notify("[SageFs] No active session", vim.log.levels.WARN)
    return
  end

  M.fetch_state(session_id, function()
    local picker_items = hr_model.format_picker_items(M.state)
    if #picker_items == 0 then
      vim.notify("[SageFs] No project files found", vim.log.levels.WARN)
      return
    end

    local labels = {}
    local lookup = {}
    for _, item in ipairs(picker_items) do
      table.insert(labels, item.label)
      lookup[item.label] = item
    end

    vim.ui.select(labels, {
      prompt = hr_model.format_prompt(M.state),
    }, function(choice)
      if not choice then return end
      local item = lookup[choice]
      if not item then return end

      local sel = hr_model.parse_selection(item)
      if not sel then return end

      if sel.action == "watch_all" then
        M.watch_all(session_id, function()
          vim.notify(string.format("[SageFs] Watching all %d files", #M.state.files))
        end)
      elseif sel.action == "unwatch_all" then
        M.unwatch_all(session_id, function()
          vim.notify("[SageFs] Unwatched all files")
        end)
      elseif sel.action == "toggle" and sel.path then
        M.toggle(session_id, sel.path, function()
          M.picker(session_id)
        end)
      end
    end)
  end)
end

-- ─── Setup ───────────────────────────────────────────────────────────────────

function M.setup(port)
  dashboard_port = port or 37750
end

return M
