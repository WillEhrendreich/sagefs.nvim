require("spec.helper")

local discovery = require("sagefs.daemon_discovery")

describe("sagefs.daemon_discovery", function()
  describe("health_endpoints", function()
    it("returns health before version", function()
      assert.are.same({ "/health", "/version" }, discovery.health_endpoints())
    end)
  end)

  describe("is_reachable_http_code", function()
    it("treats 200 and 204 as reachable", function()
      assert.is_true(discovery.is_reachable_http_code("200"))
      assert.is_true(discovery.is_reachable_http_code("204"))
    end)

    it("treats other status codes as unreachable", function()
      assert.is_false(discovery.is_reachable_http_code("404"))
      assert.is_false(discovery.is_reachable_http_code(nil))
    end)
  end)

  describe("probe_endpoints", function()
    it("stops after /health succeeds", function()
      local calls = {}
      local result = nil

      discovery.probe_endpoints(function(path, done)
        table.insert(calls, path)
        done(true, "healthy")
      end, function(ok, raw, endpoint)
        result = { ok = ok, raw = raw, endpoint = endpoint }
      end)

      assert.are.same({ "/health" }, calls)
      assert.are.same({ ok = true, raw = "healthy", endpoint = "/health" }, result)
    end)

    it("falls back to /version when /health fails", function()
      local calls = {}
      local result = nil

      discovery.probe_endpoints(function(path, done)
        table.insert(calls, path)

        if path == "/health" then
          done(false, "timeout")
          return
        end

        done(true, '{"apiVersion":7}')
      end, function(ok, raw, endpoint)
        result = { ok = ok, raw = raw, endpoint = endpoint }
      end)

      assert.are.same({ "/health", "/version" }, calls)
      assert.are.same({ ok = true, raw = '{"apiVersion":7}', endpoint = "/version" }, result)
    end)

    it("reports failure after both endpoints fail", function()
      local calls = {}
      local result = nil

      discovery.probe_endpoints(function(path, done)
        table.insert(calls, path)
        done(false, "connect failed")
      end, function(ok, raw, endpoint)
        result = { ok = ok, raw = raw, endpoint = endpoint }
      end)

      assert.are.same({ "/health", "/version" }, calls)
      assert.are.same({ ok = false, raw = nil, endpoint = nil }, result)
    end)
  end)

  describe("interpret_payload", function()
    it("accepts complete /health payloads", function()
      local result = discovery.interpret_payload("/health", [[{"healthy":true,"status":"Ready","apiVersion":7,"features":["live-testing"]}]])

      assert.is_true(result.accepted)
      assert.is_false(result.fallback)
      assert.are.same("connected", result.kind)
      assert.are.same(7, result.parsed.apiVersion)
    end)

    it("falls back when /health omits apiVersion", function()
      local result = discovery.interpret_payload("/health", [[{"healthy":false,"status":"no session","features":[]}]])

      assert.is_false(result.accepted)
      assert.is_true(result.fallback)
      assert.are.same("health_incomplete", result.kind)
      assert.are.same("no session", result.parsed.status)
    end)

    it("classifies complete no-session /health payloads as reachable", function()
      local result = discovery.interpret_payload("/health", [[{"healthy":false,"status":"no session","apiVersion":7,"features":[]}]])

      assert.is_true(result.accepted)
      assert.is_false(result.fallback)
      assert.are.same("reachable", result.kind)
      assert.are.same(7, result.parsed.apiVersion)
    end)
  end)

  describe("probe_contract", function()
    it("falls back to /version when /health is incomplete", function()
      local calls = {}
      local result = nil

      discovery.probe_contract(function(path, done)
        table.insert(calls, path)

        if path == "/health" then
          done(true, {
            raw = [[{"healthy":false,"status":"no session","features":[]}]],
            code = "200",
          })
          return
        end

        done(true, {
          raw = [[{"version":"1.2.3","apiVersion":7,"server":"sagefs"}]],
          code = "200",
        })
      end, function(ok, probe, endpoint)
        result = { ok = ok, probe = probe, endpoint = endpoint }
      end)

      assert.are.same({ "/health", "/version" }, calls)
      assert.are.same(true, result.ok)
      assert.are.same("/version", result.endpoint)
      assert.are.same("/version", result.probe.endpoint)
      assert.are.same("version", result.probe.kind)
      assert.are.same("200", result.probe.code)
      assert.are.same(7, result.probe.parsed.apiVersion)
    end)

    it("stops on a complete /health payload", function()
      local calls = {}
      local result = nil

      discovery.probe_contract(function(path, done)
        table.insert(calls, path)
        done(true, {
          raw = [[{"healthy":true,"status":"Ready","apiVersion":7,"features":["live-testing"]}]],
          code = "200",
        })
      end, function(ok, probe, endpoint)
        result = { ok = ok, probe = probe, endpoint = endpoint }
      end)

      assert.are.same({ "/health" }, calls)
      assert.are.same(true, result.ok)
      assert.are.same("/health", result.endpoint)
      assert.are.same("connected", result.probe.kind)
      assert.are.same(7, result.probe.parsed.apiVersion)
    end)
  end)
end)
