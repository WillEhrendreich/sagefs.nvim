-- Tests — sagefs.app_run: request building, response parsing, formatting
require("spec.helper")
local app_run = require("sagefs.app_run")

describe("app_run.build_run_body", function()
  it("returns nil when project is nil", function()
    assert.is_nil(app_run.build_run_body(nil))
  end)

  it("returns nil when project is an empty string", function()
    assert.is_nil(app_run.build_run_body(""))
  end)

  it("returns { project = name } when a project is given", function()
    assert.same({ project = "MyApp" }, app_run.build_run_body("MyApp"))
  end)
end)

describe("app_run.build_run_request", function()
  it("builds a POST to /api/sessions/<sid>/run-app with no body for the default target", function()
    local req = app_run.build_run_request("abc12345", nil)
    assert.are.equal("POST", req.method)
    assert.are.equal("/api/sessions/abc12345/run-app", req.path)
    assert.is_nil(req.body)
  end)

  it("builds a POST with { project = ... } when a project is named", function()
    local req = app_run.build_run_request("abc12345", "WebApp")
    assert.are.equal("POST", req.method)
    assert.are.equal("/api/sessions/abc12345/run-app", req.path)
    assert.same({ project = "WebApp" }, req.body)
  end)

  it("treats an empty-string project as no project", function()
    local req = app_run.build_run_request("abc12345", "")
    assert.is_nil(req.body)
  end)
end)

describe("app_run.build_stop_request", function()
  it("builds a bodiless POST to /api/sessions/<sid>/stop-app", function()
    local req = app_run.build_stop_request("abc12345")
    assert.are.equal("POST", req.method)
    assert.are.equal("/api/sessions/abc12345/stop-app", req.path)
    assert.is_nil(req.body)
  end)
end)

describe("app_run.parse_state", function()
  it("returns kind = Unknown for non-table input", function()
    assert.same({ kind = "Unknown" }, app_run.parse_state(nil))
  end)

  -- Real success-body shape: SageFs.Core/AppRun.fs's AppRunState projected
  -- to JSON as { State, Message, Urls, EntryPoint, RunId } (flat, PascalCase).
  it("reads the real AppStateView shape: State + Urls[1] + Message", function()
    local state = app_run.parse_state({
      State = "Running",
      Message = "listening",
      Urls = { "http://localhost:5000", "https://localhost:5001" },
      EntryPoint = "MyApp.dll",
      RunId = "run-1",
    })
    assert.are.equal("Running", state.kind)
    assert.are.equal("http://localhost:5000", state.url)
    assert.are.equal("listening", state.reason)
    assert.are.equal("MyApp.dll", state.entry_point)
    assert.are.equal("run-1", state.run_id)
  end)

  it("has no url when Urls is absent or empty", function()
    assert.is_nil(app_run.parse_state({ State = "Starting", Message = "" }).url)
    assert.is_nil(app_run.parse_state({ State = "Starting", Urls = {} }).url)
  end)

  it("reads Message as the reason for a failure state", function()
    local state = app_run.parse_state({ State = "BuildFailed", Message = "FS0039: not defined" })
    assert.are.equal("BuildFailed", state.kind)
    assert.are.equal("FS0039: not defined", state.reason)
  end)

  it("prefers State over any other spelling of the discriminator", function()
    local state = app_run.parse_state({ State = "Running", case = "Starting", kind = "Crashed" })
    assert.are.equal("Running", state.kind)
  end)

  it("prefers Urls[1] over any other spelling of the url", function()
    local state = app_run.parse_state({ Urls = { "http://real:1" }, url = "http://fallback:2" })
    assert.are.equal("http://real:1", state.url)
  end)

  it("prefers Message over any other spelling of the reason", function()
    local state = app_run.parse_state({ Message = "real reason", reason = "fallback reason" })
    assert.are.equal("real reason", state.reason)
  end)

  -- Defensive fallbacks only — exercised in case the wire shape ever drifts
  -- from the real AppStateView; State/Urls/Message above remain authoritative.
  it("falls back to Case/case/kind/Kind/status/Status when State is absent", function()
    assert.are.equal("Running", app_run.parse_state({ Case = "Running" }).kind)
    assert.are.equal("Running", app_run.parse_state({ case = "Running" }).kind)
    assert.are.equal("Starting", app_run.parse_state({ kind = "Starting" }).kind)
    assert.are.equal("Starting", app_run.parse_state({ status = "Starting" }).kind)
  end)

  it("falls back to url/Url/applicationUrl when Urls is absent", function()
    assert.are.equal("http://localhost:5000", app_run.parse_state({ url = "http://localhost:5000" }).url)
    assert.are.equal("http://localhost:5000", app_run.parse_state({ Url = "http://localhost:5000" }).url)
  end)

  it("falls back to reason/Reason/message when Message is absent", function()
    assert.are.equal("no exe project", app_run.parse_state({ reason = "no exe project" }).reason)
    assert.are.equal("compile error", app_run.parse_state({ message = "compile error" }).reason)
  end)
end)

