-- sagefs/type_explorer_cache.lua — In-memory cache for type explorer data
-- Pure Lua, zero vim dependencies. Caches assembly → namespace → type → member
-- hierarchy to avoid repeated HTTP calls. Clear on hard reset.

local M = {}

local store = {
  assemblies = nil,
  namespaces = {},  -- keyed by assembly name
  types = {},       -- keyed by namespace
  members = {},     -- keyed by type fullName
  flat_types = nil, -- flat list of all types
}

function M.get_assemblies()
  return store.assemblies
end

function M.set_assemblies(asms)
  store.assemblies = asms
end

function M.get_namespaces(assembly)
  return store.namespaces[assembly]
end

function M.set_namespaces(assembly, ns)
  store.namespaces[assembly] = ns
end

function M.get_types(namespace)
  return store.types[namespace]
end

function M.set_types(namespace, types)
  store.types[namespace] = types
end

function M.get_members(type_name)
  return store.members[type_name]
end

function M.set_members(type_name, members)
  store.members[type_name] = members
end

function M.get_flat_types()
  return store.flat_types
end

function M.set_flat_types(flat)
  store.flat_types = flat
end

function M.has_data()
  return store.assemblies ~= nil
end

function M.stats()
  local ns_count = 0
  for _ in pairs(store.namespaces) do ns_count = ns_count + 1 end
  local type_count = 0
  for _ in pairs(store.types) do type_count = type_count + 1 end
  local member_count = 0
  for _ in pairs(store.members) do member_count = member_count + 1 end
  return {
    assemblies = store.assemblies and #store.assemblies or 0,
    namespaces = ns_count,
    types = type_count,
    members = member_count,
    has_flat = store.flat_types ~= nil,
  }
end

function M.clear()
  store.assemblies = nil
  store.namespaces = {}
  store.types = {}
  store.members = {}
  store.flat_types = nil
end

return M
