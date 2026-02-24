require("spec.helper")
local hr = require("sagefs.hotreload_model")

describe("hotreload_model", function()
  -- ─── build_url ───────────────────────────────────────────────────────────
  describe("build_url", function()
    it("builds base URL with port and session", function()
      local url = hr.build_url(37750, "abc-123", "")
      assert.are.equal("http://localhost:37750/api/sessions/abc-123/hotreload", url)
    end)

    it("appends suffix", function()
      local url = hr.build_url(37750, "abc", "/toggle")
      assert.are.equal("http://localhost:37750/api/sessions/abc/hotreload/toggle", url)
    end)

    it("handles nil suffix", function()
      local url = hr.build_url(37750, "abc")
      assert.are.equal("http://localhost:37750/api/sessions/abc/hotreload", url)
    end)

    it("uses custom port", function()
      local url = hr.build_url(9999, "s1", "/watch-all")
      assert.truthy(url:match(":9999/"))
    end)
  end)

  -- ─── new ─────────────────────────────────────────────────────────────────
  describe("new", function()
    it("returns empty state", function()
      local s = hr.new()
      assert.is_table(s)
      assert.is_table(s.files)
      assert.are.equal(0, #s.files)
      assert.are.equal(0, s.watched_count)
    end)

    it("returns independent instances", function()
      local a = hr.new()
      local b = hr.new()
      table.insert(a.files, { path = "x" })
      assert.are.equal(0, #b.files)
    end)
  end)

  -- ─── apply_response ──────────────────────────────────────────────────────
  describe("apply_response", function()
    it("applies server response", function()
      local s = hr.new()
      local resp = {
        files = { { path = "a.fs", watched = true }, { path = "b.fs", watched = false } },
        watchedCount = 1,
      }
      hr.apply_response(s, resp)
      assert.are.equal(2, #s.files)
      assert.are.equal(1, s.watched_count)
    end)

    it("handles nil response", function()
      local s = hr.new()
      local r = hr.apply_response(s, nil)
      assert.are.equal(s, r)
    end)

    it("handles empty files", function()
      local s = hr.new()
      hr.apply_response(s, { files = {} })
      assert.are.equal(0, #s.files)
    end)
  end)

  -- ─── format_picker_items ─────────────────────────────────────────────────
  describe("format_picker_items", function()
    it("returns empty for empty state", function()
      local s = hr.new()
      assert.are.same({}, hr.format_picker_items(s))
    end)

    it("formats files with watched/unwatched indicators", function()
      local s = hr.new()
      s.files = {
        { path = "src/App.fs", watched = true },
        { path = "src/Lib.fs", watched = false },
      }
      local items = hr.format_picker_items(s)
      -- 2 files + watch all + unwatch all = 4 items
      assert.are.equal(4, #items)
      -- File items
      assert.truthy(items[1].label:match("●"), "watched file should have ●")
      assert.truthy(items[2].label:match("○"), "unwatched file should have ○")
      assert.are.equal("toggle", items[1].action)
      assert.are.equal("src/App.fs", items[1].path)
    end)

    it("includes watch-all and unwatch-all actions", function()
      local s = hr.new()
      s.files = { { path = "a.fs", watched = false } }
      local items = hr.format_picker_items(s)
      local actions = {}
      for _, item in ipairs(items) do
        actions[item.action] = true
      end
      assert.is_true(actions["watch_all"])
      assert.is_true(actions["unwatch_all"])
    end)
  end)

  -- ─── format_prompt ───────────────────────────────────────────────────────
  describe("format_prompt", function()
    it("shows watched/total counts", function()
      local s = { files = { {}, {}, {} }, watched_count = 2 }
      local prompt = hr.format_prompt(s)
      assert.truthy(prompt:match("2/3"))
    end)

    it("shows 0/0 for empty state", function()
      local s = hr.new()
      local prompt = hr.format_prompt(s)
      assert.truthy(prompt:match("0/0"))
    end)
  end)

  -- ─── parse_selection ─────────────────────────────────────────────────────
  describe("parse_selection", function()
    it("returns nil for nil selection", function()
      assert.is_nil(hr.parse_selection(nil))
    end)

    it("extracts action and path", function()
      local sel = hr.parse_selection({ action = "toggle", path = "a.fs", label = "● a.fs" })
      assert.are.equal("toggle", sel.action)
      assert.are.equal("a.fs", sel.path)
    end)

    it("handles watch_all action", function()
      local sel = hr.parse_selection({ action = "watch_all", label = "Watch All" })
      assert.are.equal("watch_all", sel.action)
    end)
  end)
end)
