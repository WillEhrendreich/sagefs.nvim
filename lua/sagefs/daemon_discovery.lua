-- sagefs/daemon_discovery.lua — Shared daemon discovery helpers
-- Pure Lua so discovery rules stay testable outside Neovim.

local M = {}
local util = require("sagefs.util")

local HEALTH_ENDPOINTS = { "/health", "/version" }

function M.health_endpoints()
  local endpoints = {}

  for i, path in ipairs(HEALTH_ENDPOINTS) do
    endpoints[i] = path
  end

  return endpoints
end

function M.is_reachable_http_code(code)
  return code == "200" or code == "204"
end

function M.interpret_payload(endpoint, raw)
  local ok_parse, parsed = util.json_decode(raw)
  if not ok_parse or type(parsed) ~= "table" then
    return {
      accepted = false,
      fallback = endpoint == "/health",
      kind = "invalid",
      parsed = nil,
    }
  end

  if endpoint == "/health" then
    local has_health_contract =
      parsed.healthy ~= nil
      or parsed.status ~= nil
      or parsed.error ~= nil
      or parsed.features ~= nil

    if not has_health_contract then
      return {
        accepted = false,
        fallback = true,
        kind = "invalid",
        parsed = parsed,
      }
    end

    if parsed.apiVersion == nil then
      return {
        accepted = false,
        fallback = true,
        kind = "health_incomplete",
        parsed = parsed,
      }
    end

    return {
      accepted = true,
      fallback = false,
      kind = parsed.status == "no session" and "reachable" or "connected",
      parsed = parsed,
    }
  end

  if endpoint == "/version" then
    local has_version_contract =
      parsed.apiVersion ~= nil
      or parsed.version ~= nil
      or parsed.server ~= nil
      or parsed.mcp ~= nil
      or parsed.sse ~= nil

    return {
      accepted = has_version_contract,
      fallback = false,
      kind = has_version_contract and "version" or "invalid",
      parsed = parsed,
    }
  end

  return {
    accepted = false,
    fallback = false,
    kind = "invalid",
    parsed = parsed,
  }
end

function M.probe_endpoints(request, on_complete, endpoints)
  local probe_paths = endpoints or HEALTH_ENDPOINTS
  local index = 1

  local function try_next()
    local path = probe_paths[index]

    if not path then
      on_complete(false, nil, nil)
      return
    end

    request(path, function(ok, raw)
      if ok then
        on_complete(true, raw, path)
      else
        index = index + 1
        try_next()
      end
    end)
  end

  try_next()
end

function M.probe_contract(request, on_complete, endpoints)
  local last_probe = nil

  M.probe_endpoints(function(path, done)
    request(path, function(ok, response)
      local probe = {}

      if type(response) == "table" then
        for key, value in pairs(response) do
          probe[key] = value
        end
      else
        probe.raw = response
      end

      probe.endpoint = path
      probe.raw = probe.raw or ""

      if not ok then
        last_probe = probe
        done(false, probe)
        return
      end

      local interpreted = M.interpret_payload(path, probe.raw)
      probe.kind = interpreted.kind
      probe.parsed = interpreted.parsed
      last_probe = probe

      done(interpreted.accepted, probe)
    end)
  end, function(ok, probe, endpoint)
    local final_probe = probe or last_probe
    local final_endpoint = endpoint or (final_probe and final_probe.endpoint) or nil
    on_complete(ok, final_probe, final_endpoint)
  end, endpoints)
end

return M
