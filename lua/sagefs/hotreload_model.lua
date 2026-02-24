-- sagefs/hotreload_model.lua — Pure hot reload state model
-- Extracted from hotreload.lua to enable busted testing
-- Zero vim dependencies

local M = {}

-- ─── URL Builder ──────────────────────────────────────────────────────────────

function M.build_url(port, session_id, suffix)
  return string.format(
    "http://localhost:%d/api/sessions/%s/hotreload%s",
    port, session_id, suffix or ""
  )
end

-- ─── State Constructor ────────────────────────────────────────────────────────

function M.new()
  return {
    files = {},
    watched_count = 0,
  }
end

-- ─── Apply Server Response ────────────────────────────────────────────────────

function M.apply_response(state, response)
  if not response then return state end
  state.files = response.files or {}
  state.watched_count = response.watchedCount or 0
  return state
end

-- ─── Picker Formatting ────────────────────────────────────────────────────────

function M.format_picker_items(state)
  if #state.files == 0 then return {} end
  local items = {}
  for _, f in ipairs(state.files) do
    local indicator = f.watched and "●" or "○"
    table.insert(items, {
      label = string.format("%s %s", indicator, f.path),
      path = f.path,
      action = "toggle",
    })
  end
  table.insert(items, { label = "⟳ Watch All", action = "watch_all" })
  table.insert(items, { label = "⊘ Unwatch All", action = "unwatch_all" })
  return items
end

function M.format_prompt(state)
  return string.format("Hot Reload (%d/%d watched)", state.watched_count, #state.files)
end

-- ─── Parse Selection ──────────────────────────────────────────────────────────

function M.parse_selection(selection)
  if not selection then return nil end
  return {
    action = selection.action,
    path = selection.path,
  }
end

return M
