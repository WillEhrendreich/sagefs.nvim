-- RED tests for hotreload pure logic extraction
-- hotreload.lua currently mixes vim APIs with logic.
-- These tests define the pure functions that should be extracted.

require("spec.helper")

-- This require will fail until hotreload_model.lua is created
local ok, hrm = pcall(require, "sagefs.hotreload_model")
if not ok then
  hrm = {}
end

-- ─── URL builder ─────────────────────────────────────────────────────────────

describe("hotreload_model.build_url [RED]", function()
  it("builds the hot reload base URL", function()
    assert.is_function(hrm.build_url)
    local url = hrm.build_url(37750, "session-123", "")
    assert.are.equal("http://localhost:37750/api/sessions/session-123/hotreload", url)
  end)

  it("builds toggle endpoint URL", function()
    local url = hrm.build_url(37750, "s1", "/toggle")
    assert.are.equal("http://localhost:37750/api/sessions/s1/hotreload/toggle", url)
  end)

  it("builds watch-all endpoint URL", function()
    local url = hrm.build_url(37750, "s1", "/watch-all")
    assert.are.equal("http://localhost:37750/api/sessions/s1/hotreload/watch-all", url)
  end)

  it("builds unwatch-all endpoint URL", function()
    local url = hrm.build_url(37750, "s1", "/unwatch-all")
    assert.are.equal("http://localhost:37750/api/sessions/s1/hotreload/unwatch-all", url)
  end)
end)

-- ─── State management ────────────────────────────────────────────────────────

describe("hotreload_model.new [RED]", function()
  it("creates empty hotreload state", function()
    assert.is_function(hrm.new)
    local state = hrm.new()
    assert.is_table(state)
    assert.is_table(state.files)
    assert.are.equal(0, state.watched_count)
  end)
end)

describe("hotreload_model.apply_response [RED]", function()
  it("populates state from server response", function()
    local state = hrm.new()
    local response = {
      files = {
        { path = "src/Math.fs", watched = true },
        { path = "src/Net.fs", watched = false },
        { path = "src/App.fs", watched = true },
      },
      watchedCount = 2,
    }
    state = hrm.apply_response(state, response)
    assert.are.equal(3, #state.files)
    assert.are.equal(2, state.watched_count)
  end)

  it("handles empty response gracefully", function()
    local state = hrm.new()
    state = hrm.apply_response(state, nil)
    assert.are.equal(0, #state.files)
    assert.are.equal(0, state.watched_count)
  end)

  it("handles response with no files", function()
    local state = hrm.new()
    state = hrm.apply_response(state, { files = {}, watchedCount = 0 })
    assert.are.equal(0, #state.files)
  end)
end)

-- ─── Picker item formatting ──────────────────────────────────────────────────

describe("hotreload_model.format_picker_items [RED]", function()
  it("formats files with watched/unwatched indicators", function()
    local state = hrm.new()
    state = hrm.apply_response(state, {
      files = {
        { path = "src/Math.fs", watched = true },
        { path = "src/Net.fs", watched = false },
      },
      watchedCount = 1,
    })
    local items = hrm.format_picker_items(state)
    assert.is_table(items)
    -- Should include the 2 files + 2 bulk actions (Watch All, Unwatch All)
    assert.are.equal(4, #items)
  end)

  it("marks watched files with filled indicator", function()
    local state = hrm.new()
    state = hrm.apply_response(state, {
      files = { { path = "src/Math.fs", watched = true } },
      watchedCount = 1,
    })
    local items = hrm.format_picker_items(state)
    local found = false
    for _, item in ipairs(items) do
      if item.path == "src/Math.fs" then
        assert.is_truthy(item.label:find("●"))
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("marks unwatched files with empty indicator", function()
    local state = hrm.new()
    state = hrm.apply_response(state, {
      files = { { path = "src/Net.fs", watched = false } },
      watchedCount = 0,
    })
    local items = hrm.format_picker_items(state)
    local found = false
    for _, item in ipairs(items) do
      if item.path == "src/Net.fs" then
        assert.is_truthy(item.label:find("○"))
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("includes watch-all and unwatch-all actions", function()
    local state = hrm.new()
    state = hrm.apply_response(state, {
      files = { { path = "src/Math.fs", watched = false } },
      watchedCount = 0,
    })
    local items = hrm.format_picker_items(state)
    local actions = {}
    for _, item in ipairs(items) do
      if item.action then actions[item.action] = true end
    end
    assert.is_true(actions["watch_all"] ~= nil)
    assert.is_true(actions["unwatch_all"] ~= nil)
  end)

  it("formats prompt with watch count", function()
    local state = hrm.new()
    state = hrm.apply_response(state, {
      files = {
        { path = "a.fs", watched = true },
        { path = "b.fs", watched = true },
        { path = "c.fs", watched = false },
      },
      watchedCount = 2,
    })
    local prompt = hrm.format_prompt(state)
    assert.is_string(prompt)
    assert.is_truthy(prompt:find("2"))
    assert.is_truthy(prompt:find("3"))
  end)

  it("returns empty items for empty state", function()
    local state = hrm.new()
    local items = hrm.format_picker_items(state)
    assert.are.equal(0, #items)
  end)
end)

-- ─── Parse picker selection ──────────────────────────────────────────────────

describe("hotreload_model.parse_selection [RED]", function()
  it("identifies watch_all action", function()
    local result = hrm.parse_selection({ action = "watch_all" })
    assert.are.equal("watch_all", result.action)
  end)

  it("identifies unwatch_all action", function()
    local result = hrm.parse_selection({ action = "unwatch_all" })
    assert.are.equal("unwatch_all", result.action)
  end)

  it("identifies toggle action with path", function()
    local result = hrm.parse_selection({ action = "toggle", path = "src/Math.fs" })
    assert.are.equal("toggle", result.action)
    assert.are.equal("src/Math.fs", result.path)
  end)

  it("returns nil for nil selection (user cancelled)", function()
    local result = hrm.parse_selection(nil)
    assert.is_nil(result)
  end)
end)
