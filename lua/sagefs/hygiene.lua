-- sagefs/hygiene.lua: what agents and orchestrators left behind on this machine
-- Pure Lua, zero vim dependencies.
--
-- The daemon's `get_workspace_hygiene` MCP tool answers in text
-- (SageFs.Core/WorkspaceHygieneRender.fs, renderPlan), and it is always a dry run:
--
--   Workspace hygiene (dry run, plan 7f3c1a2b)
--   3 leftover(s) found. 2 safe to reclaim (12.0 KiB), 1 need a look (4.0 KiB).
--
--   Safe to reclaim (2)
--    agent worktree x1, 8.0 KiB
--     .worktrees/claude-9f2  8.0 KiB, 3d 4h old. merged by rebase, so it is safe to reclaim
--
--   Has uncommitted work (1)
--    agent branch x1, 4.0 KiB
--     feature-x  4.0 KiB, 1d 1h old. unmerged commits, so it is never touched
--       to keep it: git push origin feature-x
--
--   In use or too young (1)
--    agent worktree x1, 2.0 KiB
--     .worktrees/copilot-11ab  2.0 KiB, 5m old. a session works in it
--
--   To reclaim the 2 safe item(s): tidy_workspace with confirm=true and plan=... .
--   Anything marked needs-a-look is never touched by tidy.
--
-- This module reads that text and lays it out for the editor. It does NOT
-- reclaim anything: `tidy_workspace` needs a plan id and confirm=true, and a
-- keystroke in an editor is not that decision.
--
-- Every line the daemon sent is kept, in its own words. The only change is a
-- heading: its "(n)" moves in front, so the count reads as a heading instead of
-- sitting in brackets. Nothing here can claim more than the daemon did, because
-- every claim in the window is a sentence the daemon wrote.
--
-- The absent half is the one that protects users on an older daemon. The plugin
-- reaches users commit by commit against whatever daemon they last installed, so
-- a reply that is not a plan is rendered as itself, in plain words, with a note
-- saying the daemon is older. It is never an error and never an empty window.

local M = {}

-- ─── Parsing ─────────────────────────────────────────────────────────────────

-- A heading is a Title-cased phrase over a count in parentheses, the way the
-- daemon prints a risk group. Anchored on the brackets, so a group line or an
-- entry line can never be read as one.
local HEADING = "^%s*(%a[%w%s]-)%s*%((%d+)%)%s*$"
-- One group line: the kind of leftover (which may be two words), how many of it,
-- and their size.
local GROUP = "^(.-)%s+x(%d+),%s*(.+)$"
-- One entry line: the thing, its size, its age, then the reason the daemon gave.
local ENTRY = "^%s+(%S+)%s+.-%s+.-,%s+.-old%.%s*(.*)$"
-- The line that follows an entry that needs a look, naming what saves it.
local KEEP = "^%s+to keep it:%s*(.*)$"
-- The sentence that sums the reply up: how many leftovers, how much is safe and
-- how much needs a look. The daemon pluralises the "(s)" its own way.
local SUMMARY = "\n([^\n]*leftover[%w%(%) ]* found[^\n]*)\n"
-- A group cut short at the daemon's display limit.
local MORE = "^%s+%.%.%.and (%d+) more%s*$"
-- The sentence that tells a person how to reclaim.
local RECLAIM = "%f[%S]To reclaim the "

-- Read a plan id out of the line that calls the reply a dry run.
local function read_plan_id(text)
  local id = text:match("dry run, plan ([^%)%s]+)")
  return id
end

-- Read one "agent worktree x1, 8.0 KiB" line. The daemon prints one line per
-- kind inside a section, so this is a kind, a count and a size and nothing else.
local function read_group(line)
  local rest = line:gsub("^%s+", "")
  -- `x2,` with no space before it, because "8.0 KiB" after the comma is a
  -- second word and the kind itself can be two words ("agent worktree").
  local kind, count, bytes = rest:match("^(.-)%s+x(%d+),%s*(.+)$")
  if not kind or not bytes then return nil end
  -- A size is a number and a unit, and that is the last word of the line: an
  -- entry's reason is the daemon's own sentence and reads as a sentence, not as
  -- a number and a unit. A pid line ("pid 1234 (...)") ends in a bracket.
  if not bytes:match("^%S+%s+%S+$") or bytes:match("%(%)$") then return nil end
  return { kind = kind, count = tonumber(count), bytes = bytes }
end

