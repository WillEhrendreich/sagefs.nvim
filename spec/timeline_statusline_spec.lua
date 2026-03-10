-- =============================================================================
-- Tests — timeline.format_statusline and timeline_stats state storage
-- =============================================================================
-- The eval_timeline SSE event now stores server-computed stats in M.timeline_stats
-- and the statusline component renders them via timeline.format_statusline.
-- =============================================================================

require("spec.helper")
local timeline = require("sagefs.timeline")

-- ─── timeline.format_statusline ──────────────────────────────────────────────

describe("timeline.format_statusline", function()
  it("returns empty string when stats is nil", function()
    assert.are.equal("", timeline.format_statusline(nil))
  end)

  it("returns empty string when count is 0", function()
    local stats = { count = 0, sparkline = "", p50Ms = nil }
    assert.are.equal("", timeline.format_statusline(stats))
  end)

  it("renders sparkline with p50 when data present", function()
    local stats = { count = 5, sparkline = "▁▂▃▅▆", p50Ms = 42 }
    local result = timeline.format_statusline(stats)
    assert.truthy(result:find("▁▂▃▅▆"), "should contain sparkline chars")
    assert.truthy(result:find("42ms"), "should contain p50 latency")
    assert.truthy(result:find("⚡"), "should contain performance icon")
  end)

  it("renders without p50 when p50Ms is nil", function()
    local stats = { count = 3, sparkline = "▁▂▃", p50Ms = nil }
    local result = timeline.format_statusline(stats)
    assert.truthy(result:find("▁▂▃"), "should contain sparkline")
    assert.falsy(result:find("ms"), "should not contain ms when no p50")
  end)

  it("formats p50 as integer milliseconds", function()
    local stats = { count = 1, sparkline = "▆", p50Ms = 123.7 }
    local result = timeline.format_statusline(stats)
    assert.truthy(result:find("124ms") or result:find("123ms"),
      "should round p50 to integer ms: " .. result)
  end)

  it("handles missing sparkline field gracefully", function()
    local stats = { count = 2, p50Ms = 55 }
    local result = timeline.format_statusline(stats)
    assert.are.same("string", type(result))
  end)
end)

-- ─── round-trip: SSE payload → format_statusline ─────────────────────────────

describe("eval_timeline stats table to statusline", function()
  it("produces non-empty statusline from server stats shape", function()
    -- Simulate what the custom handler stores in M.timeline_stats
    local stats = {
      count = 10,
      sparkline = "▁▂▃▅▆▆▃▂▁▆",
      p50Ms = 88,
      p95Ms = 250,
      p99Ms = 420,
      meanMs = 110,
    }
    local result = timeline.format_statusline(stats)
    assert.truthy(#result > 0, "statusline should be non-empty for live data")
    assert.truthy(result:find("88ms"), "should show p50: " .. result)
  end)

  it("produces empty statusline for zero-count stats", function()
    local stats = { count = 0, sparkline = "", p50Ms = nil, p95Ms = nil }
    assert.are.equal("", timeline.format_statusline(stats))
  end)
end)
