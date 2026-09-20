-- spec/hotreload_spec.lua — Tests for sagefs.hotreload's success/failure propagation
--
-- §5.2: hotreload.watch_all/unwatch_all/toggle fired their callback on BOTH
-- the success and failure branch with no `ok` argument, so a caller could
-- not tell a rejected watch-all from a successful one. commands.lua's
-- :SageFsWatchAll/:SageFsUnwatchAll notified "Watching all N files" /
-- "Unwatched all files" unconditionally — a failed request reported success,
-- which is worse than reporting nothing.
require("spec.helper")

local function unload()
  package.loaded["sagefs.hotreload"] = nil
  package.loaded["sagefs.transport"] = nil
end

describe("sagefs.hotreload", function()
  local hotreload
  local http_calls

  before_each(function()
    unload()
    http_calls = {}
    package.loaded["sagefs.transport"] = {
      http_json = function(opts)
        table.insert(http_calls, opts)
      end,
    }
    hotreload = require("sagefs.hotreload")
    hotreload.setup(37750)
  end)

  after_each(function()
    unload()
  end)

  describe("fetch_state", function()
    it("invokes the callback with ok=true on success", function()
      local received
      hotreload.fetch_state("sid1", function(ok) received = ok end)
      http_calls[1].callback(true, vim.json.encode({ files = {} }))
      assert.is_true(received)
    end)

    it("invokes the callback with ok=false on failure", function()
      local received
      hotreload.fetch_state("sid1", function(ok) received = ok end)
      http_calls[1].callback(false, nil)
      assert.is_false(received)
    end)
  end)

  describe("watch_all", function()
    it("succeeds: POSTs /watch-all then refetches state, callback(true)", function()
      local received = "unset"
      hotreload.watch_all("sid1", function(ok) received = ok end)

      assert.equals(1, #http_calls)
      assert.is_truthy(http_calls[1].url:find("/watch%-all"))
      http_calls[1].callback(true, "")

      -- the refetch (fetch_state) is the second HTTP call
      assert.equals(2, #http_calls)
      http_calls[2].callback(true, vim.json.encode({ files = {} }))

      assert.is_true(received)
    end)

    it("fails: does NOT refetch, callback(false) — never silently succeeds", function()
      local received = "unset"
      hotreload.watch_all("sid1", function(ok) received = ok end)

      assert.equals(1, #http_calls)
      http_calls[1].callback(false, nil)

      -- must NOT have triggered a refetch on failure
      assert.equals(1, #http_calls)
      assert.is_false(received, "a failed watch-all must report ok=false, never true")
    end)
  end)

  describe("unwatch_all", function()
    it("fails: callback(false), no refetch", function()
      local received = "unset"
      hotreload.unwatch_all("sid1", function(ok) received = ok end)
      http_calls[1].callback(false, nil)
      assert.equals(1, #http_calls)
      assert.is_false(received, "a failed unwatch-all must report ok=false, never true")
    end)
  end)

  describe("toggle", function()
    it("fails: callback(false), no refetch", function()
      local received = "unset"
      hotreload.toggle("sid1", "Foo.fs", function(ok) received = ok end)
      http_calls[1].callback(false, nil)
      assert.equals(1, #http_calls)
      assert.is_false(received, "a failed toggle must report ok=false, never true")
    end)
  end)
end)
