-- sagefs/wire_runtime.lua — the daemon's reload and REPL-freshness wire, folded and surfaced
--
-- Glue between the pure folds (reload_state, repl_freshness, status_fields) and the
-- editor. Every impure thing is passed in, so this file has no vim dependency and is
-- tested with fakes:
--   notify(msg, level)        vim.notify wrapper
--   now_ms()                  a clock, so a harmless verdict can fade and the eval
--                             message can be rate-limited
--   refresh_sessions(cb)      re-read GET /api/sessions (the REPL's freshness lives there)
--   active_session()          the active normalized session, or nil
--   redraw()                  ask for a statusline redraw
--   redraw_later(ms)          optional: ask for one after a delay (a fading segment)
--   ui { show(sid, display), clear(sid) }   optional virtual text surface
--   notify_reload             false turns the reload notifications off (the state is still shown)
--   on_freshness(sid, f)      optional: called when a session's REPL freshness is read
--
-- init.lua forwards the SSE handlers, the eval result, the session list and the
-- statusline to the object this returns.

local reload_state = require("sagefs.reload_state")
local repl_freshness = require("sagefs.repl_freshness")
local source_state = require("sagefs.source_state")
local status_fields = require("sagefs.status_fields")

local M = {}

local LEVELS = { info = 1, warn = 2, error = 3 }

---@param deps table
function M.new(deps)
  local rt = {}
  local model = reload_state.model_new()
  local gate = repl_freshness.gate_new()
  local last_note = {}          -- sid -> last notification text, so a repeat is not said twice
  local banner_override = {}    -- sid -> BehindApp read from a result's banner, until a list is read
  local last_freshness_key = {} -- sid -> key of the freshness last passed to on_freshness

  local function now()
    return deps.now_ms and deps.now_ms() or 0
  end

  local function active()
    return deps.active_session and deps.active_session() or nil
  end

  -- Strict: with no active session nothing is "ours". On a shared daemon every
  -- session's report arrives here, and a directory with no session of its own must
  -- not announce them. The report is still folded into the model, so it shows the
  -- moment a session is picked.
  local function is_active(sid)
    local a = active()
    return a ~= nil and a.id == sid
  end

  local function level_for(display)
    local name = display.notify_level or "info"
    local levels = vim.log and vim.log.levels or { INFO = 1, WARN = 2, ERROR = 3 }
    if name == "error" then return levels.ERROR end
    if name == "warn" then return levels.WARN end
    return levels.INFO
  end

  --- The REPL freshness of the active session: the list's word, else a banner's.
  local function freshness_of(session)
    if not session then return nil end
    if session.repl_freshness then return session.repl_freshness end
    return banner_override[session.id]
  end

  -- ─── SSE: a reload report ──────────────────────────────────────────────────

  function rt.on_reload_reported(data)
    local new_model, info = reload_state.apply_sse(model, data, now())
    if not info.changed then return end
    model = new_model
    local sid = info.sid
    if info.report and info.report.file and deps.ui and deps.ui.note_file then
      deps.ui.note_file(sid, info.report.file)
    end
    if is_active(sid) then
      local report = info.report
      local display = report and reload_state.display(report) or nil
      if display and display.fade_ms and deps.redraw_later then
        -- The statusline segment fades by the clock; something has to redraw it then.
        deps.redraw_later(display.fade_ms + 50)
      end
      if deps.ui then
        if display and report.phase ~= reload_state.PHASE.None then
          deps.ui.show(sid, display)
        else
          deps.ui.clear(sid)
        end
      end
      if display and display.attention and deps.notify_reload ~= false then
        local text = "reload: " .. display.text
        if last_note[sid] ~= text then
          last_note[sid] = text
          deps.notify(text, level_for(display))
        end
      elseif display and not display.attention then
        last_note[sid] = nil
      end
      -- The REPL's freshness is the daemon's word on the session list. It cannot have
      -- changed while a save is still compiling, so only a resolved report asks.
      local compiling = report and report.phase == reload_state.PHASE.Compiling
      if deps.refresh_sessions and not compiling then deps.refresh_sessions() end
    end
    if deps.redraw then deps.redraw() end
  end

  -- ─── Session list ──────────────────────────────────────────────────────────

  function rt.on_sessions(sessions)
    model = reload_state.seed(model, sessions)
    for _, s in ipairs(sessions or {}) do
      if s.id and s.repl_freshness then
        banner_override[s.id] = nil
        if deps.on_freshness then
          local key = tostring(s.repl_freshness.state) .. tostring(s.repl_freshness.saves_since)
          if last_freshness_key[s.id] ~= key then
            last_freshness_key[s.id] = key
            deps.on_freshness(s.id, s.repl_freshness)
          end
        end
      end
    end
    if deps.redraw then deps.redraw() end
  end

  --- A session came back ready: its worker was replaced. The daemon cleared the
  --- reload report (unless it is the restart that caused the swap) and the REPL
  --- freshness with the old worker, so forget what events said and read the list.
  function rt.on_session_ready(data)
    local sid = type(data) == "table" and (data.sessionReady or data.sessionId) or nil
    if type(sid) ~= "string" then return end
    model = reload_state.forget(model, sid)
    banner_override[sid] = nil
    last_note[sid] = nil
    if deps.refresh_sessions then deps.refresh_sessions() end
    if deps.redraw then deps.redraw() end
  end

  function rt.on_reconnect()
    model = reload_state.drop_events(model)
  end

  function rt.on_hard_reset()
    local a = active()
    if a and a.id then
      banner_override[a.id] = nil
      gate = repl_freshness.gate_new()
    end
    if deps.refresh_sessions then deps.refresh_sessions() end
  end

  -- ─── Eval ──────────────────────────────────────────────────────────────────

  --- Take the daemon's WARNING banner off an eval result, and say the one-line
  --- message (with the remedy) when the REPL is behind. Returns the result without
  --- the banner.
  function rt.on_eval(result)
    result = result or {}
    local session = active()
    local clean_result = {}
    for k, v in pairs(result) do clean_result[k] = v end
    local banner
    for _, field in ipairs({ "output", "error" }) do
      if type(result[field]) == "string" then
        local clean, found = repl_freshness.split_banner(result[field])
        if found then
          clean_result[field] = clean
          banner = banner or found
        end
      end
    end
    if banner and session and session.id and not (session.repl_freshness and session.repl_freshness.state == repl_freshness.STATE.BehindApp) then
      banner_override[session.id] = repl_freshness.from_banner(banner)
    end
    local f = freshness_of(session)
    local say
    say, gate = repl_freshness.gate_should_announce(gate, f, now())
    if say then
      local levels = vim.log and vim.log.levels or { WARN = 2 }
      deps.notify(repl_freshness.eval_message(f), levels.WARN)
    end
    if banner and deps.redraw then deps.redraw() end
    return clean_result
  end

  -- ─── Surfaces ──────────────────────────────────────────────────────────────

  function rt.statusline_segments()
    local session = active()
    if not session then return {} end
    local view = {}
    for k, v in pairs(session) do view[k] = v end
    if not view.repl_freshness then view.repl_freshness = banner_override[session.id] end
    return status_fields.segments(view, { reload_model = model, now_ms = now() })
  end

  --- Lines for the :SageFsReloadStatus panel: the reload truth, then the REPL state.
  function rt.report_lines()
    local session = active()
    local sid = session and session.id
    local lines = {}
    local report = sid and (reload_state.current(model, sid) or session.last_reload) or nil
    if not report and not sid then report = reload_state.latest(model) end
    if report then
      for _, l in ipairs(reload_state.lines(report, sid and reload_state.previous(model, sid) or nil)) do
        table.insert(lines, l)
      end
    else
      table.insert(lines, { text = "no hot reload yet", hl = "SageFsReloadQuiet" })
    end
    local f = freshness_of(session)
    for _, l in ipairs(repl_freshness.lines(f)) do table.insert(lines, l) end
    for _, l in ipairs(source_state.lines(session and session.source_state or nil)) do table.insert(lines, l) end
    return lines
  end

  function rt.model() return model end

  return rt
end

return M
