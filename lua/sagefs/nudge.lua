-- sagefs/nudge.lua — Nudge one value in a source file the session owns (pure)
--
-- The daemon's nudge_value tool (SageFs/McpNudge.fs, docs/hot-reload.md "Nudging a
-- value") lists the values of a file (`inspect`), writes one back as just that
-- expression (`set`, with the hash inspect gave), and steps through what it wrote
-- (`undo`, `redo`). Every reply is one JSON object with an `outcome` token; a
-- refusal carries `refusal`, `rule` and `nextAction`.
--
-- Everything the plugin decides without touching the editor is here: the request,
-- the reply, which listed value the cursor is on, what a bump of a literal comes
-- to, and the words for the notice. The editor side is sagefs.nudge_ui.
--
-- Lua 5.1 only (the Lua Neovim embeds): no //, no goto, no bit operators.

local util = require("sagefs.util")

local M = {}

local LEVELS = (vim and vim.log and vim.log.levels) or { INFO = 1, WARN = 2, ERROR = 3 }

M.TOOL = "nudge_value"

--- The sub-commands of :SageFsNudge, in the order the help lists them.
M.ACTIONS = { "up", "down", "set", "expr", "undo", "redo", "list" }

-- ─── The request ─────────────────────────────────────────────────────────────

local ARG_FIELDS = { "action", "file", "address", "seen", "literal", "expression", "working_directory" }

--- The tool's arguments: its own parameter names, with what is empty left out.
---@param opts table
---@return table
function M.build_args(opts)
  local args = {}
  for _, key in ipairs(ARG_FIELDS) do
    local value = opts[key]
    if type(value) == "string" and value ~= "" then args[key] = value end
  end
  return args
end

--- The directory that names the session: the active session's own, and the
--- editor's only when the session list carried none. (nudge_value takes a
--- working_directory, not a session id.)
---@param session table|nil
---@param cwd string
function M.working_directory(session, cwd)
  local dir = session and session.working_directory
  if type(dir) == "string" and dir ~= "" then return dir end
  return cwd
end

--- The daemon writes the file on disk, so a buffer with edits it has not seen is
--- refused by name, never silently overwritten or ignored.
---@param buffer { modified: boolean, name: string }
---@return string|nil refusal
function M.unsaved_refusal(buffer)
  if not buffer.name or buffer.name == "" then
    return "SageFs nudge: this buffer is not a file on disk. Open a source file of the session's project."
  end
  if buffer.modified then
    return "SageFs nudge: this buffer has unsaved edits, and the daemon writes the file on disk, "
      .. "so it would not see them and its write would replace them. :write the buffer first, or :edit! to drop the edits."
  end
  return nil
end

-- ─── :SageFsNudge arguments ──────────────────────────────────────────────────

--- Read what was typed after :SageFsNudge.
---@param text string
---@return { action: string|nil, step: string|nil, value: string|nil, error: string|nil }
function M.parse_command(text)
  local trimmed = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then return { action = "up" } end
  local word, rest = trimmed:match("^(%S+)%s*(.*)$")
  if word == "up" or word == "down" then
    return { action = word, step = rest ~= "" and rest or nil }
  elseif word == "set" or word == "expr" then
    return { action = word, value = rest ~= "" and rest or nil }
  elseif word == "undo" or word == "redo" or word == "list" then
    return { action = word }
  end
  return {
    error = string.format("'%s' is not something :SageFsNudge does. Use one of: %s.",
      word, table.concat(M.ACTIONS, ", ")),
  }
end

-- ─── The reply ───────────────────────────────────────────────────────────────

