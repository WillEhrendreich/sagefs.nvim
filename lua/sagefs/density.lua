--- density.lua — Display density presets for SageFs annotations
--- Controls which annotation layers are visible: signs, codelens, inline failures, branch EOL.
local M = {}

local presets = {
  minimal = { signs = true, codelens = false, inline_failures = false, branch_eol = false },
  normal  = { signs = true, codelens = true,  inline_failures = true,  branch_eol = false },
  full    = { signs = true, codelens = true,  inline_failures = true,  branch_eol = true  },
}

local cycle_order = { "minimal", "normal", "full" }

--- Create a new density state defaulting to "normal".
---@return table
function M.new()
  local p = presets.normal
  return {
    preset = "normal",
    signs = p.signs,
    codelens = p.codelens,
    inline_failures = p.inline_failures,
    branch_eol = p.branch_eol,
  }
end

--- Set density to a named preset. Returns unchanged state for unknown names.
---@param state table
---@param name string
---@return table
function M.set(state, name)
  local p = presets[name]
  if not p then return state end
  return {
    preset = name,
    signs = p.signs,
    codelens = p.codelens,
    inline_failures = p.inline_failures,
    branch_eol = p.branch_eol,
  }
end

--- Cycle to the next preset.
---@param state table
---@return table
function M.cycle(state)
  for i, name in ipairs(cycle_order) do
    if name == state.preset then
      local next_name = cycle_order[(i % #cycle_order) + 1]
      return M.set(state, next_name)
    end
  end
  return M.set(state, "normal")
end

--- Check if a specific layer should render.
---@param state table
---@param layer string one of "signs", "codelens", "inline_failures", "branch_eol"
---@return boolean
function M.should_render(state, layer)
  return state[layer] == true
end

return M
