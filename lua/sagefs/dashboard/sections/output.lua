-- sagefs/dashboard/sections/output.lua — Eval output section
-- Pure Lua, zero vim dependencies

local M = {}

M.id = "output"
M.label = "Output"
M.events = { "eval_result", "eval_completed", "eval_heartbeat" }

--- Format the running eval's elapsed milliseconds (from eval_heartbeat).
local function elapsed_label(ms)
  if type(ms) ~= "number" then return "?" end
  if ms >= 1000 then return string.format("%.1fs", ms / 1000) end
  return string.format("%dms", ms)
end

--- Render the eval output section from dashboard state.
--- @param state table
--- @return table SectionOutput
function M.render(state)
  local lines = {}
  local highlights = {}
  local e = state.eval or {}

  table.insert(lines, "═══ Output ═══")
  table.insert(highlights, {
    line = 0, col_start = 0, col_end = #lines[1], hl_group = "SageFsSectionHeader",
  })

  -- While the daemon is still sending eval_heartbeat the eval is running:
  -- show its elapsed time. eval_result clears the heartbeat, so this line
  -- disappears when the eval finishes and the meta duration below is the
  -- completed eval's, not the last heartbeat's.
  if e.heartbeat then
    table.insert(lines, "Evaluating… " .. elapsed_label(e.heartbeat.elapsed_ms))
    table.insert(highlights, {
      line = #lines - 1, col_start = 0, col_end = #lines[#lines],
      hl_group = "SageFsEvalDuration",
    })
  end

  if not e.output then
    if not e.heartbeat then
      table.insert(lines, "(no eval output)")
    end
    return { section_id = M.id, lines = lines, highlights = highlights, keymaps = {} }
  end

  -- Metadata line
  local meta_parts = {}
  if e.cell_id then
    table.insert(meta_parts, string.format("Cell %d", e.cell_id))
  end
  if e.duration_ms then
    table.insert(meta_parts, string.format("%dms", e.duration_ms))
  end
  if #meta_parts > 0 then
    table.insert(lines, table.concat(meta_parts, " · "))
    table.insert(highlights, {
      line = #lines - 1, col_start = 0, col_end = #lines[#lines], hl_group = "SageFsEvalMeta",
    })
  end

  -- Split output into lines
  for output_line in e.output:gmatch("[^\n]+") do
    table.insert(lines, output_line)
  end

  return { section_id = M.id, lines = lines, highlights = highlights, keymaps = {} }
end

return M
