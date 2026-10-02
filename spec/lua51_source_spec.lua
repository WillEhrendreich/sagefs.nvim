-- The GitHub workflow runs busted under PUC Lua 5.1, which has no "\u{XXXX}"
-- string escape (LuaJIT and 5.3+ do, so Neovim never notices). Such an escape
-- reads as the literal text "u{XXXX}" there. Write the character itself.
local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local function lua_files(dir)
  local out = {}
  local p = assert(io.popen('find "' .. dir .. '" -name "*.lua" 2>/dev/null'))
  for line in p:lines() do out[#out + 1] = line end
  p:close()
  return out
end

describe("source files that run under every supported Lua", function()
  for _, dir in ipairs({ "lua", "spec" }) do
    it("no \\u{...} escape under " .. dir .. "/ (Lua 5.1 does not have it)", function()
      local offenders = {}
      for _, path in ipairs(lua_files(dir)) do
        if path ~= "spec/lua51_source_spec.lua" then
          local n = 0
          for line in read(path):gmatch("[^\n]*") do
            if line:find("\\u{", 1, true) then n = n + 1 end
          end
          if n > 0 then offenders[#offenders + 1] = path .. " (" .. n .. ")" end
        end
      end
      assert.are.same({}, offenders)
    end)
  end
end)

describe("docs for contributors", function()
  for _, path in ipairs({ "README.md", "TESTING.md" }) do
    it(path .. " gives no Lua 5.4 or 5.5 guidance (the plugin targets LuaJIT, Lua 5.1 semantics)", function()
      local text = read(path)
      assert.is_nil(text:find("5%.4"), "mentions Lua 5.4")
      assert.is_nil(text:find("5%.5"), "mentions Lua 5.5")
    end)
  end
end)
