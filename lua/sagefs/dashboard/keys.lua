-- sagefs/dashboard/keys.lua — the dashboard's keys, in one place
-- Pure Lua, zero vim dependencies
--
-- The keymaps the dashboard registers and the help section both read this
-- list, so the help cannot list a key that is not mapped or say what it does
-- wrongly. `how` says what the shell does with the key: "close", "next_section",
-- "prev_section", "toggle_section" (digits), "refresh", "context", "toggle_help",
-- or "action" (dispatch the action in `action`).

local M = {}

M.all = {
  { key = "q",       help = "Close dashboard",                             how = "close" },
  { key = "<Tab>",   help = "Next section",                                how = "next_section" },
  { key = "<S-Tab>", help = "Previous section",                            how = "prev_section" },
  { key = "1-9",     help = "Toggle section N",                            how = "toggle_section" },
  { key = "e",       help = "Enable live testing",                         how = "action", action = { type = "enable_testing" } },
  { key = "d",       help = "Disable live testing",                        how = "action", action = { type = "disable_testing" } },
  { key = "h",       help = "Switch workflow (REPL, live testing, hot reload)", how = "action", action = { type = "switch_workflow" } },
  { key = "r",       help = "Run all tests",                               how = "action", action = { type = "run_tests" } },
  { key = "R",       help = "Refresh dashboard",                           how = "refresh" },
  { key = "<CR>",    help = "Context action at cursor",                    how = "context" },
  { key = "?",       help = "Toggle this help",                            how = "toggle_help" },
}

--- The keys as separate left-hand sides: "1-9" becomes "1" .. "9".
--- @return string[]
function M.lhs_list()
  local out = {}
  for _, k in ipairs(M.all) do
    if k.key == "1-9" then
      for i = 1, 9 do table.insert(out, tostring(i)) end
    else
      table.insert(out, k.key)
    end
  end
  return out
end

return M
