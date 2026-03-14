-- sagefs/dashboard/highlights.lua — Highlight group definitions
-- REQUIRES vim — only loaded in Neovim context
--
-- All SageFs dashboard highlight groups are defined here with `default = true`,
-- meaning user highlight overrides and colorscheme-specific configurations
-- take precedence automatically. No fighting with themes.

local M = {}

-- Map of group name → linked standard highlight group.
-- Using links (not explicit fg/bg) means every colorscheme "just works."
M.groups = {
  -- Section headers
  SageFsSectionHeader     = "Title",
  -- Test status
  SageFsTestPassed        = "DiagnosticOk",
  SageFsTestFailed        = "DiagnosticError",
  SageFsTestStale         = "DiagnosticWarn",
  SageFsTestRunning       = "DiagnosticInfo",
  -- Diagnostics
  SageFsDiagError         = "DiagnosticError",
  SageFsDiagWarn          = "DiagnosticWarn",
  SageFsDiagInfo          = "DiagnosticInfo",
  -- Daemon status
  SageFsConnected         = "DiagnosticOk",
  SageFsDisconnected      = "DiagnosticError",
  -- Sessions
  SageFsActiveSession     = "CursorLine",
  SageFsSessionStatus     = "Comment",
  -- Coverage
  SageFsCoverageFull      = "DiagnosticOk",
  SageFsCoveragePartial   = "DiagnosticWarn",
  SageFsCoverageNone      = "DiagnosticError",
  -- Help
  SageFsHelpKey           = "Special",
  -- Eval
  SageFsEvalDuration      = "Number",
  SageFsEvalCellId        = "Identifier",
  -- Alarms
  SageFsAlarm             = "WarningMsg",
  -- Filmstrip
  SageFsFilmstripEntry    = "Comment",
  -- Hot reload
  SageFsHotReloadOn       = "DiagnosticOk",
  SageFsHotReloadOff      = "Comment",
  -- Failure narratives
  SageFsFailureIcon       = "DiagnosticError",
  SageFsFailureName       = "ErrorMsg",
  SageFsFailureSummary    = "Comment",
}

--- Define all highlight groups. Safe to call multiple times.
function M.setup()
  for group, target in pairs(M.groups) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

return M
