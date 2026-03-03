-- sagefs/health.lua — :checkhealth sagefs integration
-- Neovim health check for SageFs plugin: daemon availability,
-- connection status, treesitter parser, configuration.

local M = {}

function M.check()
  vim.health.start("sagefs")

  -- Check SageFs CLI availability
  local ok_cli = pcall(function()
    local result = vim.fn.system("sagefs --version")
    if vim.v.shell_error ~= 0 then error("not found") end
    return result
  end)
  if ok_cli then
    vim.health.ok("SageFs CLI found")
  else
    vim.health.error("SageFs CLI not found", {
      "Install with: dotnet tool install -g sagefs",
      "See https://github.com/WillEhrendreich/SageFs",
    })
  end

  -- Check plugin loaded
  local ok_plugin, sagefs = pcall(require, "sagefs")
  if ok_plugin and sagefs.state then
    vim.health.ok("sagefs.nvim loaded")
    -- Check connection
    if sagefs.state.status == "connected" then
      vim.health.ok("Connected to SageFs daemon")
    elseif sagefs.state.status == "reconnecting" then
      vim.health.warn("Reconnecting to SageFs daemon", {
        "Check that the daemon is running: sagefs --proj <your.fsproj>",
      })
    else
      vim.health.info("Not connected (status: " .. (sagefs.state.status or "unknown") .. ")", {
        "Run :SageFsStart or :SageFsConnect to connect",
      })
    end
  else
    vim.health.info("sagefs.nvim not yet initialized (call require('sagefs').setup() first)")
  end

  -- Check treesitter F# parser
  local ok_ts, parsers = pcall(require, "nvim-treesitter.parsers")
  if ok_ts and parsers then
    local has_fsharp = parsers.has_parser and parsers.has_parser("fsharp")
    if has_fsharp then
      vim.health.ok("Tree-sitter F# parser installed (improved cell detection)")
    else
      vim.health.info("Tree-sitter F# parser not installed (optional)", {
        "Install with: :TSInstall fsharp",
        "Improves cell boundary detection inside strings/comments",
      })
    end
  else
    vim.health.info("nvim-treesitter not found (optional, improves cell detection)")
  end

  -- Check curl availability (needed for HTTP transport)
  local ok_curl = pcall(function()
    vim.fn.system("curl --version")
    if vim.v.shell_error ~= 0 then error("not found") end
  end)
  if ok_curl then
    vim.health.ok("curl available (required for SSE event stream)")
  else
    vim.health.error("curl not found", {
      "curl is required for the SSE event stream (live updates, test results, coverage)",
      "HTTP eval requests use vim.uv TCP and don't require curl",
    })
  end
end

return M
