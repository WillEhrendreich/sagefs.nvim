-- sagefs/format.lua — Result formatting for extmarks and virtual text
-- Pure Lua, no vim API dependencies — fully testable with busted
local M = {}

local MAX_INLINE_LEN = 120
local MAX_VIRTUAL_LINES = 20

-- Simple JSON decoder for busted tests (outside Neovim)
local function json_decode(s)
  -- Try vim.json first (available in Neovim), fall back to vim.fn
  if vim and vim.json and vim.json.decode then
    return pcall(vim.json.decode, s)
  elseif vim and vim.fn and vim.fn.json_decode then
    return pcall(vim.fn.json_decode, s)
  end
  return false, "no JSON decoder available"
end

--- Parse the JSON response from POST /exec
---@param json_str string|nil
---@return {ok: boolean, output: string?, error: string?}
function M.parse_exec_response(json_str)
  if not json_str or json_str == "" then
    return { ok = false, error = "empty response" }
  end

  local ok, data = json_decode(json_str)
  if not ok or type(data) ~= "table" then
    return { ok = false, error = "invalid JSON: " .. tostring(json_str) }
  end

  local result
  if data.success then
    result = { ok = true, output = data.result or "" }
  else
    result = { ok = false, error = data.result or data.error or "unknown error" }
  end

  -- Pass through structured diagnostics if present (from JSON format)
  if data.diagnostics and type(data.diagnostics) == "table" then
    result.diagnostics = data.diagnostics
  end

  return result
end

--- Format a duration in milliseconds for human display.
---@param ms number|nil Duration in milliseconds
---@return string|nil Formatted string like "42ms" or "2.5s"
function M.format_duration(ms)
  if not ms or ms == 0 then return nil end
  if ms < 1000 then
    return string.format("%dms", ms)
  else
    return string.format("%.1fs", ms / 1000)
  end
end

--- Format result for inline extmark (single line, truncated)
---@param result {ok: boolean, output: string?, error: string?, duration_ms: number?}
---@return {text: string, hl: string}
function M.format_inline(result)
  local text, hl

  if result.stale then
    hl = "SageFsStale"
    text = result.output or ""
    text = text:gsub("\r", "")
    local first_line = text:match("^([^\n]*)")
    if first_line then text = first_line end
    if (result.output or ""):find("\n") then
      text = text .. " …"
    end
    if #text > MAX_INLINE_LEN then
      text = text:sub(1, MAX_INLINE_LEN - 1) .. "…"
    end
    return { text = "~ " .. text, hl = hl }
  end

  if result.ok then
    hl = "SageFsSuccess"
    text = result.output or ""
    -- Strip \r from Windows line endings
    text = text:gsub("\r", "")
    -- Take first line only for inline display
    local first_line = text:match("^([^\n]*)")
    if first_line then text = first_line end
    -- Indicate more lines exist
    if (result.output or ""):find("\n") then
      text = text .. " …"
    end
  else
    hl = "SageFsError"
    text = result.error or "error"
    local first_line = text:match("^([^\n]*)")
    if first_line then text = first_line end
  end

  -- Truncate long output
  if #text > MAX_INLINE_LEN then
    text = text:sub(1, MAX_INLINE_LEN - 1) .. "…"
  end

  -- Prefix with status indicator
  local prefix = result.ok and "→ " or "✖ "
  text = prefix .. text

  -- Append duration if available
  local dur = M.format_duration(result.duration_ms)
  if dur then
    text = text .. "  " .. dur
  end

  return { text = text, hl = hl }
end

--- Format result for virtual lines display (below ;;)
---@param result {ok: boolean, output: string?, error: string?}
---@return {text: string, hl: string}[]
function M.format_virtual_lines(result)
  local hl = result.stale and "SageFsStale" or (result.ok and "SageFsOutput" or "SageFsError")
  local raw = result.ok and (result.output or "") or (result.error or "error")
  raw = raw:gsub("\r", "")

  if raw == "" then
    return { { text = "(no output)", hl = hl } }
  end

  local lines = {}
  for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, { text = "  " .. line, hl = hl })
    if #lines >= MAX_VIRTUAL_LINES - 1 then
      table.insert(lines, { text = "  … (truncated)", hl = hl })
      break
    end
  end

  return lines
end

--- Get gutter sign for a cell status
---@param status string "success"|"error"|"running"|"stale"|"idle"
---@return {text: string, hl: string}
function M.gutter_sign(status)
  if status == "success" then
    return { text = "✓", hl = "SageFsSuccess" }
  elseif status == "error" then
    return { text = "✖", hl = "SageFsError" }
  elseif status == "running" then
    return { text = "⏳", hl = "SageFsRunning" }
  elseif status == "stale" then
    return { text = "~", hl = "SageFsStale" }
  else
    return { text = " ", hl = "Normal" }
  end
end

