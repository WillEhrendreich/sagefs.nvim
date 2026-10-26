-- sagefs/type_explorer_cache.lua — In-memory cache for type explorer listings
-- Pure Lua, zero vim dependencies. Caches qualified name → listing (the
-- completions plus the size the daemon stated, from completions.listing_of), so a
-- cached name still says "Showing 200 of at least 2000".
-- Clear on hard reset.

local M = {}

local store = {}

--- Get the cached listing for a qualified name.
---@param name string
---@return table|nil
function M.get(name)
  return store[name]
end

--- Cache a listing for a qualified name.
---@param name string
---@param listing table
function M.set(name, listing)
  store[name] = listing
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
