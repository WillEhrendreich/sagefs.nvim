-- The headless harnesses are CI gates only if a failing case makes nvim exit
-- non-zero. They print "Results: N passed, M failed" and then quit; ending in a
-- bare `qa!` quits 0 whatever M is, so a broken handler passes CI.

local function read(path)
  local f = assert(io.open(path, "r"), "cannot open " .. path)
  local s = f:read("*a")
  f:close()
  return s
end

local function last_code_line(path)
  local last
  for line in read(path):gmatch("[^\r\n]+") do
    if line:match("%S") then last = line end
  end
  return last
end

local harnesses = {
  "spec/nvim_harness.lua",
  "spec/nvim_display_harness.lua",
  "spec/treesitter_cells_spec.lua",
}

describe("headless harness exit codes", function()
  for _, path in ipairs(harnesses) do
    it(path .. " quits non-zero when a case failed", function()
      local line = last_code_line(path)
      assert.equals('if failed > 0 then vim.cmd("cquit 1") else vim.cmd("qa!") end', line)
    end)
  end
end)

describe("CI workflow", function()
  local workflow = read(".github/workflows/test.yml")

  it("runs the integration harness", function()
    assert.is_truthy(workflow:find("nvim --headless --clean -u NONE -l spec/nvim_harness.lua", 1, true))
  end)

  it("runs the display harness", function()
    assert.is_truthy(workflow:find("nvim --headless --clean -u NONE -l spec/nvim_display_harness.lua", 1, true))
  end)
end)