--- Read what the tool answered: the answer is JSON on its own (the client hands
--- over the first text block, and the daemon's event echo is a block of its own).
--- `ok` is false when the call itself failed (a member token without the role, an
--- older daemon with no such tool); the text is then the daemon's own words.
---@param ok boolean
---@param raw string|nil
---@return table reply always has `outcome`; `Failed` carries `message`
function M.parse_reply(ok, raw)
  if not ok then
    return { outcome = "Failed", message = tostring(raw or "no reply from the daemon") }
  end
  local decoded, data = util.json_decode(type(raw) == "string" and raw or nil)
  if decoded and type(data) == "table" and type(data.outcome) == "string" then
    if type(data.notes) ~= "table" then data.notes = {} end
    if type(data.items) ~= "table" then data.items = {} end
    return data
  end
  local text = (type(raw) == "string" and raw ~= "") and raw or "no reply"
  if #text > 200 then text = text:sub(1, 200) .. "…" end
  return {
    outcome = "Failed",
    message = "the daemon answered something that is not a nudge reply (it may be older than this plugin): " .. text,
  }
end

local NOTE_TEXT = {
  TornJournalTailRemoved = "A torn journal record left by a crash was removed.",
  UnlandedWriteMarkedUndone = "A write that never reached the file was marked undone.",
  ExpressionNotTypeChecked = "The expression was parsed, not type-checked: a type error shows in the reload verdict, "
    .. "and :SageFsNudge undo puts the old text back.",
  FileNotWatched = "Hot reload is not watching this file, so the running app has not picked the change up (:SageFsWatchAll).",
}

local function notes_text(notes)
  local parts = {}
  for _, token in ipairs(notes or {}) do
    table.insert(parts, NOTE_TEXT[token] or tostring(token))
  end
  return table.concat(parts, " ")
end

--- The notice for a reply: text and log level.
---@param reply table
---@return string text, number level
function M.describe(reply)
  local outcome = reply.outcome
  local text, level
  if outcome == "Written" then
    text = string.format("SageFs nudge: %s  %s -> %s", reply.address or "?", reply.before or "?", reply.after or "?")
    level = LEVELS.INFO
  elseif outcome == "Undone" then
    text = string.format("SageFs nudge: undone, %s is back to %s (was %s)", reply.address or "?", reply.after or "?", reply.before or "?")
    level = LEVELS.INFO
  elseif outcome == "Redone" then
    text = string.format("SageFs nudge: redone, %s is %s again (was %s)", reply.address or "?", reply.after or "?", reply.before or "?")
    level = LEVELS.INFO
  elseif outcome == "Unchanged" then
    text = string.format("SageFs nudge: %s is already %s, so nothing was written.", reply.address or "?", reply.text or "?")
    level = LEVELS.INFO
  elseif outcome == "Refused" then
    text = string.format("SageFs nudge refused (%s): %s", reply.refusal or "?", reply.rule or "")
    if reply.nextAction and reply.nextAction ~= "" then text = text .. " Next: " .. reply.nextAction end
    return text, LEVELS.WARN
  elseif outcome == "Inspected" then
    text = string.format("SageFs nudge: %d value(s) in %s; undo steps %d, redo steps %d.",
      #(reply.items or {}), reply.file or "the file", reply.undoSteps or 0, reply.redoSteps or 0)
    level = LEVELS.INFO
  else
    text = "SageFs nudge failed: " .. tostring(reply.message or ("the daemon answered '" .. tostring(outcome) .. "'"))
    return text, LEVELS.ERROR
  end
  local notes = notes_text(reply.notes)
  if notes ~= "" then text = text .. " " .. notes end
  return text, level
end

-- ─── Literals and bumping ────────────────────────────────────────────────────

local function strip_underscores(s) return (s:gsub("_", "")) end

local MAX_DIGITS = 15 -- a Lua number is a double: past this a bump would not be exact

-- F#'s own numeric type suffixes. Anything else after the digits (the x of "0x") is not a number.
local INT_SUFFIX = { y = true, uy = true, s = true, us = true, l = true, ul = true, u = true, L = true, UL = true, n = true, un = true }
local REAL_SUFFIX = { f = true, F = true, m = true, M = true, lf = true, LF = true }

local function decimals_of(frac)
  return #strip_underscores(frac)
end

--- Read the text of a literal into what a bump needs. A unit of measure
--- (`12.5<m/s>`) and a type suffix (`10L`, `1.0f`) are left to the daemon, which
--- keeps them when it writes the new value back.
---@param text string
---@return table { kind = "int"|"real"|"bool"|"other", value, base?, decimals?, unit? }
function M.read_literal(text)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "true" then return { kind = "bool", value = true } end
  if text == "false" then return { kind = "bool", value = false } end
  local body, unit = text:match("^(.-)(<[^<>]+>)$")
  if body then text = body else unit = "" end

  local function sign_of(s) return s == "-" and -1 or 1 end

  local sign, digits = text:match("^(%-?)0[xX]([%x_]+)$")
  if digits then
    local clean = strip_underscores(digits)
    if #clean > MAX_DIGITS - 3 then return { kind = "other" } end
    return { kind = "int", value = sign_of(sign) * tonumber(clean, 16), base = "hex", unit = unit }
  end
  sign, digits = text:match("^(%-?)0[oO]([0-7_]+)$")
  if digits then
    return { kind = "int", value = sign_of(sign) * tonumber(strip_underscores(digits), 8), base = "oct", unit = unit }
  end
  sign, digits = text:match("^(%-?)0[bB]([01_]+)$")
  if digits then
    return { kind = "int", value = sign_of(sign) * tonumber(strip_underscores(digits), 2), base = "bin", unit = unit }
  end

  local whole, frac, suffix
  sign, whole, frac, suffix = text:match("^(%-?)([%d_]+)%.([%d_]*)(%a*)$")
  if whole and (suffix == "" or REAL_SUFFIX[suffix]) then
    local clean = strip_underscores(whole)
    if #clean > MAX_DIGITS or decimals_of(frac) > MAX_DIGITS then return { kind = "other" } end
    local number = tonumber(clean .. "." .. (strip_underscores(frac) == "" and "0" or strip_underscores(frac)))
    if not number then return { kind = "other" } end
    return { kind = "real", value = sign_of(sign) * number, decimals = decimals_of(frac), unit = unit }
  end
  sign, digits, suffix = text:match("^(%-?)([%d_]+)(%a*)$")
  if digits and (suffix == "" or INT_SUFFIX[suffix]) then
    local clean = strip_underscores(digits)
    if clean == "" or #clean > MAX_DIGITS then return { kind = "other" } end
    return { kind = "int", value = sign_of(sign) * tonumber(clean), base = "dec", unit = unit }
  end
  return { kind = "other" }
end

--- The literal text that goes up or down from `item.text` by `count` steps, or
--- nil and the reason. The text is plain decimal: the daemon reads it as the kind
--- the literal already is and writes it back in the author's own style (hex stays
--- hex, a unit of measure and a suffix stay).
---@param item { text: string }
---@param direction number 1 or -1
---@param count number|nil
---@param step_text string|nil
---@return string|nil literal, string|nil reason
function M.bump(item, direction, count, step_text)
  count = (count and count > 0) and count or 1
  local lit = M.read_literal(item.text)
  if lit.kind == "bool" then return tostring(not lit.value) end
  if lit.kind == "other" then
    return nil, "the value here is not a number or a bool, so it cannot be bumped. "
      .. "Use :SageFsNudge set (or expr) to give it a value."
  end

  local step, step_decimals
  if step_text and step_text ~= "" then
    local given = M.read_literal(step_text)
    if (given.kind ~= "int" and given.kind ~= "real") or given.unit ~= "" or (given.base and given.base ~= "dec")
      or given.value <= 0 then
      return nil, "the step must be a plain number above zero, such as 1 or 0.25."
    end
    step = given.value
    step_decimals = given.decimals or 0
  elseif lit.kind == "real" and lit.decimals > 0 then
    step = 10 ^ -lit.decimals
    step_decimals = lit.decimals
  else
    step, step_decimals = 1, 0
  end

  local value = lit.value + direction * step * count
  if lit.kind == "int" then
    if step_decimals > 0 then
      return nil, "an integer literal takes a whole step. Give a whole number, or set a real value with :SageFsNudge set."
    end
    local formatted = string.format("%.0f", value)
    if formatted == "-0" then formatted = "0" end
    return formatted
  end
  local places = math.max(lit.decimals, step_decimals)
  local formatted = string.format("%." .. places .. "f", value)
  if formatted:match("^%-0%.?0*$") then formatted = formatted:sub(2) end
  return formatted
end

-- ─── Which listed value is under the cursor ──────────────────────────────────
--
-- inspect lists each value's address, its text and its hash, and no line or
-- column. So the cursor is matched to the text on its own line, and two values
-- with the same text are told apart by what the file says around them: the
-- binding the cursor is inside, and the record field written just before it. When
-- that still leaves more than one, they are offered; none is guessed.

local MODIFIERS = { "rec", "inline", "mutable", "private", "internal", "public", "static", "lazy" }

--- The name a declaration line declares, or nil for a line that declares nothing
--- this can read (a tuple pattern, a line that is not a declaration).
local function declared_name(line)
  local is_member = false
  local rest = line:match("^%s*let%s+(.*)$") or line:match("^%s*and%s+(.*)$") or line:match("^%s*val%s+(.*)$")
  if not rest then
    rest = line:match("^%s*static%s+member%s+(.*)$") or line:match("^%s*member%s+(.*)$")
      or line:match("^%s*override%s+(.*)$") or line:match("^%s*default%s+(.*)$")
    is_member = rest ~= nil
  end
  if not rest then return nil end
  local changed = true
  while changed do
    changed = false
    for _, word in ipairs(MODIFIERS) do
      local stripped, n = rest:gsub("^" .. word .. "%s+", "", 1)
      if n > 0 then rest = stripped; changed = true end
    end
  end
  if is_member then rest = rest:gsub("^[%w_]+%.", "", 1) end
  return rest:match("^([%w_']+)")
end

local function indent_of(line)
  return #(line:match("^(%s*)"))
end

--- Where the declaration of `name` that contains `row` starts: "inside" when the
--- cursor's line belongs to its body, "outside" when a declaration of `name` is
--- above but the cursor is past its end, "unknown" when no line declares it.
local function binding_state(lines, row, name)
  for i = row, 1, -1 do
    if declared_name(lines[i] or "") == name then
      local base = indent_of(lines[i])
      for j = i + 1, row do
        local line = lines[j] or ""
        if line:find("%S") and indent_of(line) <= base then return "outside" end
      end
      return "inside", i
    end
  end
  return "unknown"
end

local function binding_of(address)
  local head = address:match("^([^/]*)") or address
  return head:match("([^%.]+)$") or head
end

local function last_field_of(address)
  local field
  for step in address:gmatch("/([^/]+)") do
    local name = step:match("^{(.*)}$")
    if name then field = name end
  end
  return field
end

local function escape(s) return (s:gsub("%p", "%%%0")) end

--- Every place `text` stands as its own token in `line`: { s, e } (1-based, inclusive).
local function spans_of(line, text)
  local spans = {}
  local init = 1
  while true do
    local s, e = line:find(text, init, true)
    if not s then break end
    local before = s > 1 and line:sub(s - 1, s - 1) or ""
    local after = line:sub(e + 1, e + 1)
    local after2 = line:sub(e + 1, e + 2)
    local edge_ok = not before:find("[%w_%.]") and not after:find("[%w_]") and not after2:find("^%.%d")
    if edge_ok then spans[#spans + 1] = { s = s, e = e } end
    init = s + 1
  end
  return spans
end

--- Which listed value the cursor is on.
---@param items table[] the `items` of an inspect reply
---@param lines string[] the buffer's lines
---@param row number 1-based
---@param col number 0-based byte column
---@param opts { knob_only: boolean|nil }|nil
---@return table { kind = "one", item } | { kind = "many", items } | { kind = "none", reason }
function M.locate(items, lines, row, col, opts)
  opts = opts or {}
  local line = lines[row] or ""
  local cursor = col + 1

  local hits = {}
  for index, item in ipairs(items) do
    local usable = type(item.text) == "string" and item.text ~= "" and not item.text:find("\n", 1, true)
    if usable and (not opts.knob_only or item.kind == "Knob") then
      for _, span in ipairs(spans_of(line, item.text)) do
        if span.s <= cursor and cursor <= span.e then
          hits[#hits + 1] = { item = item, span = span, order = index }
          break
        end
      end
    end
  end
  if #hits == 0 then
    return { kind = "none", reason = "no value the daemon lists for this file is under the cursor. Put the cursor on the value itself." }
  end

  -- Which binding the cursor is inside.
  local inside, unknown = {}, {}
  for _, hit in ipairs(hits) do
    local state = binding_state(lines, row, binding_of(hit.item.address))
    if state == "inside" then inside[#inside + 1] = hit
    elseif state == "unknown" then unknown[#unknown + 1] = hit end
  end
  local pool = #inside > 0 and inside or unknown
  if #pool == 0 then
    return { kind = "none", reason = "the value under the cursor is in a binding the daemon does not list for this file, "
      .. "so it is not one it can nudge." }
  end

  -- The record field written just before the value.
  local named = {}
  for _, hit in ipairs(pool) do
    local field = last_field_of(hit.item.address)
    if field then
      local before = line:sub(1, hit.span.s - 1)
      if before:find("%f[%w_']" .. escape(field) .. "%s*=%s*$") then named[#named + 1] = hit end
    end
  end
  if #named > 0 then pool = named end

  table.sort(pool, function(a, b)
    if #a.item.text ~= #b.item.text then return #a.item.text < #b.item.text end
    return a.order < b.order
  end)
  if #pool == 1 then return { kind = "one", item = pool[1].item } end
  local out = {}
  for _, hit in ipairs(pool) do out[#out + 1] = hit.item end
  return { kind = "many", items = out }
end

return M