--- Read a get_workspace_hygiene reply. nil when the reply is not a plan (an
--- older daemon's error, an empty reply, something else entirely); the second
--- return is then the reply itself, which absent_message explains in plain words.
---@param reply string|nil
---@return table|nil model { plan_id, total, safe_count, safe_bytes, review_count, review_bytes, sections, present }
---@return string|nil text the reply, only when it carried no plan
function M.parse(reply)
  if type(reply) ~= "string" then return nil, nil end
  if reply:match("^%s*$") then return nil, reply end
  local id = read_plan_id(reply)
  if not id then return nil, reply end
  local model = { plan_id = id, sections = {}, present = true }
  local summary = reply:match(SUMMARY)
  if summary then
    model.summary = summary
    model.total = tonumber(summary:match("^%s*(%d+) leftover")) or 0
    model.safe_count = tonumber(summary:match("(%d+) safe to reclaim")) or 0
    model.safe_bytes = summary:match("safe to reclaim %(([^%)]+)%)")
    model.review_count = tonumber(summary:match("(%d+) need a look")) or 0
    model.review_bytes = summary:match("need a look %(([^%)]+)%)")
  end
  -- Defaults, because the summary line is OPTIONAL: a daemon that reports a plan with no
  -- sections and no summary still produced a model, and these fields were nil on it. The
  -- cost was a "bad argument #2 to 'format' (number expected, got nil)" from the summary
  -- line — the one caller that formats them — rather than a legible "nothing to reclaim".
  model.total = model.total or 0
  model.safe_count = model.safe_count or 0
  model.safe_bytes = model.safe_bytes or "0 B"
  model.review_count = model.review_count or 0
  model.review_bytes = model.review_bytes or "0 B"

  local section = nil
  for line in (reply .. "\n"):gmatch("([^\n]*)\n") do
    local name, count = line:match(HEADING)
    if name then
      section = { name = name, count = tonumber(count), items = {} }
      table.insert(model.sections, section)
    elseif section then
      local more = line:match(MORE)
      local keep = line:match(KEEP)
      if more then
        section.more = tonumber(more)
      elseif keep then
        -- "to keep it" belongs to the entry just above it.
        local items = section.items
        if #items > 0 then items[#items].keep = keep end
      else
        local group = read_group(line)
        if group then
          section.kind, section.group_count, section.group_bytes = group.kind, group.count, group.bytes
        else
          local thing, reason = line:match(ENTRY)
          if thing then
            table.insert(section.items, { text = thing, keep = nil, reason = reason or "" })
          end
        end
      end
    end
  end
  return model, nil
end

-- ─── The words for an absent reply ────────────────────────────────────────────

-- Said whether or not the daemon said anything itself: the plugin reached a
-- daemon and the daemon did not know the tool.
local ABSENT_HEAD = "This daemon has no get_workspace_hygiene, so there is no hygiene plan to read."
local ABSENT_TAIL = "That is expected, not a failure: the plugin is newer than the daemon is. Update the daemon when you want this view."

--- The words for a reply that carried no plan: what the daemon said first, so a
--- word of it is never dropped, then a plain explanation in the same register.
---@param reply string|nil the reply that was not a plan
---@return string[]
function M.absent_message(reply)
  local lines = {}
  if type(reply) == "string" then
    for line in (reply .. "\n"):gmatch("([^\n]*)\n") do
      if line:match("%S") then table.insert(lines, line) end
    end
  end
  if #lines == 0 then table.insert(lines, "The daemon answered with nothing this view can read.") end
  table.insert(lines, "")
  table.insert(lines, ABSENT_HEAD)
  table.insert(lines, ABSENT_TAIL)
  return lines
end

-- ─── Rendering ────────────────────────────────────────────────────────────────

--- The words a heading is shown with: the daemon's own words, with the count it
--- printed in brackets moved in front so it reads as a heading and not as a note.
---@param name string
---@param count number|nil
---@return string
function M.heading(name, count)
  if type(count) == "number" then return string.format("%d %s", count, name or "") end
  return tostring(name or "")
end

--- Lay a reply out as scratch-buffer lines: every line of the plan kept, one
--- blank line between sections, a heading given its count in front, and the
--- read-only note added under a reply that offers a reclaim.
---@param text string|nil the get_workspace_hygiene reply
---@return { lines: string[], model: table|nil, present: boolean }
function M.render(text)
  local model = M.parse(text)
  if not model then
    return { lines = M.absent_message(text), model = nil, present = false }
  end
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local name, count = line:match(HEADING)
    if name then
      if #lines > 0 then table.insert(lines, "") end
      table.insert(lines, M.heading(name, tonumber(count)))
    elseif line:match("^%s*$") then
      -- A blank line only means "before a section"; drop it here.
    else
      table.insert(lines, line)
    end
  end
  -- The daemon says how to reclaim. Say plainly that this view does not.
  if type(text) == "string" and text:find(RECLAIM) then
    table.insert(lines, "")
    table.insert(lines, "This view is read-only. It reclaimed nothing; the call above is the daemon's to make, with its plan id.")
  end
  return { lines = lines, model = model, present = true }
end

--- A one-line summary, for a notification: how much is safe to reclaim.
---@param text string|nil
---@return string
function M.summary_line(text)
  local model = M.parse(text)
  if not model then return "this daemon has no get_workspace_hygiene" end
  if model.safe_count == 0 then return "nothing is safe to reclaim right now" end
  return string.format("%d safe to reclaim (%s)", model.safe_count, model.safe_bytes or "an unknown size")
end

-- ─── Which repository the plan is about ───────────────────────────────────────

--- The directory to ask about: the one the editor is in, which is this
--- repository. Empty when there is none, so the daemon is asked rather than told.
---@param getcwd function():string|nil
---@return string
function M.working_directory(getcwd)
  local ok, cwd = pcall(getcwd or function() return "" end)
  if not ok or type(cwd) ~= "string" then return "" end
  return (cwd:gsub("/+$", ""))
end

return M