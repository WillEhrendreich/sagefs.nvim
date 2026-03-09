require("spec.helper")

describe("sagefs.config", function()
  it("builds the per-project config path", function()
    local config = require("sagefs.config")
    assert.equals("C:\\Code\\MyProj\\.SageFs\\config.fsx", config.config_path("C:\\Code\\MyProj"))
  end)

  it("renders a template with AutoOpenNamespaces disabled", function()
    local config = require("sagefs.config")
    local template = config.auto_open_opt_out_template()
    assert.is_truthy(template:find("AutoOpenNamespaces = false", 1, true))
    assert.is_truthy(template:find("DirectoryConfig.empty", 1, true))
  end)

  it("creates the config when it does not exist", function()
    local config = require("sagefs.config")
    local mkdir_calls = {}
    local write_calls = {}

    vim.fn.filereadable = function() return 0 end
    vim.fn.mkdir = function(path, mode)
      table.insert(mkdir_calls, { path = path, mode = mode })
    end
    vim.fn.writefile = function(lines, path)
      table.insert(write_calls, { lines = lines, path = path })
    end

    local result = config.ensure_auto_open_opt_out("C:\\Code\\MyProj")
    assert.equals("created", result.status)
    assert.equals("C:\\Code\\MyProj\\.SageFs", mkdir_calls[1].path)
    assert.equals("p", mkdir_calls[1].mode)
    assert.equals("C:\\Code\\MyProj\\.SageFs\\config.fsx", write_calls[1].path)
  end)
end)
