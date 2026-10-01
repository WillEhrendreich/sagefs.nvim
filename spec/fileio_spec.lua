require("spec.helper")

-- E482 regression: setup() wrote the one-time welcome marker under
-- stdpath("data") without creating the directory first, so a fresh machine
-- (or a container with an empty $XDG_DATA_HOME) died at startup with
-- "E482: Can't create file". Every plugin write now goes through
-- sagefs.fileio.write_file, which makes the parent directory first and
-- reports a failure as (false, message) instead of raising.

describe("sagefs.fileio.write_file", function()
  local original_fn

  before_each(function()
    package.loaded["sagefs.fileio"] = nil
    original_fn = vim.fn
    -- A filesystem in a table: directories that exist, files written.
    vim.fn = setmetatable({}, { __index = original_fn })
  end)

  after_each(function()
    vim.fn = original_fn
    package.loaded["sagefs.fileio"] = nil
  end)

  local function fake_fs(existing_dirs)
    local fs = { dirs = existing_dirs or {}, files = {}, mkdirs = {} }
    vim.fn.mkdir = function(dir, flags)
      table.insert(fs.mkdirs, { dir = dir, flags = flags })
      fs.dirs[dir] = true
      return 1
    end
    vim.fn.writefile = function(lines, path)
      local dir = path:match("^(.*)/[^/]*$")
      if not fs.dirs[dir] then
        error("Vim(call):E482: Can't create file " .. path, 0)
      end
      fs.files[path] = lines
      return 0
    end
    return fs
  end

  it("creates a missing parent directory before writing", function()
    local fs = fake_fs({})
    local fileio = require("sagefs.fileio")
    local ok, err = fileio.write_file("/home/u/.local/share/nvim/sagefs_welcomed", {})
    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals("/home/u/.local/share/nvim", fs.mkdirs[1].dir)
    assert.equals("p", fs.mkdirs[1].flags)
    assert.is_table(fs.files["/home/u/.local/share/nvim/sagefs_welcomed"])
  end)

  it("writes when the directory already exists", function()
    local fs = fake_fs({ ["/d"] = true })
    local fileio = require("sagefs.fileio")
    local ok = fileio.write_file("/d/marker", { "x" })
    assert.is_true(ok)
    assert.same({ "x" }, fs.files["/d/marker"])
  end)

  it("reports a failed mkdir as a message, never an error", function()
    vim.fn.mkdir = function() error("Vim(call):E739: Cannot create directory: /ro/x", 0) end
    vim.fn.writefile = function() error("E482: Can't create file", 0) end
    local fileio = require("sagefs.fileio")
    local ok, err
    assert.has_no.errors(function() ok, err = fileio.write_file("/ro/x/marker", {}) end)
    assert.is_false(ok)
    assert.is_truthy(err:find("/ro/x", 1, true))
  end)

  it("reports a failed write as a message naming the path, never an error", function()
    vim.fn.mkdir = function() return 1 end
    vim.fn.writefile = function() return -1 end
    local fileio = require("sagefs.fileio")
    local ok, err = fileio.write_file("/d/marker", {})
    assert.is_false(ok)
    assert.is_truthy(err:find("/d/marker", 1, true))
  end)

  it("handles a bare filename with no directory part", function()
    local fs = fake_fs({})
    vim.fn.writefile = function(lines, path) fs.files[path] = lines; return 0 end
    local fileio = require("sagefs.fileio")
    local ok = fileio.write_file("session_notebook.fsx", { "a" })
    assert.is_true(ok)
    assert.equals(0, #fs.mkdirs)
  end)
end)
