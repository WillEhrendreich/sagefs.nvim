-- sagefs/dashboard/section.lua — Section protocol definition and registry
-- Pure Lua, zero vim dependencies, fully testable with busted
--
-- A Section is the fundamental unit of the dashboard:
--   { id: string, label: string, events: table, render: fn(state) -> SectionOutput }
--
-- SectionOutput = { lines: string[], highlights: Highlight[], keymaps: Keymap[] }
-- Highlight = { line: int, col_start: int, col_end: int, hl_group: string }
-- Keymap = { line: int, key: string, action: { type: string, ... } }

local M = {}

-- ─── Validation ──────────────────────────────────────────────────────────────

--- Validate that a table conforms to the Section protocol.
--- @param tbl table
--- @return boolean
function M.validate(tbl)
  if type(tbl) ~= "table" then return false end
  if type(tbl.id) ~= "string" or tbl.id == "" then return false end
  if type(tbl.label) ~= "string" then return false end
  if type(tbl.events) ~= "table" then return false end
  if type(tbl.render) ~= "function" then return false end
  return true
end

-- ─── Registry ────────────────────────────────────────────────────────────────

local registry = {}

--- Register a section. Validates before accepting.
--- @param section table Section conforming to protocol
--- @return boolean success
function M.register(section)
  if not M.validate(section) then return false end
  registry[section.id] = section
  return true
end

--- Get a registered section by id.
--- @param id string
--- @return table|nil
function M.get(id)
  return registry[id]
end

--- Get all registered sections as a list, preserving insertion order.
--- @return table[]
function M.all()
  local result = {}
  for _, s in pairs(registry) do
    table.insert(result, s)
  end
  -- Sort by id for deterministic order
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end

--- Get ordered sections matching a list of ids.
--- Skips ids that aren't registered.
--- @param ids string[]
--- @return table[]
function M.ordered(ids)
  local result = {}
  for _, id in ipairs(ids) do
    local s = registry[id]
    if s then table.insert(result, s) end
  end
  return result
end

--- Clear all registered sections (for testing).
function M.clear()
  registry = {}
end

-- ─── Empty SectionOutput (monoid identity) ───────────────────────────────────

function M.empty_output(section_id)
  return {
    section_id = section_id or "",
    lines = {},
    highlights = {},
    keymaps = {},
  }
end

return M
