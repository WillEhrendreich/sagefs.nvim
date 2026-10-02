-- sagefs/reload_ui.lua — the editor surfaces of the hot reload truth
-- REQUIRES vim — the impure shell around reload_state's display
--
-- Highlight groups, and one virtual-text mark on the first line of the file the
-- last save touched ("◐ applied, new body has not run yet"). The words come from
-- reload_state.display, the same function the statusline and the panel use. A
-- settled harmless verdict (patched, kept, no effect) clears itself after its
-- fade; a pending patch, a restart or a compile failure stays until the next
-- report replaces it.

local reload_state = require("sagefs.reload_state")
local repl_freshness = require("sagefs.repl_freshness")

local M = {}

local ns = nil
local files = {}   -- session id -> last file a save touched (a path, or a bare name while compiling)
local marks = {}   -- bufnr -> { id = extmark id, token = integer }
local token = 0

local function namespace()
  if not ns then ns = vim.api.nvim_create_namespace("sagefs_reload") end
  return ns
end

--- Define the highlight groups (default links, so a colorscheme can override).
function M.setup()
  for group, target in pairs(reload_state.HL) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
  for group, target in pairs(repl_freshness.HL) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

--- Remember the file a save is about, from a compiling frame or fileReloaded.
function M.note_file(sid, path)
  if type(path) == "string" and path ~= "" then files[sid or "?"] = path end
end

local function find_buffer(path)
  if not path then return nil end
  local base = path:match("([^/\\]+)$")
  local fallback
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name == path then return buf end
      if not fallback and base and name:sub(-(#base + 1)) == "/" .. base then fallback = buf end
    end
  end
  return fallback
end

local function clear_buffer(buf)
  local mark = marks[buf]
  if mark and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_del_extmark, buf, namespace(), mark.id)
  end
  marks[buf] = nil
end

--- Show a display on the first line of the session's last-saved file.
---@param sid string
---@param display table from reload_state.display
function M.show(sid, display)
  local buf = find_buffer(files[sid or "?"])
  if not buf then return end
  clear_buffer(buf)
  token = token + 1
  local my_token = token
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, namespace(), 0, 0, {
    virt_text = { { " " .. display.icon .. " " .. display.text, display.hl } },
    virt_text_pos = "eol",
  })
  if not ok then return end
  marks[buf] = { id = id, token = my_token }
  if display.fade_ms then
    vim.defer_fn(function()
      if marks[buf] and marks[buf].token == my_token then clear_buffer(buf) end
    end, display.fade_ms)
  end
end

--- Remove the mark for a session's file.
function M.clear(sid)
  local buf = find_buffer(files[sid or "?"])
  if buf then clear_buffer(buf) end
end

return M