describe("app_run.is_failure", function()
  it("is true for BuildFailed and CouldNotStart", function()
    assert.is_true(app_run.is_failure({ kind = "BuildFailed" }))
    assert.is_true(app_run.is_failure({ kind = "CouldNotStart" }))
  end)

  it("is false for Running/Starting/NotRunning/nil", function()
    assert.is_false(app_run.is_failure({ kind = "Running" }))
    assert.is_false(app_run.is_failure({ kind = "Starting" }))
    assert.is_false(app_run.is_failure({ kind = "NotRunning" }))
    assert.is_false(app_run.is_failure(nil))
  end)
end)

describe("app_run.format_run_notify", function()
  it("shows the URL when the app is running with one", function()
    local msg = app_run.format_run_notify({ kind = "Running", url = "http://localhost:5000" })
    assert.truthy(msg:find("http://localhost:5000", 1, true))
    assert.truthy(msg:find("running"))
  end)

  it("still reports running without a URL", function()
    local msg = app_run.format_run_notify({ kind = "Running" })
    assert.truthy(msg:find("running"))
  end)

  it("reports starting", function()
    assert.truthy(app_run.format_run_notify({ kind = "Starting" }):find("starting"))
  end)

  it("includes the reason for BuildFailed", function()
    local msg = app_run.format_run_notify({ kind = "BuildFailed", reason = "FS0039" })
    assert.truthy(msg:find("build failed"))
    assert.truthy(msg:find("FS0039", 1, true))
  end)

  it("includes the reason for CouldNotStart", function()
    local msg = app_run.format_run_notify({ kind = "CouldNotStart", reason = "no exe project" })
    assert.truthy(msg:find("could not start"))
    assert.truthy(msg:find("no exe project", 1, true))
  end)
end)

describe("app_run.format_stop_notify", function()
  it("reports stopped for NotRunning", function()
    assert.truthy(app_run.format_stop_notify({ kind = "NotRunning" }):find("stopped"))
  end)

  it("falls back to format_run_notify for other kinds", function()
    local msg = app_run.format_stop_notify({ kind = "BuildFailed", reason = "x" })
    assert.truthy(msg:find("build failed"))
  end)
end)

describe("app_run.format_error", function()
  it("combines message and suggestedAction", function()
    local msg = app_run.format_error({ message = "No session", suggestedAction = "Create one first" }, nil)
    assert.truthy(msg:find("No session", 1, true))
    assert.truthy(msg:find("Create one first", 1, true))
  end)

  it("accepts PascalCase Message/SuggestedAction", function()
    local msg = app_run.format_error({ Message = "Boom", SuggestedAction = "Retry" }, nil)
    assert.truthy(msg:find("Boom", 1, true))
    assert.truthy(msg:find("Retry", 1, true))
  end)

  it("omits the arrow when there is no suggestedAction", function()
    local msg = app_run.format_error({ message = "No session" }, nil)
    assert.are.equal("No session", msg)
  end)

  it("falls back to the raw text when parsed is not a table", function()
    assert.are.equal("connect: refused", app_run.format_error(nil, "connect: refused"))
  end)

  it("falls back to a generic message when nothing is available", function()
    assert.are.equal("Unknown error", app_run.format_error(nil, nil))
  end)
end)

describe("app_run — end-to-end: real AppStateView success body", function()
  it("a Running body with Urls produces the running notify with that URL and the running statusline icon", function()
    local body = { State = "Running", Message = "listening", Urls = { "http://localhost:5000" } }
    local state = app_run.parse_state(body)

    assert.are.equal("SageFs: app running at http://localhost:5000", app_run.format_run_notify(state))
    assert.are.equal("▶", app_run.format_statusline(state))
    assert.is_false(app_run.is_failure(state))
  end)

  it("a BuildFailed body surfaces Message as the failure reason end to end", function()
    local body = { State = "BuildFailed", Message = "FS0039: not defined", Urls = {} }
    local state = app_run.parse_state(body)

    local msg = app_run.format_run_notify(state)
    assert.truthy(msg:find("build failed"))
    assert.truthy(msg:find("FS0039", 1, true))
    assert.are.equal("⚠", app_run.format_statusline(state))
    assert.is_true(app_run.is_failure(state))
  end)
end)

describe("app_run.format_statusline", function()
  it("is empty when state is nil", function()
    assert.are.equal("", app_run.format_statusline(nil))
  end)

  it("is empty for NotRunning (hidden when not running)", function()
    assert.are.equal("", app_run.format_statusline({ kind = "NotRunning" }))
  end)

  it("shows a running indicator", function()
    assert.are.equal("▶", app_run.format_statusline({ kind = "Running" }))
  end)

  it("shows a starting indicator", function()
    assert.are.equal("⏳", app_run.format_statusline({ kind = "Starting" }))
  end)

  it("shows a failure indicator for BuildFailed and CouldNotStart", function()
    assert.are.equal("⚠", app_run.format_statusline({ kind = "BuildFailed" }))
    assert.are.equal("⚠", app_run.format_statusline({ kind = "CouldNotStart" }))
  end)
end)
