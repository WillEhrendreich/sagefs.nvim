-- sagefs/type_explorer_cache.lua — In-memory cache for type explorer completions
-- Pure Lua, zero vim dependencies. Caches qualified name → completions.
-- Clear on hard reset.

local M = {}

local store = {}

--- Get cached completions for a qualified name.
---@param name string
---@return table[]|nil
function M.get(name)
  return store[name]
end

--- Cache completions for a qualified name.
---@param name string
---@param completions table[]
function M.set(name, completions)
  store[name] = completions
end

function M.has_data()
  return next(store) ~= nil
end

function M.stats()
  local count = 0
  for _ in pairs(store) do count = count + 1 end
  return { cached_names = count }
end

function M.clear()
  store = {}
end

return M
