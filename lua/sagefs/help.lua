-- sagefs/help.lua — :SageFsHelp and the first-run hint
--
-- The command list is read from the live command table (nvim_get_commands),
-- so it cannot drift from what is registered: add a command with a `desc` and
-- it shows up here. The pure builders take plain tables and are tested under
-- busted; the two functions at the bottom touch the editor.
local M = {}

local PREFIX = "SageFs"
local NO_DESC = "(no description)"

--- Rows for every :SageFs* command, sorted by name.
---@param cmds table<string, { name: string, desc: string|nil, definition: string|nil }>
---@return { name: string, desc: string, undescribed: boolean|nil }[]
function M.command_rows(cmds)
  local rows = {}
  for name, c in pairs(cmds or {}) do
    if name:sub(1, #PREFIX) == PREFIX and #name > #PREFIX then
      local desc = c.desc
      if desc == nil or desc == "" then desc = c.definition end
      -- a Lua-callback command with no desc has an empty or placeholder text
      if desc == nil or desc == "" or desc:find("Lua function", 1, true) then desc = nil end
      rows[#rows + 1] = { name = name, desc = desc or NO_DESC, undescribed = desc == nil or nil }
    end
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return rows
end

--- Rows for the SageFs keymaps in a buffer, from their own descriptions.
---@param maps { lhs: string, desc: string|nil }[]
---@return { lhs: string, desc: string }[]
function M.keymap_rows(maps)
  local rows = {}
  for _, m in ipairs(maps or {}) do
    local d = m.desc
    if type(d) == "string" and d:sub(1, 8) == "SageFs: " then
      rows[#rows + 1] = { lhs = m.lhs, desc = d:sub(9) }
    end
  end
  return rows
end

--- The help text.
---@param rows { name: string, desc: string }[]
---@param keymaps { lhs: string, desc: string }[]
---@return string[]
function M.lines(rows, keymaps)
  local lines = {
    string.format("SageFs: %d command%s (type :Sage<Tab> to complete them)", #rows, #rows == 1 and "" or "s"),
    "",
  }
  local width = 0
  for _, r in ipairs(rows) do width = math.max(width, #r.name) end
  for _, r in ipairs(rows) do
    lines[#lines + 1] = string.format("  :%-" .. width .. "s  %s", r.name, r.desc)
  end
  if keymaps and #keymaps > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Keymaps in this buffer"
    local kw = 0
    for _, k in ipairs(keymaps) do kw = math.max(kw, #k.lhs) end
    for _, k in ipairs(keymaps) do
      lines[#lines + 1] = string.format("  %-" .. kw .. "s  %s", k.lhs, k.desc)
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "q closes this window."
  return lines
end

--- The first-run hint: the three most useful things, only the ones registered.
---@param rows { name: string }[]
---@return string[]
function M.hint_lines(rows)
  local have = {}
  for _, r in ipairs(rows or {}) do have[r.name] = true end
  local lines = { "SageFs is attached to this F# buffer. Three things to know:", "" }
  if have.SageFsEval then
    lines[#lines + 1] = "  <A-CR>            evaluate the cell under the cursor (:SageFsEval)"
  end
  if have.SageFsSessions then
    lines[#lines + 1] = "  :SageFsSessions   see, switch or create sessions"
  end
  if have.SageFsHelp then
    lines[#lines + 1] = "  :SageFsHelp       every command, one line each"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Type :Sage<Tab> to complete any of them."
  lines[#lines + 1] = "Shown once. Any key or cursor move dismisses it."
  return lines
end

-- ─── Editor-facing ───────────────────────────────────────────────────────────

--- Open :SageFsHelp for `buf`.
---@param buf number
function M.show_help(buf)
  local rows = M.command_rows(vim.api.nvim_get_commands({}))
  local maps = {}
  for _, mode in ipairs({ "n", "v" }) do
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
      if m.desc then
        maps[#maps + 1] = { lhs = m.lhs, desc = mode == "v" and (m.desc .. " (visual)") or m.desc }
      end
    end
  end
  return require("sagefs.render").show_float(M.lines(rows, M.keymap_rows(maps)), {
    title = "SageFs help", max_height = 40, min_width = 64,
  })
end

local function show_hint_float()
  local lines = M.hint_lines(M.command_rows(vim.api.nvim_get_commands({})))
  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  width = math.min(width + 2, math.max(vim.o.columns - 4, 20))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    anchor = "SE",
    row = math.max(vim.o.lines - 2, #lines + 2),
    col = math.max(vim.o.columns - 1, width + 2),
    width = width,
    height = #lines,
    style = "minimal",
    border = "rounded",
    focusable = false,
    zindex = 40,
  })
  local group = vim.api.nvim_create_augroup("SageFsHint", { clear = true })
  local function close()
    pcall(vim.api.nvim_del_augroup_by_name, "SageFsHint")
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  end
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave", "VimResized" }, {
    group = group, once = true, callback = close,
  })
  vim.defer_fn(close, 20000)
end

--- Show the one-time hint when the plugin first attaches to an F# buffer.
--- Once ever (a marker file, so it survives restarts whatever shada says),
--- off with `hint = false`.
---@param config table plugin config: hint, hint_marker_path
function M.maybe_show_hint(config)
  if config.hint == false then return end
  local marker = config.hint_marker_path or (vim.fn.stdpath("data") .. "/sagefs_hint_seen")
  if vim.fn.filereadable(marker) == 1 then return end
  -- remember first: a hint that crashes must not come back every launch
  pcall(vim.fn.writefile, {}, marker)
  vim.defer_fn(function()
    pcall(show_hint_float)
  end, 1200)
end

return M
