-- sagefs/spawn.lua — The one place the plugin starts external processes.
-- vim.fn.jobstart raises E475 when the binary is missing, which used to
-- surface as a raw Lua traceback. jobstart here returns (job_id) or
-- (nil, message) and never raises, and the messages say what to do.

local M = {}

local INSTALL = "dotnet tool install --global sagefs"

--- Start a job without ever raising.
---@param cmd string[]
---@param opts table jobstart options
---@return integer|nil job_id, string|nil err
function M.jobstart(cmd, opts)
  local bin = cmd[1] or "?"
  local ok, result = pcall(vim.fn.jobstart, cmd, opts)
  if not ok then
    local text = tostring(result)
    if text:find("not executable", 1, true) or text:find("E475", 1, true) then
      return nil, string.format("%s is not on PATH (or is not executable)", bin)
    end
    return nil, string.format("could not start %s: %s", bin, text)
  end
  if type(result) ~= "number" or result == -1 then
    return nil, string.format("%s is not on PATH (or is not executable)", bin)
  end
  if result == 0 then
    return nil, string.format("could not start %s: invalid arguments", bin)
  end
  return result, nil
end

--- The binary to run for a configured sagefs_path. `~` and `$VAR` are expanded
--- (vim.fn.executable and jobstart do not do it), anything else is left alone
--- so characters like `%` and `#` in a real path are not read as filename
--- modifiers. nil and the empty string mean the default, "sagefs".
---@param bin string|nil
---@return string
function M.resolve_binary(bin)
  if type(bin) ~= "string" or bin == "" then return "sagefs" end
  if bin:sub(1, 1) == "~" or bin:find("$", 1, true) then return vim.fn.expand(bin) end
  return bin
end

--- True when `bin` resolves to something executable. Assumes yes when the
--- check is unavailable (a spawn failure is still handled by jobstart).
---@param bin string
---@return boolean
function M.binary_available(bin)
  if type(vim.fn.executable) ~= "function" then return true end
  return vim.fn.executable(bin) == 1
end

--- The actionable message for a missing sagefs binary.
---@param bin string|nil the configured sagefs_path (default "sagefs")
---@return string
function M.missing_sagefs_message(bin)
  bin = (bin and bin ~= "") and bin or "sagefs"
  local how_to_point = "If it is installed somewhere else, point the plugin at it: "
    .. "require(\"sagefs\").setup({ sagefs_path = \"/full/path/to/sagefs\" })."
  if bin == "sagefs" then
    return "sagefs is not on PATH. Install: " .. INSTALL
      .. " (needs the .NET SDK), then restart Neovim so it sees the new PATH. " .. how_to_point
  end
  return string.format("sagefs_path = %q is not an executable file. Fix the path in setup({ sagefs_path = ... }), "
    .. "or install sagefs: %s and use the default.", bin, INSTALL)
end

--- The actionable message for a missing curl (the SSE stream spawns it).
---@return string
function M.missing_curl_message()
  return "curl is not on PATH, and the live event stream (results, tests, coverage) runs through it. "
    .. "Install curl with your package manager, then run :SageFsConnect."
end

return M
