local M = {}

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
    vim.fn.mkdir(config_dir, "p")
    vim.fn.writefile(vim.split(M.auto_open_opt_out_template(), "\n", { plain = true }), path)
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
