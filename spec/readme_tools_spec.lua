-- The README lists SageFs MCP tools, and the daemon retires them. A tool that left the daemon's
-- surface and is still in this README sends a reader (or an agent that read it) to a call that
-- does not exist. The README had eleven of them in a table, and nothing in this repo noticed.

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- Tool names the daemon no longer registers. Copied from SageFs: the first ten are
-- `RetiredTool` in SageFs.Core/Affordances.fs (and are checked against the live registry by
-- SageFs.Tests/RetiredToolNameTests.fs); `get_elm_state` and `explain_test_run` are the two
-- members SageFs.Tests/ToolDescriptionTests.fs lists as deliberately unregistered. Add a name
-- here when SageFs retires one.
local retired = {
  "create_session",
  "get_fsi_status",
  "get_startup_info",
  "load_fsharp_script",
  "explore_namespace",
  "explore_type",
  "get_completions",
  "get_file_coverage",
  "query_test_coverage",
  "visualize_domain_model",
  "get_elm_state",
  "explain_test_run",
}

-- A name counts as written when it stands alone: not inside a longer identifier.
local function mentions(text, name)
  return text:find("%f[%w_]" .. name .. "%f[^%w_]") ~= nil
end

-- The README section that lists the daemon's tools.
local function tools_section(readme)
  local start = readme:find("## SageFs MCP Tools Reference", 1, true)
  if not start then return "" end
  local stop = readme:find("\n## ", start + 4, true)
  return readme:sub(start, stop and stop - 1 or #readme)
end

-- Where a SageFs checkout is, if there is one: SAGEFS_REPO, else the sibling folder.
local function sagefs_tools_doc()
  local candidates = {}
  local env = os.getenv("SAGEFS_REPO")
  if env and env ~= "" then candidates[#candidates + 1] = env end
  candidates[#candidates + 1] = "../SageFs"
  for _, root in ipairs(candidates) do
    local doc = read(root .. "/docs/mcp-tools.md")
    if doc then return doc end
  end
  return nil
end

describe("README tool names", function()
  local readme = assert(read("README.md"))

  it("the matcher finds a whole name and not a piece of a longer one", function()
    assert.is_true(mentions("call `get_fsi_status` first", "get_fsi_status"))
    assert.is_true(mentions("| `explore_namespace` / `explore_type` |", "explore_type"))
    assert.is_false(mentions("get_fsi_status_extra", "get_fsi_status"))
    assert.is_false(mentions("my_get_fsi_status", "get_fsi_status"))
  end)

  it("names no tool the daemon has retired", function()
    local found = {}
    for _, name in ipairs(retired) do
      if mentions(readme, name) then found[#found + 1] = name end
    end
    assert.are.same({}, found)
  end)

  it("lists only tools the daemon's own tool page lists (when a SageFs checkout is there)", function()
    local doc = sagefs_tools_doc()
    if not doc then
      pending("no SageFs checkout at SAGEFS_REPO or ../SageFs, so the README tool names are not compared with docs/mcp-tools.md")
      return
    end
    local registered = {}
    for name in doc:gmatch("\n| `([a-z][a-z0-9_]*)` |") do registered[name] = true end
    local unknown = {}
    for name in tools_section(readme):gmatch("`([a-z][a-z0-9]*_[a-z0-9_]+)`") do
      if not registered[name] then unknown[#unknown + 1] = name end
    end
    assert.are.same({}, unknown)
  end)

  it("has a tool section to read, so the check above cannot pass by finding nothing", function()
    assert.is_true(#tools_section(readme) > 500)
  end)
end)
