-- sagefs/daemon.lua — Pure state machine for SageFs daemon lifecycle
-- No vim APIs — fully testable under busted.
local M = {}

function M.new()
  return {
    status = "idle",
    job_id = nil,
    project = nil,
    port = nil,
    error = nil,
  }
end

function M.start_command(opts)
  local cmd = { "sagefs", "--supervised" }
  if opts.project then
    table.insert(cmd, "--proj")
    table.insert(cmd, opts.project)
  end
  if opts.port then
    table.insert(cmd, "--port")
    table.insert(cmd, tostring(opts.port))
  end
  return cmd
end

function M.mark_starting(state, project, port)
  state.status = "starting"
  state.project = project
  state.port = port
  state.error = nil
  return state
end

function M.mark_running(state, job_id)
  state.status = "running"
  state.job_id = job_id
  return state
end

function M.mark_stopped(state)
  state.status = "idle"
  state.job_id = nil
  state.error = nil
  return state
end

function M.mark_failed(state, reason)
  state.status = "failed"
  state.job_id = nil
  state.error = reason
  return state
end

function M.is_running(state)
  return state.status == "running"
end

function M.format_statusline(state)
  if state.status == "running" then
    local name = state.project and state.project:match("([^/\\]+)$") or "?"
    return string.format("🚀 %s", name)
  elseif state.status == "starting" then
    return "⏳ starting"
  elseif state.status == "failed" then
    return string.format("❌ %s", state.error or "failed")
  end
  return "💤 idle"
end

return M
