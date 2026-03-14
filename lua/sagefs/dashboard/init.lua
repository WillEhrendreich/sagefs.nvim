-- sagefs/dashboard/init.lua — Dashboard panel window manager + integration
--
-- Architecture:
--   SSE events → state.update (pure fold) → dirty sections (event_index O(1) lookup)
--     → render only dirty (cached outputs for clean sections) → compositor (monoid)
--     → buf_set_lines + highlights
--
-- Pure core: section, state, compositor, event_index, statusline, sections/*
-- Impure shell: this file (vim buffer/window management, autocmds, keymaps)

local section_mod = require("sagefs.dashboard.section")
local state_mod = require("sagefs.dashboard.state")
local compositor = require("sagefs.dashboard.compositor")
local event_index_mod = require("sagefs.dashboard.event_index")

local M = {}

-- ─── Statusline (public, pure — safe to require without opening dashboard) ──

M.statusline = require("sagefs.dashboard.statusline")

-- ─── Available sections (register on load) ───────────────────────────────────

local section_modules = {
  require("sagefs.dashboard.sections.health"),
  require("sagefs.dashboard.sections.tests"),
  require("sagefs.dashboard.sections.diagnostics"),
  require("sagefs.dashboard.sections.failures"),
  require("sagefs.dashboard.sections.session"),
  require("sagefs.dashboard.sections.hot_reload"),
  require("sagefs.dashboard.sections.output"),
  require("sagefs.dashboard.sections.bindings"),
  require("sagefs.dashboard.sections.coverage"),
  require("sagefs.dashboard.sections.filmstrip"),
  require("sagefs.dashboard.sections.alarms"),
  require("sagefs.dashboard.sections.help"),
}

for _, s in ipairs(section_modules) do
  section_mod.register(s)
end

-- Build the event→section reverse index once (O(1) lookups thereafter)
local _event_idx = event_index_mod.build(section_mod.all())

-- ─── Internal State ──────────────────────────────────────────────────────────

M._bufnr = nil
M._winnr = nil
M._state = nil
M._last_composed = nil
M._ns_id = nil
M._augroup = nil
M._section_cache = {}   -- section_id → last SectionOutput (dirty tracking)
M._render_scheduled = false -- coalescing flag for vim.schedule

-- ─── Config ──────────────────────────────────────────────────────────────────

M.config = {
  position = "botright",
  height = 20,
  separator = "─────────────────────────────",
  default_sections = { "health", "session", "tests", "diagnostics", "failures" },
  persist_sections = true, -- save visible sections to vim.g
}

-- ─── Public API ──────────────────────────────────────────────────────────────

--- Check if the dashboard is currently open.
function M.is_open()
  return M._winnr ~= nil
    and vim.api.nvim_win_is_valid(M._winnr)
end

--- Open the dashboard panel.
function M.open()
  if M.is_open() then
    vim.api.nvim_set_current_win(M._winnr)
    return
  end

  -- Setup theme-aware highlight groups
  local ok_hl, highlights = pcall(require, "sagefs.dashboard.highlights")
  if ok_hl then highlights.setup() end

  -- Initialize state if first open
  if not M._state then
    M._state = state_mod.new()
    -- Restore persisted section visibility (or use defaults)
    local persisted = M.config.persist_sections and vim.g.sagefs_dashboard_sections
    if persisted and type(persisted) == "table" and #persisted > 0 then
      M._state.visible_sections = vim.deepcopy(persisted)
    else
      M._state.visible_sections = vim.deepcopy(M.config.default_sections)
    end
  end

  -- Clear section cache on fresh open
  M._section_cache = {}

  -- Create namespace for highlights
  M._ns_id = M._ns_id or vim.api.nvim_create_namespace("sagefs_dashboard")

  -- Create buffer
  M._bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(M._bufnr, "sagefs://dashboard")
  vim.bo[M._bufnr].buftype = "nofile"
  vim.bo[M._bufnr].bufhidden = "wipe"
  vim.bo[M._bufnr].swapfile = false
  vim.bo[M._bufnr].modifiable = false
  vim.bo[M._bufnr].filetype = "sagefs-dashboard"

  -- Create split window
  vim.cmd(M.config.position .. " " .. M.config.height .. "split")
  M._winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M._winnr, M._bufnr)
  vim.wo[M._winnr].winfixheight = true
  vim.wo[M._winnr].number = false
  vim.wo[M._winnr].relativenumber = false
  vim.wo[M._winnr].signcolumn = "no"
  vim.wo[M._winnr].foldcolumn = "0"
  vim.wo[M._winnr].wrap = false

  -- Set buffer-local keymaps
  M._setup_keymaps()

  -- Wire autocmds
  M._setup_autocmds()

  -- Initial render
  M.render()
end

--- Close the dashboard panel.
function M.close()
  if M._augroup then
    vim.api.nvim_del_augroup_by_id(M._augroup)
    M._augroup = nil
  end
  if M._winnr and vim.api.nvim_win_is_valid(M._winnr) then
    vim.api.nvim_win_close(M._winnr, true)
  end
  M._winnr = nil
  M._bufnr = nil
end

--- Toggle the dashboard panel open/closed.
function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

--- Update state from an SSE event and re-render dirty sections only.
--- Uses event_index for O(1) lookup of which sections care about this event.
--- @param event_type string
--- @param payload table|nil
function M.on_event(event_type, payload)
  if not M._state then return end
  M._state = state_mod.update(M._state, event_type, payload)
  if not M.is_open() then return end

  -- O(1) lookup: which sections need re-rendering?
  local dirty_ids = event_index_mod.to_set(event_index_mod.lookup(_event_idx, event_type))

  -- Coalesce rapid events into a single vim.schedule pass
  if not M._render_scheduled then
    M._render_scheduled = true
    -- Merge dirty set into pending dirty set
    M._pending_dirty = M._pending_dirty or {}
    for id, _ in pairs(dirty_ids) do M._pending_dirty[id] = true end

    vim.schedule(function()
      M._render_scheduled = false
      local dirty = M._pending_dirty
      M._pending_dirty = nil
      M.render(dirty)
    end)
  else
    -- Already scheduled — just expand the dirty set
    M._pending_dirty = M._pending_dirty or {}
    for id, _ in pairs(dirty_ids) do M._pending_dirty[id] = true end
  end
end

--- Render the dashboard. With dirty_set, only re-render those sections (cache rest).
--- Without dirty_set (nil), re-render all visible sections (full refresh).
--- @param dirty_set table<string,true>|nil
function M.render(dirty_set)
  if not M.is_open() then return end
  if not M._bufnr or not vim.api.nvim_buf_is_valid(M._bufnr) then return end

  -- Collect visible section outputs (cached or fresh)
  local outputs = {}
  local visible_ids = M._state.visible_sections or M.config.default_sections
  local sections = section_mod.ordered(visible_ids)

  for _, s in ipairs(sections) do
    local use_cache = dirty_set
      and not dirty_set[s.id]
      and M._section_cache[s.id]

    if use_cache then
      table.insert(outputs, M._section_cache[s.id])
    else
      local ok, output = pcall(s.render, M._state)
      if ok and output then
        M._section_cache[s.id] = output
        table.insert(outputs, output)
      end
    end
  end

  -- Compose (monoid fold)
  local composed = compositor.compose(outputs, { separator = M.config.separator })
  M._last_composed = composed

  -- Write to buffer
  vim.bo[M._bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M._bufnr, 0, -1, false, composed.lines)
  vim.bo[M._bufnr].modifiable = false

  -- Apply highlights (clear + re-apply is simpler and correct)
  vim.api.nvim_buf_clear_namespace(M._bufnr, M._ns_id, 0, -1)
  for _, hl in ipairs(composed.highlights) do
    pcall(vim.api.nvim_buf_add_highlight,
      M._bufnr, M._ns_id, hl.hl_group, hl.line, hl.col_start, hl.col_end)
  end
end

--- Toggle visibility of a specific section.
--- @param section_id string
function M.toggle_section(section_id)
  if not M._state then return end
  state_mod.toggle_section(M._state, section_id)

  -- Persist visible sections if configured
  if M.config.persist_sections then
    vim.g.sagefs_dashboard_sections = vim.deepcopy(M._state.visible_sections)
  end

  -- Invalidate cache for toggled section
  M._section_cache[section_id] = nil
  M.render()
end

--- Get current state (for testing/inspection).
function M.get_state()
  return M._state
end

--- Set state directly (for testing).
function M.set_state(new_state)
  M._state = new_state
end

-- ─── Internal: Keymaps ───────────────────────────────────────────────────────

function M._setup_keymaps()
  local buf = M._bufnr
  local opts = { noremap = true, silent = true, buffer = buf }

  -- q: close dashboard
  vim.keymap.set("n", "q", function() M.close() end, opts)

  -- Tab: cycle focus to next section
  vim.keymap.set("n", "<Tab>", function() M._cycle_section(1) end, opts)
  vim.keymap.set("n", "<S-Tab>", function() M._cycle_section(-1) end, opts)

  -- 1-9: toggle section visibility by position
  for i = 1, 9 do
    vim.keymap.set("n", tostring(i), function()
      local all = section_mod.all()
      if all[i] then M.toggle_section(all[i].id) end
    end, opts)
  end

  -- Section-specific keys
  vim.keymap.set("n", "e", function() M._dispatch_action({ type = "enable_testing" }) end, opts)
  vim.keymap.set("n", "d", function() M._dispatch_action({ type = "disable_testing" }) end, opts)
  vim.keymap.set("n", "h", function() M._dispatch_action({ type = "toggle_hot_reload" }) end, opts)
  vim.keymap.set("n", "r", function() M._dispatch_action({ type = "run_tests" }) end, opts)
  vim.keymap.set("n", "R", function() M.render() end, opts)

  -- CR: context action at cursor
  vim.keymap.set("n", "<CR>", function() M._action_at_cursor() end, opts)

  -- ?: toggle inline help section (not vim.notify — help is a section like any other)
  vim.keymap.set("n", "?", function() M.toggle_section("help") end, opts)
end

-- ─── Internal: Autocmds ──────────────────────────────────────────────────────

function M._setup_autocmds()
  M._augroup = vim.api.nvim_create_augroup("SageFsDashboard", { clear = true })

  -- Listen for SSE events via User autocmds
  vim.api.nvim_create_autocmd("User", {
    group = M._augroup,
    pattern = "SageFs*",
    callback = function(args)
      -- Extract event type from pattern (strip "SageFs" prefix, convert to snake_case)
      local pattern = args.match or ""
      local event_type = M._autocmd_to_event(pattern)
      local data = args.data
      if type(data) == "string" then
        local ok, payload = pcall(vim.json.decode, data)
        if ok then
          M.on_event(event_type, payload)
        end
      elseif type(data) == "table" then
        M.on_event(event_type, data)
      end
    end,
  })

  -- Clean up on buffer wipe
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = M._augroup,
    buffer = M._bufnr,
    callback = function()
      M._winnr = nil
      M._bufnr = nil
    end,
  })
end

-- ─── Internal: Helpers ───────────────────────────────────────────────────────

--- Convert autocmd pattern like "SageFsTestSummary" to event name "test_summary"
function M._autocmd_to_event(pattern)
  -- Strip "SageFs" prefix
  local name = pattern:gsub("^SageFs", "")
  -- CamelCase to snake_case
  local result = name:gsub("(%u)", function(c) return "_" .. c:lower() end)
  -- Remove leading underscore
  result = result:gsub("^_", "")
  return result
end

function M._cycle_section(direction)
  if not M._last_composed or #M._last_composed.section_ranges == 0 then return end

  local cursor = vim.api.nvim_win_get_cursor(M._winnr)
  local cur_line = cursor[1] - 1

  local ranges = M._last_composed.section_ranges
  local cur_idx = nil
  for i, r in ipairs(ranges) do
    if cur_line >= r.start_line and cur_line <= r.end_line then
      cur_idx = i
      break
    end
  end

  local next_idx
  if cur_idx then
    next_idx = cur_idx + direction
    if next_idx < 1 then next_idx = #ranges end
    if next_idx > #ranges then next_idx = 1 end
  else
    next_idx = direction > 0 and 1 or #ranges
  end

  local target = ranges[next_idx]
  if target then
    vim.api.nvim_win_set_cursor(M._winnr, { target.start_line + 1, 0 })
  end
end

function M._action_at_cursor()
  if not M._last_composed then return end

  local cursor = vim.api.nvim_win_get_cursor(M._winnr)
  local cur_line = cursor[1] - 1

  for _, km in ipairs(M._last_composed.keymaps) do
    if km.line == cur_line and km.key == "<CR>" then
      M._dispatch_action(km.action)
      return
    end
  end
end

function M._dispatch_action(action)
  if not action then return end

  local sagefs = require("sagefs")

  if action.type == "enable_testing" then
    if sagefs.enable_live_testing then sagefs.enable_live_testing() end
  elseif action.type == "disable_testing" then
    if sagefs.disable_live_testing then sagefs.disable_live_testing() end
  elseif action.type == "run_tests" then
    if sagefs.run_tests then sagefs.run_tests() end
  elseif action.type == "toggle_hot_reload" then
    if sagefs.toggle_hot_reload then sagefs.toggle_hot_reload() end
  elseif action.type == "switch_session" then
    if sagefs.switch_session then sagefs.switch_session(action.session_id) end
  elseif action.type == "jump_to_test" then
    if sagefs.jump_to_test then sagefs.jump_to_test(action.test_name) end
  elseif action.type == "inspect_binding" then
    if sagefs.inspect_binding then sagefs.inspect_binding(action.name) end
  elseif action.type == "jump_to_eval" then
    if sagefs.jump_to_eval then sagefs.jump_to_eval(action.index) end
  end
end

-- ─── Setup (called from plugin init) ─────────────────────────────────────────

function M.setup(user_config)
  if user_config then
    for k, v in pairs(user_config) do
      M.config[k] = v
    end
  end

  -- Register user command
  vim.api.nvim_create_user_command("SageFsDashboard", function()
    M.toggle()
  end, { desc = "Toggle SageFs dashboard panel" })
end

return M
