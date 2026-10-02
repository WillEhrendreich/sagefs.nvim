-- sagefs/member_view.lua: :SageFsMintMember and :SageFsRevokeMember
--
-- Both call a conductor-only MCP tool on a daemon that mints per-run member
-- tokens. The daemon refuses anyone who is not the conductor, and says so; the
-- plugin shows its words. A mint reply holds the token, which SageFs shows once
-- and keeps only the hash of, so the reply goes to one float and nowhere else:
-- not to vim.notify (the message log keeps those), not to a log, and the
-- command line holds only the role, scope and minutes. The float is a scratch
-- buffer with no swap file, no undo and no entry in the buffer list, wiped when
-- it closes, and it closes when you leave its window.
--
-- The argument parsing and the flow are plain Lua over injected deps (client,
-- say, show_once) and are tested under busted; the float and the registration
-- touch the editor and are checked in spec/nvim_harness.lua.

local member_token = require("sagefs.member_token")
local mcp_client = require("sagefs.mcp_client")

local M = {}

--- What this plugin calls itself in the daemon's agentName argument.
M.AGENT_NAME = "sagefs.nvim"

--- The roles mint_member accepts, in the daemon's spelling.
M.ROLES = { "Observer", "Analysis", "Verifier", "Implementer" }

local MAX_MINUTES = 480
local USAGE_MINT = "Usage: :SageFsMintMember <Observer|Analysis|Verifier|Implementer> [scope] [minutes]"
local USAGE_REVOKE = "Usage: :SageFsRevokeMember cap:<hex> (the id :SageFsCohort shows for a minted run)"

local function level(name)
  return vim.log and vim.log.levels and vim.log.levels[name] or nil
end

-- ─── Pure: arguments ─────────────────────────────────────────────────────────

--- Read `<role> [scope] [minutes]`.
---@param fargs string[]
---@return { role: string, scope: string, ttl_minutes: integer }|nil args
---@return string|nil err
function M.parse_mint_args(fargs)
  fargs = fargs or {}
  if #fargs == 0 then return nil, USAGE_MINT end
  if #fargs > 3 then return nil, "Too many arguments. " .. USAGE_MINT end
  for _, a in ipairs(fargs) do
    -- A token pasted into the wrong place is never echoed back.
    if a:find("sfm_", 1, true) then
      return nil, "That looks like a member token. A token is never an argument here. " .. USAGE_MINT
    end
  end
  local role
  for _, r in ipairs(M.ROLES) do
    if r:lower() == fargs[1]:lower() then role = r end
  end
  if not role then
    return nil, string.format("%s is not a role. Roles: %s. %s", fargs[1], table.concat(M.ROLES, ", "), USAGE_MINT)
  end
  local scope = fargs[2] or ""
  if scope == "." then scope = "" end
  local minutes = 0
  if fargs[3] ~= nil then
    minutes = fargs[3]:match("^%d+$") and tonumber(fargs[3]) or nil
    if minutes == nil or minutes > MAX_MINUTES then
      return nil, string.format("Minutes is a whole number from 0 to %d (0 means the daemon's default). %s", MAX_MINUTES, USAGE_MINT)
    end
  end
  return { role = role, scope = scope, ttl_minutes = minutes }
end

--- Read `cap:<hex>`.
---@param fargs string[]
---@return string|nil id
---@return string|nil err
function M.parse_revoke_args(fargs)
  fargs = fargs or {}
  local id = fargs[1]
  if #fargs ~= 1 or type(id) ~= "string" then return nil, USAGE_REVOKE end
  if not id:match("^cap:%x+$") then
    return nil, "A revoke takes the id of a minted run, `cap:<hex>`. " .. USAGE_REVOKE
  end
  return id
end

-- ─── The float ───────────────────────────────────────────────────────────────

local function show_once(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].undolevels = -1
  local width = 40
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l) + 4) end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  width = math.min(width, vim.o.columns - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = math.min(#lines, vim.o.lines - 4),
    row = math.max(0, math.floor((vim.o.lines - #lines) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " SageFs member token (shown once) ",
  })
  local function close()
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  end
  vim.keymap.set("n", "q", close, { buffer = buf, silent = true, nowait = true })
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function() vim.schedule(close) end,
  })
end

local function say(msg, lvl)
  vim.notify("SageFs: " .. msg, lvl or level("INFO"))
end

-- ─── The flow ────────────────────────────────────────────────────────────────

local client = nil
local port_fn = function() return 37749 end

local function resolve(deps)
  deps = deps or {}
  if not deps.client and not client then client = mcp_client.connect(port_fn()) end
  return deps.client or client, deps.say or say, deps.show_once or show_once
end

local FOOTER = "This is the only time the token is shown. SageFs keeps only its hash. q or leaving this window closes it, and nothing here is saved."

--- Mint a member token and show it once.
---@param fargs string[]
---@param deps { client: table|nil, say: function|nil, show_once: function|nil }|nil
function M.mint(fargs, deps)
  local args, err = M.parse_mint_args(fargs)
  local c, tell, float = resolve(deps)
  if not args then tell(err, level("WARN")); return end
  c.call_tool("mint_member", {
    agentName = M.AGENT_NAME, role = args.role, scope = args.scope, ttl_minutes = args.ttl_minutes,
  }, function(ok, text)
    if not ok then
      tell("mint_member refused: " .. member_token.redact(text, nil), level("ERROR"))
      return
    end
    local member = text:match("cap:%x+")
    if not text:find("sfm_[A-Za-z0-9_%-]+") then
      tell(member_token.redact(text, nil), level("INFO"))
      return
    end
    local lines = vim.split(text, "\n", { plain = true })
    table.insert(lines, "")
    table.insert(lines, FOOTER)
    float(lines)
    tell(string.format("minted %s. The token is in the window, once.", member or "a member"), level("INFO"))
  end)
end

--- Revoke a minted member.
---@param fargs string[]
---@param deps { client: table|nil, say: function|nil, show_once: function|nil }|nil
function M.revoke(fargs, deps)
  local id, err = M.parse_revoke_args(fargs)
  local c, tell = resolve(deps)
  if not id then tell(err, level("WARN")); return end
  c.call_tool("revoke_member", { agentName = M.AGENT_NAME, member_id = id }, function(ok, text)
    local words = member_token.redact(text, nil)
    if ok then tell(words, level("INFO")) else tell("revoke_member refused: " .. words, level("ERROR")) end
  end)
end

-- ─── Registration ────────────────────────────────────────────────────────────

local function complete_role(lead, line)
  local parts = vim.split(line, "%s+")
  if #parts > 2 then return {} end
  local out = {}
  for _, r in ipairs(M.ROLES) do
    if r:lower():find(lead:lower(), 1, true) == 1 then table.insert(out, r) end
  end
  return out
end

--- Register the two commands.
---@param port function returns the daemon port
function M.register(port)
  port_fn = port or port_fn
  vim.api.nvim_create_user_command("SageFsMintMember", function(o) M.mint(o.fargs) end, {
    nargs = "*",
    complete = complete_role,
    desc = "Mint a cohort member token (role, scope, minutes) and show it once; conductor only",
  })
  vim.api.nvim_create_user_command("SageFsRevokeMember", function(o) M.revoke(o.fargs) end, {
    nargs = "*",
    desc = "Revoke a minted cohort member, cap:<hex>; conductor only",
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("SageFsMemberView", { clear = true }),
    callback = function() if client then client.close() end end,
  })
end

return M
