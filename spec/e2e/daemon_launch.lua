-- spec/e2e/daemon_launch.lua: how an e2e suite starts its own daemon
-- Pure Lua, no vim dependency, so spec/daemon_launch_spec.lua can test it.
--
-- An e2e daemon must not touch the user's real SageFs state and must not outlive
-- the test run:
--   * SAGEFS_DATA_DIR gives it its own manifest directory (the daemon resumes the
--     sessions it finds there, and writes there);
--   * --no-resume skips what a data directory might still hold;
--   * --owner-pid ends it when the Neovim running the suite exits, however that
--     happens, and --ttl is the backstop for a daemon with no sessions and no
--     clients.

local M = {}

---@param bin string path of the sagefs binary
---@param port number MCP port (the dashboard is the next one up)
---@param owner_pid number pid of the Neovim running the suite
---@return string[]
function M.command(bin, port, owner_pid)
  return {
    bin,
    "--mcp-port", tostring(port),
    "--no-resume",
    "--owner-pid", tostring(owner_pid),
    "--ttl", "4h",
  }
end

--- The environment variables to add for the daemon.
---@param data_dir string a directory that is not the user's own
---@return table<string, string>
function M.environment(data_dir)
  if type(data_dir) ~= "string" or data_dir == "" then
    error("an e2e daemon needs its own SAGEFS_DATA_DIR; with none it would use the user's ~/.SageFs", 2)
  end
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
  local own = home ~= "" and (home .. "/.SageFs") or nil
  if own and (data_dir == own or data_dir == own .. "/") then
    error("refusing the user's own data directory " .. data_dir, 2)
  end
  return { SAGEFS_DATA_DIR = data_dir }
end

return M
