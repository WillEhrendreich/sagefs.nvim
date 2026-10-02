-- sagefs/closed_set.lua — closed sets of named wire tokens
-- Pure Lua, zero vim dependencies
--
-- The daemon names its states with closed sets (ReloadCase, PatchMechanism,
-- ReplFreshness, ...). Each is spelled once on this side, as a table of
-- constants with a membership test, so display code branches on a name and a
-- token the daemon adds later is visible as "not in the set" instead of being
-- silently treated as one of the old ones.

local M = {}

--- Define a closed set.
--- `entries` is an ordered list. An entry is either "Name" (the wire token is the
--- name) or { "Name", "token" } (the wire token differs; "" is allowed).
---@param name string
---@param entries (string|string[])[]
---@return table set  constants by name, plus name, all, has, name_of
function M.define(name, entries)
  local set = { name = name, all = {} }
  local by_token = {}
  local names = {}
  for _, entry in ipairs(entries) do
    local entry_name, token
    if type(entry) == "table" then
      entry_name, token = entry[1], entry[2]
    else
      entry_name, token = entry, entry
    end
    if names[entry_name] then
      error(string.format("closed_set %s: duplicate name %s", name, entry_name))
    end
    if by_token[token] then
      error(string.format("closed_set %s: duplicate token %q", name, token))
    end
    names[entry_name] = true
    by_token[token] = entry_name
    set[entry_name] = token
    table.insert(set.all, token)
  end

  function set.has(token)
    return type(token) == "string" and by_token[token] ~= nil
  end

  function set.name_of(token)
    if type(token) ~= "string" then return nil end
    return by_token[token]
  end

  return set
end

return M
