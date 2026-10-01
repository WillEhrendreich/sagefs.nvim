-- spec/nvim_display_harness.lua — headless-Neovim specs for how results and
-- sessions appear (render placement, :SageFsResult, :SageFsHelp, the hint).
-- Usage: nvim --headless --clean -u NONE -l spec/nvim_display_harness.lua
-- Self-contained like spec/nvim_harness.lua (no busted); exits non-zero on failure.

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])")
local plugin_root = script_dir .. ".."
vim.opt.rtp:prepend(plugin_root)
package.path = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;" .. package.path

local passed, failed, errors = 0, 0, {}
local suite = ""
local function describe(name, fn) suite = name; fn(); suite = "" end
local function it(name, fn)
  local label = suite ~= "" and (suite .. " > " .. name) or name
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write("  ✓ " .. label .. "\n")
  else
    failed = failed + 1
    errors[#errors + 1] = { label = label, err = tostring(err) }
    io.write("  ✖ " .. label .. "\n    " .. tostring(err) .. "\n")
  end
end
local function ok_(v, msg) if not v then error(msg or ("expected truthy, got " .. tostring(v)), 2) end end
local function eq(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", msg or "eq", tostring(expected), tostring(actual)), 2)
  end
end

local model = require("sagefs.model")
local render = require("sagefs.render")

local function make_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

--- A `;;`-terminated cell of `n` lines (lines 1..n, `;;` on line n).
local function tall_cell_lines(n)
  local lines = {}
  for i = 1, n - 1 do lines[i] = "let v" .. i .. " = " .. i end
  lines[n] = "v1;;"
  return lines
end

local function result_of(n_lines)
  local out = {}
  for i = 1, n_lines do out[i] = "res" .. i end
  return table.concat(out, "\n")
end

local function evaluated(buf, id, output, meta)
  local state = model.new()
  meta = meta or {}
  meta.buf = buf
  state = model.set_cell_state(state, id, "running", nil, meta)
  state = model.set_cell_state(state, id, "success", output, meta)
  return state
end

--- marks that draw result text: { row0, virt_lines = n, virt_text = string|nil, last = string|nil }
local function result_marks(buf)
  local out = {}
  local marks = vim.api.nvim_buf_get_extmarks(buf, render.get_namespace(), 0, -1, { details = true })
  for _, m in ipairs(marks) do
    local d = m[4] or {}
    local vl = d.virt_lines
    local is_codelens = vl and vl[1] and vl[1][1] and vl[1][1][1] == "▶ Eval"
    if not is_codelens and (d.virt_text or vl) then
      local last
      if vl and vl[#vl] and vl[#vl][1] then last = vl[#vl][1][1] end
      out[#out + 1] = {
        row0 = m[2],
        virt_lines = vl and #vl or 0,
        virt_text = d.virt_text and d.virt_text[1] and d.virt_text[1][1] or nil,
        last = last,
      }
    end
  end
  return out
end

io.write("\n═══ sagefs.nvim display specs (headless Neovim) ═══\n\n")

describe("result placement in a real window", function()
  it("shows the result of a cell taller than the window, anchored where the user evaluated", function()
    local buf = make_buffer(tall_cell_lines(120))
    vim.api.nvim_win_set_cursor(0, { 10, 0 })
    vim.cmd("normal! zt")
    local state = evaluated(buf, 1, result_of(5), { end_line = 120, anchor_line = 10 })
    render.render_all(buf, state)
    local top, bot = vim.fn.line("w0"), vim.fn.line("w$")
    local marks = result_marks(buf)
    ok_(#marks >= 1, "a result is drawn")
    for _, m in ipairs(marks) do
      ok_(m.row0 + 1 >= top and m.row0 + 1 <= bot,
        string.format("result on line %d is outside the window %d..%d", m.row0 + 1, top, bot))
    end
    eq(9, marks[1].row0, "anchored on the evaluated line (10)")
  end)

  it("keeps a short result on the cell's last line, as before", function()
    local buf = make_buffer({ "let a = 1", "a + 1;;", "", "let b = 2;;" })
    local state = evaluated(buf, 1, "val it: int = 2", { end_line = 2, anchor_line = 1 })
    render.render_all(buf, state)
    local marks = result_marks(buf)
    ok_(#marks >= 1)
    eq(1, marks[1].row0, "cell end line (2)")
  end)

  it("draws a single-line result inline only, without a duplicate virtual line", function()
    local buf = make_buffer({ "let a = 1", "a + 1;;" })
    local state = evaluated(buf, 1, "val it: int = 2", { end_line = 2, anchor_line = 2 })
    render.render_all(buf, state)
    local total_virt_lines = 0
    local inline
    for _, m in ipairs(result_marks(buf)) do
      total_virt_lines = total_virt_lines + m.virt_lines
      inline = inline or m.virt_text
    end
    eq(0, total_virt_lines, "no virtual lines for a one-line result")
    ok_(inline and inline:find("val it: int = 2", 1, true), "inline text carries the result")
  end)

  it("truncates a tall result with an 'N more lines, <key> to expand' footer", function()
    local buf = make_buffer({ "let a = 1", "a + 1;;" })
    local state = evaluated(buf, 1, result_of(80), { end_line = 2, anchor_line = 2 })
    render.render_all(buf, state)
    local m
    for _, mk in ipairs(result_marks(buf)) do if mk.virt_lines > 0 then m = mk end end
    ok_(m, "virtual lines drawn")
    ok_(m.virt_lines <= vim.api.nvim_win_get_height(0), "fits the window")
    ok_(m.last:find("more lines", 1, true) and m.last:find("to expand", 1, true), "footer: " .. tostring(m.last))
    ok_(m.last:find("<leader>rE", 1, true), "footer names the key: " .. tostring(m.last))
  end)

  it("cuts the inline summary to the room on the line instead of running off the edge", function()
    local buf = make_buffer({ "let a = 1", "a + 1;;" })
    local long = "Evaluation failed: " .. string.rep("because of an earlier error ", 12)
    local state = model.new()
    state = model.set_cell_state(state, 1, "running", nil, { buf = buf })
    state = model.set_cell_state(state, 1, "error", long, { buf = buf, end_line = 2, anchor_line = 2 })
    render.render_all(buf, state)
    local width = vim.api.nvim_win_get_width(0)
    for _, m in ipairs(result_marks(buf)) do
      if m.virt_text then
        ok_(vim.fn.strdisplaywidth("a + 1;;" .. m.virt_text) <= width,
          "inline text overflows the window: " .. vim.fn.strdisplaywidth(m.virt_text) .. " > " .. width)
      end
    end
  end)

  it("does not draw another buffer's cell result (cell ids are per buffer, not global)", function()
    local a = make_buffer({ "let a = 1;;" })
    local b = make_buffer({ "let b = 2;;" })
    local state = evaluated(a, 1, "val a: int = 1", { end_line = 1, anchor_line = 1 })
    render.render_all(b, state)
    eq(0, #result_marks(b), "buffer b must not show buffer a's result")
    render.render_all(a, state)
    ok_(#result_marks(a) > 0, "buffer a still shows its own result")
  end)

  it("re-anchors inside the window when the view scrolls away from the first anchor", function()
    local buf = make_buffer(tall_cell_lines(200))
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    vim.cmd("normal! zt")
    local state = evaluated(buf, 1, result_of(3), { end_line = 200, anchor_line = 5 })
    render.render_all(buf, state)
    vim.api.nvim_win_set_cursor(0, { 120, 0 })
    vim.cmd("normal! zt")
    render.render_all(buf, state)
    local top, bot = vim.fn.line("w0"), vim.fn.line("w$")
    for _, m in ipairs(result_marks(buf)) do
      ok_(m.row0 + 1 >= top and m.row0 + 1 <= bot,
        string.format("result on line %d is outside the window %d..%d", m.row0 + 1, top, bot))
    end
  end)
end)

io.write(string.format("\n═══ Results: %d passed, %d failed ═══\n", passed, failed))
for _, e in ipairs(errors) do io.write("  ✖ " .. e.label .. "\n    " .. e.err .. "\n") end
if failed > 0 then vim.cmd("cquit 1") else vim.cmd("qa!") end
