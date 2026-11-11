-- sagefs/dashboard/actions.lua — what a dashboard action does
-- Pure Lua, zero vim dependencies
--
-- A section attaches an action table ({ type = ..., ... }) to a line or a key.
-- `resolve` turns it into a plain effect the dashboard shell performs:
--
--   { kind = "call",    fn = <function on the sagefs module>, args = { ... } }
--   { kind = "command", name = <user command> }
--   { kind = "open",    file = <path>, line = <number> }
--   { kind = "notify",  message = <text> }
--
-- An action type nobody handles resolves to nil, and the shell says so. A spec
-- renders every section and requires each action it emits to resolve.

local M = {}

M.KINDS = { call = true, command = true, open = true, notify = true }

local function find_test(testing_state, name)
  local tests = testing_state and testing_state.tests or {}
  for id, t in pairs(tests) do
    if t.displayName == name or t.fullName == name or id == name then
      return t
    end
  end
  return nil
end

local handlers = {
  enable_testing = function() return { kind = "call", fn = "enable_live_testing", args = {} } end,
  disable_testing = function() return { kind = "call", fn = "disable_live_testing", args = {} } end,
  switch_workflow = function() return { kind = "call", fn = "switch_workflow", args = {} } end,
  switch_session = function(a) return { kind = "call", fn = "switch_session", args = { a.session_id } } end,
  run_tests = function() return { kind = "command", name = "SageFsRunTests" } end,
  inspect_binding = function() return { kind = "command", name = "SageFsBindings" } end,
  open_hot_reload = function() return { kind = "command", name = "SageFsHotReload" } end,
  jump_to_test = function(a, ctx)
    local name = a.test_name or ""
    local t = find_test(ctx and ctx.testing_state, name)
    if t and t.file and t.file ~= "" then
      return { kind = "open", file = t.file, line = t.line or 1 }
    end
    return { kind = "notify", message = "No source location is known for test " .. name .. ". Run :SageFsTests to see the discovered tests." }
  end,
}

--- @param action table|nil
--- @param ctx table|nil { testing_state = <plugin testing state> }
--- @return table|nil effect
function M.resolve(action, ctx)
  if type(action) ~= "table" then return nil end
  local h = handlers[action.type]
  if not h then return nil end
  return h(action, ctx)
end

return M
