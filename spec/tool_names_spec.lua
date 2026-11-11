-- Every tool name the plugin sends to the daemon is a tool the daemon has.
-- A name the daemon does not know comes back as an error the user cannot act on, and
-- nothing in the plugin would notice, because the call site only sees "not ok".
-- The catalog is spec/daemon_tool_catalog.lua (copied from the daemon, source named there).
require("spec.helper")
local catalog = require("spec.daemon_tool_catalog")

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local function lua_files()
  local out = {}
  local p = assert(io.popen('find lua -name "*.lua" 2>/dev/null'))
  for line in p:lines() do out[#out + 1] = line end
  p:close()
  return out
end

-- The three shapes the plugin names a tool in: call_tool("name", ...),
-- `tool = "name"` (a command table or a request), and `TOOL = "name"` (a constant).
local PATTERNS = {
  'call_tool%("([%w_]+)"',
  '%f[%w]tool%s*=%s*"([%w_]+)"',
  '%f[%w]TOOL%s*=%s*"([%w_]+)"',
}

local function emitted()
  local found = {}
  for _, path in ipairs(lua_files()) do
    local text = read(path)
    for _, pat in ipairs(PATTERNS) do
      for name in text:gmatch(pat) do
        found[name] = found[name] or {}
        table.insert(found[name], path)
      end
    end
  end
  return found
end

describe("tool names the plugin emits", function()
  local names = catalog.name_set()
  local found = emitted()

  it("the scan finds the tools the plugin is known to call (the patterns have not rotted)", function()
    for _, known in ipairs({ "get_cohort_status", "delegate_conductor", "veto_landing", "resolve_veto",
                             "withdraw_landing", "mint_member", "revoke_member", "get_workspace_hygiene",
                             "nudge_value" }) do
      assert.is_truthy(found[known], "the scan did not find " .. known)
    end
  end)

  it("every emitted tool name is in the daemon's tool catalog", function()
    local unknown = {}
    for name, paths in pairs(found) do
      if not names[name] then unknown[#unknown + 1] = name .. " (" .. table.concat(paths, ", ") .. ")" end
    end
    table.sort(unknown)
    assert.equals("", table.concat(unknown, "; "), "tool names the daemon does not have")
  end)

  it("the cohort commands call a tool of that catalog", function()
    local actions = require("sagefs.cohort_actions")
    for _, c in ipairs(actions.commands()) do
      assert.is_truthy(names[c.tool], c.name .. " calls " .. c.tool .. ", which the daemon does not have")
    end
  end)

  it("the cohort argument builders emit only argument names the tools declare", function()
    local actions = require("sagefs.cohort_actions")
    local view = require("sagefs.cohort_view")
    local cases = {
      { "delegate_conductor", actions.delegate_args("a", "m", "/r") },
      { "veto_landing", actions.veto_args("a", "l", "why", "/r") },
      { "resolve_veto", actions.resolve_args("a", "l", "/r") },
      { "withdraw_landing", actions.withdraw_args("a", "l", "/r") },
      { "get_cohort_status", view.status_args("/r") },
    }
    for _, case in ipairs(cases) do
      local declared = {}
      for _, p in ipairs(catalog.params[case[1]]) do declared[p] = true end
      for key in pairs(case[2]) do
        assert.is_truthy(declared[key], case[1] .. " has no argument " .. key)
      end
      for p in pairs(declared) do
        if p ~= "session_id" then
          assert.is_not_nil(case[2][p], case[1] .. " is sent without its argument " .. p)
        end
      end
    end
  end)
end)
