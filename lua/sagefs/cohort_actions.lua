-- sagefs/cohort_actions.lua — :SageFsCohortDelegate, :SageFsCohortVeto,
-- :SageFsCohortResolveVeto and :SageFsCohortWithdraw
-- REQUIRES nothing from vim: the argument builders and the pre-flight refusals are
-- pure, so they can be unit tested; cohort_view.lua is the shell that calls a tool
-- and refreshes the buffer afterwards.
--
-- These four tools arrived in 0.6.896 (delegate_conductor, veto_landing,
-- resolve_veto, withdraw_landing). Until now the plugin could read the cohort and
-- see a veto on a row but could do nothing about one.
--
-- WORKING_DIRECTORY. Every one of the four takes it, and the tool reads an omitted
-- one as "the cohort of the directory the DAEMON started in" — so a command that
-- does not name the directory acts in the wrong repository, silently. Each builder
-- therefore takes the cwd and always emits it, and an absent cwd becomes an EMPTY
-- STRING, which the tool's DefaultParameterValue("") turns into "the caller named
-- none". A nil would be dropped from the JSON object entirely. Same reasoning, and
-- the same shape, as cohort_view.status_args.
--
-- REFUSALS. Checked here, before the call, for the two the tool documents a bound
-- on: a veto's reason is 1 to 1000 characters, and both the agent name and the
-- landing id are required. A refusal says what was wrong and what to do, and never
-- spends a round trip to learn it.

local M = {}

--- The tool's own bound on a veto reason, read from its schema description
--- ("maxLength: 1000"). Inclusive at both ends.
M.REASON_MAX = 1000

--- The directory argument, never nil. See the note above.
local function dir(cwd)
  return cwd or ""
end

--- delegate_conductor: hand the conductor seat to another PRESENT member.
---@return table arguments
function M.delegate_args(agent, to_member, cwd)
  return { agentName = agent, toMember = to_member, working_directory = dir(cwd) }
end

--- veto_landing: object to a landing, with the reason, on a live landing only.
---@return table arguments
function M.veto_args(agent, landing_id, reason, cwd)
  return {
    agentName = agent,
    landingId = landing_id,
    reason = reason,
    working_directory = dir(cwd),
  }
end

--- resolve_veto: the conductor clears a veto and the landing queues again.
---@return table arguments
function M.resolve_args(agent, landing_id, cwd)
  return { agentName = agent, landingId = landing_id, working_directory = dir(cwd) }
end

--- withdraw_landing: the requester takes their own landing back.
---@return table arguments
function M.withdraw_args(agent, landing_id, cwd)
  return { agentName = agent, landingId = landing_id, working_directory = dir(cwd) }
end

--- Why this agent name cannot be sent, or nil when it can.
---@return string|nil
function M.check_agent(agent, what)
  if type(agent) ~= "string" or agent:match("^%s*$") then
    return string.format(
      "%s needs the agent name the cohort knows you by, as its first argument. "
        .. "It is the name you joined with, not the one you would like to be called.",
      what)
  end
  return nil
end

--- Why this veto cannot be sent, or nil when it can. Two bounds, both from the
--- tool: a reason of 1 to 1000 characters, and a landing id.
---@return string|nil
function M.check_veto(reason, landing_id)
  if type(landing_id) ~= "string" or landing_id:match("^%s*$") then
    return "A veto names the landing it objects to, as its second argument: the landing id from :SageFsCohort."
  end
  if type(reason) ~= "string" or reason:match("^%s*$") then
    return string.format(
      "A veto needs a reason, as its third argument: one to %d characters, and it should say what is wrong "
        .. "with the landing rather than only that you dislike it. The requester reads this, and so does the "
        .. "conductor deciding whether to clear it.",
      M.REASON_MAX)
  end
  if #reason > M.REASON_MAX then
    return string.format(
      "That reason is %d characters and the tool takes at most %d. Say the part that matters first.",
      #reason, M.REASON_MAX)
  end
  return nil
end

--- The four commands, as data: the user command's name, the MCP tool it calls, and
--- how many arguments it wants (`arity`). `nargs` is deliberately NOT here: Neovim
--- refuses a numeric `nargs` above 1 ("Invalid 'nargs': 2"), so the command is
--- registered with `nargs = "+"` and the arity is checked in the handler, where a
--- short command gets a message naming what is missing instead of Neovim's own
--- error. That is also the only way a three-argument veto can say which argument
--- you left out.
---@return table[] commands
function M.commands()
  return {
    { name = "SageFsCohortDelegate", tool = "delegate_conductor", arity = 2, desc = "Hand the conductor seat to another present cohort member" },
    { name = "SageFsCohortVeto", tool = "veto_landing", arity = 3, desc = "Object to a landing, with the reason" },
    { name = "SageFsCohortResolveVeto", tool = "resolve_veto", arity = 2, desc = "Clear a veto as the conductor; the landing queues again" },
    { name = "SageFsCohortWithdraw", tool = "withdraw_landing", arity = 2, desc = "Withdraw your own landing" },
  }
end

--- Split a command's arguments into the agent, the landing-or-member id, and the
--- REASON. The reason is the rest of the line joined with spaces: a reason is
--- prose ("the landing drops the retry"), so it is one argument that happens to
--- contain spaces, and taking only the next word would both check the wrong string
--- and send the wrong one.
---
--- Pure, and shared by the handler and its pre-flight refusals so the string that
--- is CHECKED is the string that is SENT. That pairing is the whole point: two
--- places splitting the same line differently is how a bound gets checked against
--- one value and enforced on another.
---@param parts string[] the arguments as typed, already split on whitespace
---@return string agent, string id, string reason
function M.split_args(parts)
  local id, words = "", {}
  for i = 2, #parts do
    if i == 2 then
      id = parts[i]
    elseif parts[i] ~= "" then
      -- an empty word is skipped rather than joined, so a doubled space cannot
      -- inflate the reason's CHARACTER count against the tool's 1000 bound
      table.insert(words, parts[i])
    end
  end
  return parts[1] or "", id, table.concat(words, " ")
end

--- Why these arguments cannot make the call, or nil when they can. The arity is
--- checked here rather than by Neovim's `nargs`, so the message can say WHICH
--- argument is missing and what it means.
---@param nargs string the command's usage line
---@param parts string[] the arguments the user typed, already split
---@param arity number how many the command needs
---@return string|nil
function M.check_arity(parts, arity, usage)
  if #parts >= arity then return nil end
  local missing = {}
  local names = { "the agent name", "the landing id", "the reason" }
  -- parens around `#parts + 1`: LuaJIT reads the unparenthesised form as a call
  for i = (#parts + 1), arity do table.insert(missing, names[i] or ("argument " .. i)) end
  return string.format(
    "%s takes %d arguments and you gave %d. Missing: %s. Usage: %s",
    usage, arity, #parts, table.concat(missing, ", "), usage)
end

return M
