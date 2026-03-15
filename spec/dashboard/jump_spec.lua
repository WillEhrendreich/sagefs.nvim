-- spec/dashboard/jump_spec.lua — Jump-to-source tests
-- Tests the pure logic for resolving source locations from composed output

describe("dashboard jump-to-source", function()
  local compositor

  before_each(function()
    compositor = require("sagefs.dashboard.compositor")
  end)

  after_each(function()
    package.loaded["sagefs.dashboard.compositor"] = nil
  end)

  -- ─── resolve_source_at_line ────────────────────────────────────────────

  describe("resolve_source_at_line", function()
    it("returns source location when keymap has jump_to_source action", function()
      local composed = compositor.compose({
        {
          section_id = "failures",
          lines = { "═══ Failures ═══", "  🔴 MyTest", "     some summary" },
          highlights = {},
          keymaps = {
            {
              line = 1, key = "<CR>",
              action = {
                type = "jump_to_source",
                file = "src/Foo.fs",
                line = 42,
              },
            },
          },
        },
      })

      local source = compositor.resolve_source_at_line(composed, 1)
      assert.is_not_nil(source)
      assert.equals("src/Foo.fs", source.file)
      assert.equals(42, source.line)
    end)

    it("returns nil when no keymap at line", function()
      local composed = compositor.compose({
        {
          section_id = "health",
          lines = { "═══ Health ═══", "OK" },
          highlights = {},
          keymaps = {},
        },
      })

      local source = compositor.resolve_source_at_line(composed, 0)
      assert.is_nil(source)
    end)

    it("returns nil when keymap action is not jump_to_source", function()
      local composed = compositor.compose({
        {
          section_id = "tests",
          lines = { "═══ Tests ═══", "Run tests" },
          highlights = {},
          keymaps = {
            { line = 1, key = "<CR>", action = { type = "run_tests" } },
          },
        },
      })

      local source = compositor.resolve_source_at_line(composed, 1)
      assert.is_nil(source)
    end)

    it("returns nil when action has no file", function()
      local composed = compositor.compose({
        {
          section_id = "failures",
          lines = { "═══ Failures ═══", "  🔴 MyTest" },
          highlights = {},
          keymaps = {
            {
              line = 1, key = "<CR>",
              action = { type = "jump_to_source" },
            },
          },
        },
      })

      local source = compositor.resolve_source_at_line(composed, 1)
      assert.is_nil(source)
    end)

    it("handles offset from multi-section composition", function()
      local composed = compositor.compose({
        {
          section_id = "health",
          lines = { "═══ Health ═══", "OK" },
          highlights = {},
          keymaps = {},
        },
        {
          section_id = "failures",
          lines = { "═══ Failures ═══", "  🔴 MyTest" },
          highlights = {},
          keymaps = {
            {
              line = 1, key = "<CR>",
              action = {
                type = "jump_to_source",
                file = "src/Bar.fs",
                line = 99,
              },
            },
          },
        },
      })

      -- failures section starts at line 2, so keymap line 1 → composed line 3
      local source = compositor.resolve_source_at_line(composed, 3)
      assert.is_not_nil(source)
      assert.equals("src/Bar.fs", source.file)
      assert.equals(99, source.line)
    end)

    it("also resolves jump_to_test actions with file/line", function()
      local composed = compositor.compose({
        {
          section_id = "failures",
          lines = { "═══ Failures ═══", "  🔴 MyTest" },
          highlights = {},
          keymaps = {
            {
              line = 1, key = "<CR>",
              action = {
                type = "jump_to_test",
                test_name = "my test",
                file = "tests/MyTests.fs",
                line = 15,
              },
            },
          },
        },
      })

      local source = compositor.resolve_source_at_line(composed, 1)
      assert.is_not_nil(source)
      assert.equals("tests/MyTests.fs", source.file)
      assert.equals(15, source.line)
    end)
  end)
end)
