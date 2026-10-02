local M = {}

-- ─── Named constants ─────────────────────────────────────────────────────────
-- Timings and keys the display layer shares. Named here so a spec, the docs
-- and the code can all point at one definition.

--- An eval with no result after this long gets a "why is nothing happening"
--- status (session warming, daemon unreachable, still running) instead of a
--- blank screen.
M.EVAL_SLOW_AFTER_MS = 4000

--- While an eval is still pending, the status is refreshed from the daemon
--- this often.
M.EVAL_STATUS_POLL_MS = 3000

--- The key that opens the full result of the cell under the cursor in a float.
--- Shown in the "N more lines, <key> to expand" footer.
M.EXPAND_RESULT_KEY = "<leader>rE"

--- While the plugin's session reads Starting/Building/Restarting/WarmingUp,
--- the session list is re-read this often until it does not. The daemon
--- answers a create request only once the session is up, so the events that
--- announce readiness can come before the reply and be missed.
M.SESSION_WARMUP_POLL_MS = 2000

--- Result rows drawn under a cell before the footer takes over.
M.RESULT_MAX_LINES = 12

local sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, sep)
end

function M.config_path(working_dir)
  return join_path(working_dir, ".SageFs", "config.fsx")
end

function M.auto_open_opt_out_template()
  return "{ DirectoryConfig.empty with\n  AutoOpenNamespaces = false\n}\n"
end

function M.ensure_auto_open_opt_out(working_dir)
  local path = M.config_path(working_dir)
  local config_dir = join_path(working_dir, ".SageFs")

  if vim.fn.filereadable(path) == 0 then
    vim.fn.mkdir(config_dir, "p")
    vim.fn.writefile(vim.split(M.auto_open_opt_out_template(), "\n", { plain = true }), path)
    return { status = "created", path = path }
  end

  local content = table.concat(vim.fn.readfile(path), "\n")
  if content:find("AutoOpenNamespaces = false", 1, true)
    or content:find("AutoOpenNamespaces=false", 1, true) then
    return { status = "already_disabled", path = path }
  end

  return { status = "requires_manual_edit", path = path }
end

return M
