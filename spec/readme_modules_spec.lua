-- The README's module table is the map of lua/sagefs/. A module that is not in
-- it is invisible to a reader, so every top-level file has to appear.

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local function module_files()
  local out = {}
  local p = assert(io.popen('ls lua/sagefs/*.lua 2>/dev/null'))
  for line in p:lines() do out[#out + 1] = line:match("([^/]+%.lua)$") end
  p:close()
  table.sort(out)
  return out
end

describe("README module table", function()
  local readme = read("README.md")

  it("has a row for every top-level module in lua/sagefs/", function()
    -- The README's table names each module by FILE (`cohort.lua`), which is what a reader
    -- greps for, so the match includes the extension. It used to match the bare name, which
    -- matched nothing at all — every one of the 70+ modules read as missing, and the suite
    -- reported that rather than the real cause.
    local missing = {}
    for _, name in ipairs(module_files()) do
      if not readme:find("| `" .. name .. "` |", 1, true) then missing[#missing + 1] = name end
    end
    assert.are.same({}, missing)
  end)

  it("does not state a count of generated windows (it rots with every loop bound)", function()
    assert.is_nil(readme:find("%d%d%d%d+ generated windows"))
  end)
end)
