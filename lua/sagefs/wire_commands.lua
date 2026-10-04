-- sagefs/wire_commands.lua: :SageFsReloadStatus, :SageFsCohort and the member token commands
-- REQUIRES vim: thin registration, the words come from pure modules

local M = {}

--- Show highlighted lines in a small floating window; `q` closes it.
local function float(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  local texts = {}
  local width = 40
  for i, l in ipairs(lines) do
    texts[i] = l.text
    width = math.max(width, vim.fn.strdisplaywidth(l.text) + 4)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  local ns = vim.api.nvim_create_namespace("sagefs_reload_status")
  for i, l in ipairs(lines) do
    if l.hl then pcall(vim.api.nvim_buf_add_highlight, buf, ns, l.hl, i - 1, 0, #l.text) end
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  width = math.min(width, vim.o.columns - 4)
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = math.min(#texts, vim.o.lines - 4),
    row = math.floor((vim.o.lines - #texts) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " SageFs hot reload ",
  })
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, silent = true })
end

---@param plugin table the sagefs plugin module (init.lua's M)
function M.register(plugin)
  vim.api.nvim_create_user_command("SageFsReloadStatus", function()
    float(plugin.wire_runtime().report_lines())
  end, { desc = "What the last save did to the running app, and whether the REPL is behind it" })

  require("sagefs.cohort_view").register(function() return plugin.config.port end)
  require("sagefs.member_view").register(function() return plugin.config.port end)
  require("sagefs.hygiene_view").register(function() return plugin.config.port end)
end

return M