--- Build extmark render options from cell state
---@param cell {status: string, output: string?}
---@param cell_id number
---@return table|nil
function M.build_render_options(cell, cell_id)
  if not cell or cell.status == "idle" then
    return nil
  end

  local sign = M.gutter_sign(cell.status)

  if cell.status == "running" then
    return { sign = sign }
  end

  local is_stale = cell.status == "stale"
  local is_ok = cell.status == "success" or is_stale
  local result
  if is_ok then
    result = { ok = true, output = cell.output, stale = is_stale, duration_ms = cell.duration_ms }
  else
    result = { ok = false, error = cell.output, duration_ms = cell.duration_ms }
  end

  local opts = {
    sign = sign,
    inline = M.format_inline(result),
    virtual_lines = M.format_virtual_lines(result),
  }

  if is_stale then
    opts.codelens = { text = "▶ Eval", hl = "SageFsCodeLensStale" }
  end

  return opts
end

--- Build a multi-line status report from plugin state
---@param info table { state, testing_state, coverage_state, daemon_state, active_session, config }
---@return string[]
function M.format_status_report(info)
  local lines = { "═══ SageFs Status ═══", "" }

  -- Daemon
  local ds = info.daemon_state or {}
  local daemon_label = ds.status or "unknown"
  if ds.job_id then daemon_label = daemon_label .. " (job " .. ds.job_id .. ")" end
  table.insert(lines, "Daemon:    " .. daemon_label)

  -- Connection
  local cfg = info.config or {}
  table.insert(lines, "MCP port:  " .. (cfg.port or "?"))
  table.insert(lines, "Dashboard: " .. (cfg.dashboard_port or "?"))

  -- Session
  local sess = info.active_session
  if sess then
    table.insert(lines, "Session:   " .. (sess.name or sess.id or "active"))
  else
    table.insert(lines, "Session:   (none)")
  end

  -- Tests
  local ts = info.testing_state
  if ts then
    local s = ts.summary
    -- Use summary if populated, otherwise count from tests table
    if s and s.total and s.total > 0 then
      table.insert(lines, "")
      local enabled_label = ts.enabled and "enabled" or "disabled"
      table.insert(lines, "Testing:   " .. enabled_label)
      table.insert(lines, string.format("Tests:     %d total, %d passed, %d failed, %d running",
        s.total, s.passed or 0, s.failed or 0, s.running or 0))
      if (s.stale or 0) > 0 then
        table.insert(lines, string.format("           %d stale", s.stale))
      end
    elseif ts.tests then
      local passed, failed, running, total = 0, 0, 0, 0
      for _ in pairs(ts.tests) do total = total + 1 end
      for _, t in pairs(ts.tests) do
        if t.status == "Passed" then passed = passed + 1
        elseif t.status == "Failed" then failed = failed + 1
        elseif t.status == "Running" then running = running + 1
        end
      end
      if total > 0 then
        table.insert(lines, "")
        table.insert(lines, string.format("Tests:     %d total, %d passed, %d failed, %d running",
          total, passed, failed, running))
      end
    end
  end

  -- Coverage
  local cs = info.coverage_state
  if cs and cs.summary and cs.summary.line_rate then
    table.insert(lines, string.format("Coverage:  %.0f%% line rate", cs.summary.line_rate * 100))
  end

  -- Config flags
  table.insert(lines, "")
  local flags = {}
  if cfg.check_on_save then table.insert(flags, "check_on_save") end
  if cfg.auto_connect then table.insert(flags, "auto_connect") end
  if #flags > 0 then
    table.insert(lines, "Flags:     " .. table.concat(flags, ", "))
  end

  return lines
end

-- ─── FSI Binding Tracker ──────────────────────────────────────────────────────

--- Parse FSI output for binding declarations.
--- FSI output format: "val <name> : <type>" or "val <name> : <type> = <value>"
---@param output string FSI result text
---@return table[] list of {name, type_sig}
function M.parse_bindings(output)
  local bindings = {}
  if not output then return bindings end
  for line in output:gmatch("[^\n]+") do
    local name, type_sig = line:match("^val%s+(%S+)%s*:%s*(.+)")
    if name and name ~= "mutable" and name ~= "it" and not name:match("^%(") then
      -- Strip trailing " = <value>" from type_sig
      local ts = type_sig:match("^(.-)%s*=") or type_sig
      table.insert(bindings, { name = name, type_sig = ts:match("^%s*(.-)%s*$") })
    end
  end
  return bindings
end

--- Create a new binding tracker state.
---@return table {bindings: table<string, {type_sig, count}>}
function M.new_binding_tracker()
  return { bindings = {} }
end

