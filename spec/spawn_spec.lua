require("spec.helper")

-- A missing binary used to surface as a raw Lua traceback (E475 out of
-- vim.fn.jobstart). Every spawn now goes through sagefs.spawn.jobstart,
-- which returns (job_id) or (nil, message) and never raises.

describe("sagefs.spawn", function()
  local spawn
  local original_fn

  before_each(function()
    package.loaded["sagefs.spawn"] = nil
    original_fn = vim.fn
    vim.fn = setmetatable({}, { __index = original_fn })
    spawn = require("sagefs.spawn")
  end)

  after_each(function()
    vim.fn = original_fn
    package.loaded["sagefs.spawn"] = nil
  end)

  describe("jobstart", function()
    it("returns the job id on success", function()
      vim.fn.jobstart = function() return 7 end
      assert.equals(7, spawn.jobstart({ "curl", "x" }, {}))
    end)

    it("turns a raised E475 into a message naming the binary", function()
      vim.fn.jobstart = function()
        error("Vim:E475: Invalid value for argument cmd: 'sagefs' is not executable", 0)
      end
      local id, err
      assert.has_no.errors(function() id, err = spawn.jobstart({ "sagefs", "--mcp-port", "1" }, {}) end)
      assert.is_nil(id)
      assert.is_truthy(err:find("sagefs", 1, true))
      assert.is_truthy(err:find("PATH", 1, true))
    end)

    it("turns a -1 return (not executable) into a message", function()
      vim.fn.jobstart = function() return -1 end
      local id, err = spawn.jobstart({ "curl" }, {})
      assert.is_nil(id)
      assert.is_truthy(err:find("curl", 1, true))
    end)

    it("turns a 0 return (invalid arguments) into a message", function()
      vim.fn.jobstart = function() return 0 end
      local id, err = spawn.jobstart({ "curl" }, {})
      assert.is_nil(id)
      assert.is_string(err)
    end)

    it("keeps an unrelated raised error's text", function()
      vim.fn.jobstart = function() error("E5108: something odd", 0) end
      local id, err = spawn.jobstart({ "curl" }, {})
      assert.is_nil(id)
      assert.is_truthy(err:find("something odd", 1, true))
    end)
  end)

  describe("binary_available", function()
    it("is true when vim.fn.executable says 1", function()
      vim.fn.executable = function(b) return b == "sagefs" and 1 or 0 end
      assert.is_true(spawn.binary_available("sagefs"))
      assert.is_false(spawn.binary_available("nope"))
    end)
  end)

  describe("missing_sagefs_message", function()
    it("says sagefs is not on PATH, how to install, and how to point the plugin at a binary", function()
      local m = spawn.missing_sagefs_message("sagefs")
      assert.is_truthy(m:find("sagefs is not on PATH", 1, true))
      assert.is_truthy(m:find("dotnet tool install --global sagefs", 1, true))
      assert.is_truthy(m:find("sagefs_path", 1, true))
    end)

    it("names the configured path when it is not the default", function()
      local m = spawn.missing_sagefs_message("/opt/nope/sagefs")
      assert.is_truthy(m:find("/opt/nope/sagefs", 1, true))
      assert.is_truthy(m:find("sagefs_path", 1, true))
      assert.is_truthy(m:find("dotnet tool install --global sagefs", 1, true))
    end)
  end)

  describe("missing_curl_message", function()
    it("says what curl is for and what to do", function()
      local m = spawn.missing_curl_message()
      assert.is_truthy(m:find("curl", 1, true))
      assert.is_truthy(m:find(":SageFsConnect", 1, true))
    end)
  end)
end)
