require("spec.helper")

local function unload_transport()
  package.loaded["sagefs.transport"] = nil
end

describe("transport.connect_sse", function()
  local original_jobstart
  local original_jobstop
  local original_timer_start
  local original_timer_stop
  local original_defer_fn
  local fake
  local transport

  local function emit_stdout(job_id, data)
    fake.jobs[job_id].opts.on_stdout(job_id, data)
  end

  local function exit_job(job_id, code)
    fake.jobs[job_id].opts.on_exit(job_id, code)
  end

  before_each(function()
    unload_transport()

    fake = {
      next_job_id = 41,
      next_timer_id = 700,
      jobs = {},
      jobstops = {},
      timers = {},
      timer_stops = {},
      deferred = {},
    }

    original_jobstart = vim.fn.jobstart
    original_jobstop = vim.fn.jobstop
    original_timer_start = vim.fn.timer_start
    original_timer_stop = vim.fn.timer_stop
    original_defer_fn = vim.defer_fn

    vim.fn.jobstart = function(cmd, opts)
      local job_id = fake.next_job_id
      fake.next_job_id = fake.next_job_id + 1
      fake.jobs[job_id] = { cmd = cmd, opts = opts }
      return job_id
    end

    vim.fn.jobstop = function(job_id)
      table.insert(fake.jobstops, job_id)
      return 1
    end

    vim.fn.timer_start = function(timeout, callback)
      local timer_id = fake.next_timer_id
      fake.next_timer_id = fake.next_timer_id + 1
      fake.timers[timer_id] = { timeout = timeout, callback = callback }
      return timer_id
    end

    vim.fn.timer_stop = function(timer_id)
      table.insert(fake.timer_stops, timer_id)
      fake.timers[timer_id] = nil
    end

    vim.defer_fn = function(fn, delay)
      table.insert(fake.deferred, { fn = fn, delay = delay })
    end

    transport = require("sagefs.transport")
  end)

  after_each(function()
    unload_transport()
    vim.fn.jobstart = original_jobstart
    vim.fn.jobstop = original_jobstop
    vim.fn.timer_start = original_timer_start
    vim.fn.timer_stop = original_timer_stop
    vim.defer_fn = original_defer_fn
  end)

  it("parses SSE events across stdout callbacks and refreshes inactivity timers", function()
    local connects = 0
    local batches = {}
    local handle = transport.connect_sse("http://127.0.0.1:37749/events", {
      on_events = function(events)
        table.insert(batches, events)
      end,
      on_connect = function()
        connects = connects + 1
      end,
      auto_reconnect = false,
      inactivity_timeout = 2,
    })

    handle.start()

    assert.are.same(
      { "curl", "--no-buffer", "-N", "--compressed", "http://127.0.0.1:37749/events", "--silent", "--show-error" },
      fake.jobs[41].cmd
    )
    assert.is_true(handle.active())

    emit_stdout(41, { "event: state", 'data: {"phase"' })

    assert.are.equal(1, connects)
    assert.are.equal(2000, fake.timers[700].timeout)

    emit_stdout(41, { ':1}', "", "" })

    assert.are.same({ 700 }, fake.timer_stops)
    assert.are.equal(2000, fake.timers[701].timeout)
    assert.are.equal(1, #batches)
    assert.are.equal(1, #batches[1])
    assert.are.equal("state", batches[1][1].type)
    assert.are.equal('{"phase":1}', batches[1][1].data)
  end)

  it("reports reconnecting after a connected stream exits", function()
    local disconnects = {}
    local reconnects = {}
    local handle = transport.connect_sse("http://127.0.0.1:37749/events", {
      on_events = function() end,
      on_disconnect = function(code)
        table.insert(disconnects, code)
      end,
      on_reconnecting = function(attempt, status)
        table.insert(reconnects, { attempt = attempt, status = status })
      end,
      auto_reconnect = true,
    })

    handle.start()
    emit_stdout(41, { "event: ping", "", "" })

    exit_job(41, 18)

    assert.are.same({ 700 }, fake.timer_stops)
    assert.are.same({ 18 }, disconnects)
    assert.are.same({ { attempt = 1, status = "reconnecting" } }, reconnects)
    assert.are.equal(1, #fake.deferred)

    fake.deferred[1].fn()

    assert.is_true(handle.active())
    assert.is_not_nil(fake.jobs[42])
  end)

  it("suppresses disconnect callbacks after a manual stop", function()
    local disconnects = 0
    local reconnects = 0
    local handle = transport.connect_sse("http://127.0.0.1:37749/events", {
      on_events = function() end,
      on_disconnect = function()
        disconnects = disconnects + 1
      end,
      on_reconnecting = function()
        reconnects = reconnects + 1
      end,
      auto_reconnect = true,
    })

    handle.start()
    emit_stdout(41, { "event: ping", "", "" })

    handle.stop()
    exit_job(41, 0)

    assert.are.same({ 700 }, fake.timer_stops)
    assert.are.same({ 41 }, fake.jobstops)
    assert.are.equal(0, disconnects)
    assert.are.equal(0, reconnects)
    assert.is_false(handle.active())
  end)
end)

-- A missing curl used to raise out of start() with a raw E475 traceback.
describe("transport.connect_sse when curl cannot be spawned", function()
  local original_jobstart, original_defer_fn, transport, deferred

  before_each(function()
    unload_transport()
    package.loaded["sagefs.spawn"] = nil
    original_jobstart, original_defer_fn = vim.fn.jobstart, vim.defer_fn
    deferred = {}
    vim.defer_fn = function(fn, delay) table.insert(deferred, { fn = fn, delay = delay }) end
    vim.fn.jobstart = function()
      error("Vim:E475: Invalid value for argument cmd: 'curl' is not executable", 0)
    end
    transport = require("sagefs.transport")
  end)

  after_each(function()
    unload_transport()
    package.loaded["sagefs.spawn"] = nil
    vim.fn.jobstart, vim.defer_fn = original_jobstart, original_defer_fn
  end)

  it("does not raise, reports once through on_spawn_error, and does not retry", function()
    local errors = {}
    local handle = transport.connect_sse("http://127.0.0.1:37749/events", {
      on_events = function() end,
      on_spawn_error = function(msg) table.insert(errors, msg) end,
      auto_reconnect = true,
    })
    assert.has_no.errors(function() handle.start() end)
    assert.equals(1, #errors)
    assert.is_truthy(errors[1]:find("curl", 1, true))
    assert.equals(0, #deferred, "a missing binary will not appear by retrying")
    assert.is_false(handle.active())
  end)
end)

-- Neovim hands on_stdout a final {""} when a job's stdout closes. With the
-- daemon down, curl exits at once with nothing written, and that EOF used to be
-- read as the first bytes of a stream: "connected", then "disconnected", about
-- once a second for as long as the daemon stayed down.
describe("transport.connect_sse with nothing listening", function()
  local original_jobstart, original_defer_fn, original_timer_start, original_timer_stop
  local transport, fake

  before_each(function()
    unload_transport()
    fake = { next_job_id = 51, jobs = {}, deferred = {} }
    original_jobstart, original_defer_fn = vim.fn.jobstart, vim.defer_fn
    original_timer_start, original_timer_stop = vim.fn.timer_start, vim.fn.timer_stop
    vim.fn.jobstart = function(cmd, opts)
      local id = fake.next_job_id
      fake.next_job_id = id + 1
      fake.jobs[id] = { cmd = cmd, opts = opts }
      return id
    end
    vim.fn.timer_start = function() return 1 end
    vim.fn.timer_stop = function() end
    vim.defer_fn = function(fn, delay) table.insert(fake.deferred, { fn = fn, delay = delay }) end
    transport = require("sagefs.transport")
  end)

  after_each(function()
    unload_transport()
    vim.fn.jobstart, vim.defer_fn = original_jobstart, original_defer_fn
    vim.fn.timer_start, vim.fn.timer_stop = original_timer_start, original_timer_stop
  end)

  it("does not call a stdout EOF a connection", function()
    local connects, disconnects = 0, 0
    local handle = transport.connect_sse("http://127.0.0.1:37749/events", {
      on_events = function() end,
      on_connect = function() connects = connects + 1 end,
      on_disconnect = function() disconnects = disconnects + 1 end,
      auto_reconnect = true,
    })
    handle.start()
    fake.jobs[51].opts.on_stdout(51, { "" })
    fake.jobs[51].opts.on_exit(51, 7)
    assert.are.equal(0, connects, "no byte arrived, so nothing connected")
    assert.are.equal(0, disconnects, "a connection that never was cannot drop")
  end)

  it("keeps retrying after an EOF with no bytes", function()
    local handle = transport.connect_sse("http://127.0.0.1:37749/events", {
      on_events = function() end,
      auto_reconnect = true,
    })
    handle.start()
    fake.jobs[51].opts.on_stdout(51, { "" })
    fake.jobs[51].opts.on_exit(51, 7)
    assert.are.equal(1, #fake.deferred, "one reconnect is scheduled")
    fake.deferred[1].fn()
    assert.is_not_nil(fake.jobs[52], "the retry started a new curl")
  end)

  it("still calls a real first chunk a connection", function()
    local connects = 0
    local handle = transport.connect_sse("http://127.0.0.1:37749/events", {
      on_events = function() end,
      on_connect = function() connects = connects + 1 end,
      auto_reconnect = true,
    })
    handle.start()
    fake.jobs[51].opts.on_stdout(51, { "retry: 3000", "", "" })
    assert.are.equal(1, connects)
  end)
end)
