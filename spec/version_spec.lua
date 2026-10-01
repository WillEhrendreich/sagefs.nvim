require("spec.helper")

-- The plugin's version always matches the SageFs release it was tested
-- against: lua/sagefs/version.lua is written by sync-version.sh (or .ps1)
-- from SageFs's Directory.Build.props, and a ship hook on the SageFs side
-- cuts a plugin release at the same number.

local function read_all(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function sh(cmd)
  local ok, how, code = os.execute(cmd)
  return ok == true or ok == 0, code or how
end

local function repo_root()
  local src = debug.getinfo(1, "S").source:match("@(.*)/spec/[^/]*$")
  return src or "."
end

describe("sagefs.version", function()
  it("is a plain major.minor.patch version string", function()
    package.loaded["sagefs.version"] = nil
    local v = require("sagefs.version")
    assert.is_string(v)
    assert.is_truthy(v:match("^%d+%.%d+%.%d+$"), "not a plain version: " .. tostring(v))
  end)

  -- Opt-in lockstep guard: SAGEFS_REPO=/path/to/SageFs busted ... fails when
  -- the plugin has fallen behind the SageFs release in that checkout.
  local sagefs_repo = os.getenv("SAGEFS_REPO")
  local guard = sagefs_repo and sagefs_repo ~= "" and it or pending
  guard("matches the SageFs release in SAGEFS_REPO (lockstep)", function()
    local props = assert(read_all(sagefs_repo .. "/Directory.Build.props"), "no Directory.Build.props in SAGEFS_REPO")
    local release = props:match("<Version>([^<]+)</Version>")
    package.loaded["sagefs.version"] = nil
    assert.equals(release, require("sagefs.version"))
  end)
end)

describe("sync-version.sh", function()
  local tmp, script

  before_each(function()
    local p = io.popen("mktemp -d")
    tmp = p:read("l")
    p:close()
    assert.is_truthy(tmp and tmp ~= "")
    sh("mkdir -p " .. tmp .. "/plugin/lua/sagefs " .. tmp .. "/SageFs")
    sh("cp " .. repo_root() .. "/sync-version.sh " .. tmp .. "/plugin/sync-version.sh")
    script = tmp .. "/plugin/sync-version.sh"
  end)

  after_each(function()
    sh("rm -rf " .. tmp)
  end)

  it("writes the SageFs release from Directory.Build.props into version.lua", function()
    local f = io.open(tmp .. "/SageFs/Directory.Build.props", "w")
    f:write("<Project>\n  <PropertyGroup>\n    <Version>1.2.3</Version>\n  </PropertyGroup>\n</Project>\n")
    f:close()
    assert.is_true(sh("bash " .. script .. " " .. tmp .. "/SageFs > /dev/null"))
    assert.equals('return "1.2.3"\n', read_all(tmp .. "/plugin/lua/sagefs/version.lua"))
  end)

  it("fails, and leaves version.lua alone, when Directory.Build.props is missing", function()
    local f = io.open(tmp .. "/plugin/lua/sagefs/version.lua", "w")
    f:write('return "9.9.9"\n')
    f:close()
    assert.is_false(sh("bash " .. script .. " " .. tmp .. "/SageFs > /dev/null 2>&1"))
    assert.equals('return "9.9.9"\n', read_all(tmp .. "/plugin/lua/sagefs/version.lua"))
  end)
end)
