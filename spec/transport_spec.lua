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
