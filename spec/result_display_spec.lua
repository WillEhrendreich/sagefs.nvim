require("spec.helper")
local format = require("sagefs.format")

-- The pure pieces of "always show the result": full result lines, wrapping to
-- the window, an inline summary that fits the line instead of running off the
-- right edge (a lemming's error read "Operation coul" and nothing more), and
-- the footer that says how to see the rest.

describe("sagefs.format.result_lines", function()
  it("returns every line of a long result, not the first 19", function()
    local out = {}
    for i = 1, 60 do out[i] = "line " .. i end
    local lines = format.result_lines({ ok = true, output = table.concat(out, "\n") })
    assert.are.equal(60, #lines)
    assert.are.equal("  line 1", lines[1].text)
    assert.are.equal("  line 60", lines[60].text)
  end)

  it("says (no output) for an empty success", function()
    local lines = format.result_lines({ ok = true, output = "" })
    assert.are.equal(1, #lines)
    assert.are.equal("  (no output)", lines[1].text)
  end)

  it("uses the error text and the error highlight for failures", function()
    local lines = format.result_lines({ ok = false, error = "boom\nsecond" })
    assert.are.equal(2, #lines)
    assert.are.equal("SageFsError", lines[1].hl)
  end)

  it("keeps a hard ceiling so a runaway result cannot stall a redraw", function()
    local out = {}
    for i = 1, 5000 do out[i] = "x" end
    local lines = format.result_lines({ ok = true, output = table.concat(out, "\n") })
    assert.is_true(#lines <= format.MAX_RESULT_LINES + 1)
    assert.is_truthy(lines[#lines].text:find("truncated", 1, true))
  end)
end)

describe("sagefs.format.wrap_lines", function()
  it("leaves lines that already fit alone", function()
    local wrapped = format.wrap_lines({ { text = "  short", hl = "A" } }, 40)
    assert.are.equal(1, #wrapped)
    assert.are.equal("  short", wrapped[1].text)
  end)

  it("breaks a long line into rows no wider than the window, keeping the highlight", function()
    local long = "  " .. string.rep("abcdefghij", 12) -- 122 chars
    local wrapped = format.wrap_lines({ { text = long, hl = "SageFsError" } }, 40)
    assert.is_true(#wrapped >= 4)
    for _, row in ipairs(wrapped) do
      assert.is_true(#row.text <= 40, "row too wide: " .. #row.text)
      assert.are.equal("SageFsError", row.hl)
    end
    -- nothing lost
    local joined = {}
    for _, row in ipairs(wrapped) do joined[#joined + 1] = (row.text:gsub("^%s+", "")) end
    assert.are.equal((long:gsub("^%s+", "")), table.concat(joined))
  end)

  it("does not split a multi-byte character", function()
    local wrapped = format.wrap_lines({ { text = string.rep("✓", 30), hl = "A" } }, 14)
    for _, row in ipairs(wrapped) do
      -- every row is whole characters: re-encoding it is valid
      assert.is_nil(row.text:find("^[\128-\191]"))
      local chars = 0
      for _ in row.text:gmatch("[^\128-\191][\128-\191]*") do chars = chars + 1 end
      assert.is_true(chars <= 14)
    end
  end)

  it("returns the lines unchanged when the width is too small to wrap sensibly", function()
    local lines = { { text = string.rep("a", 50), hl = "A" } }
    assert.are.equal(1, #format.wrap_lines(lines, 4))
  end)
end)

describe("sagefs.format.fit_inline", function()
  it("keeps text that fits", function()
    assert.are.equal("→ 42", format.fit_inline("→ 42", 30))
  end)

  it("cuts to the budget on a character boundary and marks the cut", function()
    local out = format.fit_inline("✖ Error: Evaluation failed: Exception: Operation could not be completed", 24)
    assert.are.equal(24, select(2, out:gsub("[^\128-\191]", "")), "display chars")
    assert.are.equal("…", out:sub(-3))
  end)

  it("returns nil when there is no room worth drawing into", function()
    assert.is_nil(format.fit_inline("→ 42", 5))
    assert.is_nil(format.fit_inline("→ 42", 0))
    assert.is_nil(format.fit_inline("→ 42", -3))
  end)
end)

describe("sagefs.format.expand_footer", function()
  it("names the count and the key", function()
    assert.are.equal("  … 14 more lines, <leader>rE to expand", format.expand_footer(14, "<leader>rE"))
  end)

  it("uses the singular for one line", function()
    assert.are.equal("  … 1 more line, <leader>rE to expand", format.expand_footer(1, "<leader>rE"))
  end)
end)

describe("sagefs.format.is_single_line", function()
  it("is true for one short line, whatever the trailing newline", function()
    assert.is_true(format.is_single_line("val x: int = 5"))
    assert.is_true(format.is_single_line("val x: int = 5\n"))
  end)

  it("is false for several lines", function()
    assert.is_false(format.is_single_line("a\nb"))
  end)
end)
