-- sagefs/type_explorer.lua — Pure type exploration formatting
-- Formats assemblies, namespaces, types, and members for picker/float display
-- Zero vim dependencies

local M = {}

-- ─── Assembly Picker ──────────────────────────────────────────────────────────

function M.format_assemblies(assemblies)
  local items = {}
  for _, asm in ipairs(assemblies) do
    table.insert(items, {
      label = asm.name,
      name = asm.name,
      path = asm.path or "",
    })
  end
  return items
end

-- ─── Namespace Picker ─────────────────────────────────────────────────────────

function M.format_namespaces(namespaces)
  local items = {}
  for _, ns in ipairs(namespaces) do
    table.insert(items, {
      label = ns,
      namespace = ns,
    })
  end
  return items
end

-- ─── Type Picker ──────────────────────────────────────────────────────────────

function M.format_types(types)
  local items = {}
  for _, t in ipairs(types) do
    local kind_icon = ({
      class = "◆",
      struct = "◇",
      interface = "◈",
      enum = "▣",
      union = "▤",
      module = "▥",
    })[t.kind] or "●"
    table.insert(items, {
      label = string.format("%s %s", kind_icon, t.name),
      fullName = t.fullName,
      kind = t.kind,
    })
  end
  return items
end

-- ─── Member Display ───────────────────────────────────────────────────────────

function M.format_members(type_name, members)
  local lines = {}
  table.insert(lines, string.format("── %s ──", type_name))
  table.insert(lines, "")

  local grouped = { constructor = {}, property = {}, method = {}, field = {}, event = {} }
  for _, m in ipairs(members) do
    local kind = m.kind or "method"
    if not grouped[kind] then grouped[kind] = {} end
    table.insert(grouped[kind], m)
  end

  local sections = {
    { key = "constructor", title = "Constructors" },
    { key = "property", title = "Properties" },
    { key = "field", title = "Fields" },
    { key = "method", title = "Methods" },
    { key = "event", title = "Events" },
  }

  for _, section in ipairs(sections) do
    local items = grouped[section.key]
    if items and #items > 0 then
      table.insert(lines, string.format("  %s:", section.title))
      for _, m in ipairs(items) do
        local sig = m.name
        if m.parameters then
          sig = sig .. "(" .. m.parameters .. ")"
        end
        if m.returnType then
          sig = sig .. " : " .. m.returnType
        end
        table.insert(lines, "    " .. sig)
      end
      table.insert(lines, "")
    end
  end

  return lines
end

return M