--- Update tracker with new bindings from an eval result.
--- MUTATES tracker in-place and returns the same reference for chaining.
--- Returns shadows detected during this update.
---@param tracker table binding tracker state (mutated in-place)
---@param output string FSI output text
---@return table tracker (same reference), table[] shadows [{name, old_type, new_type}]
function M.update_bindings(tracker, output)
  local parsed = M.parse_bindings(output)
  local shadows = {}
  for _, b in ipairs(parsed) do
    local existing = tracker.bindings[b.name]
    if existing then
      table.insert(shadows, {
        name = b.name,
        old_type = existing.type_sig,
        new_type = b.type_sig,
      })
      existing.type_sig = b.type_sig
      existing.count = existing.count + 1
    else
      tracker.bindings[b.name] = { type_sig = b.type_sig, count = 1 }
    end
  end
  return tracker, shadows
end

--- Rebuild tracker from server-pushed bindings snapshot (CQRS: server is source of truth).
--- Replaces the entire tracker state from the authoritative snapshot.
---@param snapshot table[] array of {Name, TypeSig, ShadowCount}
---@return table tracker fresh tracker from snapshot
function M.tracker_from_snapshot(snapshot)
  local tracker = { bindings = {} }
  for _, b in ipairs(snapshot) do
    local name = b.Name or b.name
    if name then
      tracker.bindings[name] = {
        type_sig = b.TypeSig or b.typeSig,
        count = b.ShadowCount or b.shadowCount,
      }
    end
  end
  return tracker
end

-- ─── Type Signature Extraction ──────────────────────────────────────────────

--- Validate SSE handler definition table entries.
--- Checks: target requires fn, fn requires target, at least one of fn or event.
---@param defs table[] SSE_HANDLER_DEFS-style entries
function M.validate_handler_defs(defs)
  for _, def in ipairs(defs) do
    if def.target and not def.fn then
      error("SSE_HANDLER_DEF: target without fn: " .. (def.action or "?"))
    end
    if def.fn and not def.target then
      error("SSE_HANDLER_DEF: fn without target: " .. (def.action or "?"))
    end
    if not def.fn and not def.event then
      error("SSE_HANDLER_DEF: no fn and no event: " .. (def.action or "?"))
    end
  end
end

--- Format model stats as display lines for :SageFsStats float.
---@param m table model state
---@return string[] lines
function M.format_stats_lines(m)
  local model = require("sagefs.model")
  local avg = model.eval_latency_avg(m)
  return {
    "═══ SageFs Stats ═══",
    "",
    string.format("Evals:         %d", m.stats.eval_count),
    string.format("Avg latency:   %s", avg and string.format("%.0fms", avg) or "n/a"),
    string.format("SSE events:    %d", m.stats.sse_events_total),
    string.format("Reconnects:    %d", m.stats.reconnect_count),
    string.format("Cells tracked: %d", model.cell_count(m)),
  }
end

--- Extract type signatures from FSI output for inline type hints.
--- Alias for parse_bindings — same FSI output format, same parsing logic (DRY).
M.extract_type_signatures = M.parse_bindings

--- Compute type hint placements for virtual text rendering.
--- Matches parsed bindings to `let <name>` lines within a cell range.
---@param buffer_lines string[] full buffer lines (1-indexed array)
---@param start_line number 1-indexed start line of cell
---@param end_line number 1-indexed end line of cell
---@param bindings table[] {name, type_sig} from parse_bindings
---@return table[] placements {line, text} for virtual text
function M.type_hint_placements(buffer_lines, start_line, end_line, bindings)
  local placements = {}
  if not bindings or #bindings == 0 then return placements end
  -- Build name→type_sig lookup
  local sig_map = {}
  for _, b in ipairs(bindings) do
    sig_map[b.name] = b.type_sig
  end
  for i = start_line, math.min(end_line, #buffer_lines) do
    local line = buffer_lines[i]
    -- Match simple `let name` patterns (not tuple/pattern destructuring)
    local name = line:match("^%s*let%s+(%a[%w_']*)")
    if name and sig_map[name] then
      table.insert(placements, { line = i, text = ": " .. sig_map[name] })
    end
  end
  return placements
end

-- ─── Path Exclusion Filter ──────────────────────────────────────────────────

local EXCLUDED_PATTERNS = {
  "node_modules",
  "[/\\]bin[/\\]",
  "[/\\]obj[/\\]",
  "^bin[/\\]",
  "^obj[/\\]",
  "^%.git[/\\]",
  "[/\\]%.git[/\\]",
  "^%.nuget[/\\]",
  "[/\\]%.nuget[/\\]",
}

--- Filter out paths matching common exclusion patterns (node_modules, bin, obj, .git, .nuget).
---@param paths string[] list of relative paths
---@return string[] filtered paths
function M.filter_excluded_paths(paths)
  local result = {}
  for _, p in ipairs(paths) do
    local excluded = false
    for _, pattern in ipairs(EXCLUDED_PATTERNS) do
      if p:match(pattern) then
        excluded = true
        break
      end
    end
    if not excluded then
      table.insert(result, p)
    end
  end
  return result
end

return M
