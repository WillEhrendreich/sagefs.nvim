require("spec.helper")

-- The plugin's version always matches the SageFs release it was tested
-- against: lua/sagefs/version.lua is written by sync-version.sh (or .ps1)
-- from SageFs's Directory.Build.props, and a ship hook on the SageFs side
-- cuts a plugin release at the same number.

local function read_all(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
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

  -- Lockstep guard against a SageFs checkout. Why it is strict only on request:
  -- the SageFs release script pushes SageFs first and bumps this file AFTER
  -- (scripts/sync-nvim-version writes version.lua, then runs this suite as its
  -- gate). So the plugin is legitimately one release behind a SageFs checkout
  -- for a while, and a checkout that has moved on to its next version, or sits
  -- on an older branch, must not make the plugin's suite red and block that
  -- sync. The plugin's CI has no SageFs checkout, so it is pending there.
  --
  --   SAGEFS_REPO=/path/to/SageFs  strict: fails when the numbers differ
  --   no SAGEFS_REPO, checkout found next to this repo (../SageFs, or the same
  --     from a git worktree under .worktrees/): runs, passes when equal, and
  --     is pending with both numbers (advisory) when they differ
  --   no checkout: pending, says how to point at one
  local function props_version(dir)
    local props = read_all(dir .. "/Directory.Build.props")
    return props and props:match("<Version>([^<]+)</Version>")
  end

  local function sibling_checkout()
    local root = repo_root()
    for _, rel in ipairs({ "/../SageFs", "/../../../SageFs" }) do
      local dir = root .. rel
      if props_version(dir) then return dir end
    end
    return nil
  end

  local function plugin_version()
    package.loaded["sagefs.version"] = nil
    return require("sagefs.version")
  end

  local explicit = os.getenv("SAGEFS_REPO")
  if explicit and explicit ~= "" then
    it("matches the SageFs release in SAGEFS_REPO (lockstep)", function()
      local release = props_version(explicit)
      assert.is_truthy(release, "no Directory.Build.props with a <Version> in SAGEFS_REPO=" .. explicit)
      assert.equals(release, plugin_version())
    end)
  else
    local dir = sibling_checkout()
    if not dir then
      pending("matches the SageFs release (lockstep): no SageFs checkout found next to this repo; "
        .. "set SAGEFS_REPO=/path/to/SageFs to check it")
    else
      it("matches the SageFs release in the neighbouring checkout (lockstep, advisory)", function()
        local release, mine = props_version(dir), plugin_version()
        if release ~= mine then
          pending(string.format("advisory: sagefs.nvim is %s, SageFs at %s is %s. If a SageFs release just went out, "
            .. "scripts/sync-nvim-version (or ./sync-version.sh %s) brings the plugin along. "
            .. "SAGEFS_REPO=%s makes this strict.", mine, dir, release, dir, dir))
        end
        assert.equals(release, mine)
      end)
    end
  end
end)

describe("sync-version.sh", function()
  local tmp, script

  before_each(function()
    local p = io.popen("mktemp -d")
    tmp = p:read("*l")
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

describe("sync-version.sh as shipped", function()
  it("is executable, so ./sync-version.sh (what the docs say to run) works", function()
    assert.is_true(sh("test -x " .. repo_root() .. "/sync-version.sh"))
  end)
end)
