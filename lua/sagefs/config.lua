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

--- The scrub keys: press (or hold — the terminal or GUI repeats the key) either
--- to move the value under the cursor up or down, one nudge per press, the way a
--- knob turns. They run :SageFsNudge's own flow, so every press is a journaled
--- write through the daemon's nudge_value tool, with its refusals and its undo
--- (SageFs docs/roadmap.md: "a scrub key in Neovim ... writing through the nudge
--- door so the same rules and the same undo apply"). Single Alt keys, not a
--- `<leader>` sequence: holding the last key of a sequence would not repeat the
--- map. j/k for down/up, like Alt-drag on the dashboard's knob. Buffer-local,
--- registered when an F# buffer attaches — set either here before that to
--- remap, or over the buffer-local map afterwards.
M.SCRUB_UP_KEY = "<A-k>"
M.SCRUB_DOWN_KEY = "<A-j>"

--- While the plugin's session reads Starting/Building/Restarting/WarmingUp,
--- the session list is re-read this often until it does not. The daemon
--- answers a create request only once the session is up, so the events that
--- announce readiness can come before the reply and be missed.
M.SESSION_WARMUP_POLL_MS = 2000

--- After a hard reset the daemon builds in the background; the session list is
--- re-read this often until its lastRestart says how the rebuild ended.
M.REBUILD_POLL_MS = 2000

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
    local ok, err = require("sagefs.fileio").write_file(
      path, vim.split(M.auto_open_opt_out_template(), "\n", { plain = true }))
    if not ok then
      return { status = "failed", path = path, error = err }
    end
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
