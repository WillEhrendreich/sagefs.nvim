-- sagefs/fileio.lua — The one place the plugin writes files.
-- Makes the parent directory first and turns every failure into a message,
-- so a missing or unwritable directory (a fresh machine's stdpath("data"),
-- a read-only home) can never raise out of setup() or a command.

local M = {}

--- Directory part of a path, or nil for a bare filename.
---@param path string
---@return string|nil
function M.parent_dir(path)
  local dir = path:match("^(.*)[/\\][^/\\]*$")
  if dir == nil or dir == "" then return nil end
  return dir
end

--- Write `lines` to `path`, creating the parent directory when needed.
---@param path string
---@param lines string[]
---@return boolean ok, string|nil err
function M.write_file(path, lines)
  local dir = M.parent_dir(path)
  if dir then
    local ok, err = pcall(vim.fn.mkdir, dir, "p")
    if not ok then
      return false, string.format("could not create directory %s: %s", dir, tostring(err))
    end
  end
  local ok, result = pcall(vim.fn.writefile, lines, path)
  if not ok then
    return false, string.format("could not write %s: %s", path, tostring(result))
  end
  if result == -1 then
    return false, string.format("could not write %s", path)
  end
  return true, nil
end

return M
