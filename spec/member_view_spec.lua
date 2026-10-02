-- :SageFsMintMember and :SageFsRevokeMember. Both call a conductor-only MCP tool
-- on the daemon. A mint reply holds the token, which SageFs shows once and keeps
-- only the hash of, so the reply goes to a float and nowhere else: not to a
-- notification (the message log keeps those), not to the command history, not
-- to a log. The window and the registration are checked in a real Neovim by
-- spec/nvim_harness.lua; this file covers the words and the flow.
require("spec.helper")
local V = require("sagefs.member_view")

local TOKEN = "sfm_Zk3vQ9mT1xWc7Yh2LpB8aDfG5jRuN0sEoIqXtVyHwKc"
local MINTED = table.concat({
  "Minted member cap:0123456789abcdef.",
  "  role:    Analysis (cohort role Observer)",
  "  scope:   src/Foo/ (claims outside it are refused)",
  "  expires: 2026-10-02 12:00:00Z, and lapses after 30 minutes without a call",
  "",
  "TOKEN (shown once; SageFs keeps only its hash, so it cannot be shown again):",
  "  " .. TOKEN,
  "",
  "Present it on every call in the X-SageFs-Member-Token HTTP header.",
}, "\n")

local function fake_client(reply)
  local client = { calls = {} }
  function client.call_tool(name, args, cb)
    table.insert(client.calls, { name = name, args = args })
    cb(reply.ok, reply.text)
  end
  return client
end

local function fake_ui()
  local ui = { said = {}, floats = {} }
  function ui.say(msg, level) table.insert(ui.said, { msg = msg, level = level }) end
  function ui.show_once(lines) table.insert(ui.floats, lines) end
  return ui
end

local function everything_said(ui)
  local parts = {}
  for _, s in ipairs(ui.said) do table.insert(parts, s.msg) end
  return table.concat(parts, "\n")
end

describe("member_view.parse_mint_args", function()
  it("takes a role and defaults the scope to the whole repo and the lifetime to the daemon's", function()
    local a = assert(V.parse_mint_args({ "Analysis" }))
    assert.are.equal("Analysis", a.role)
    assert.are.equal("", a.scope)
    assert.are.equal(0, a.ttl_minutes)
  end)

  it("takes a scope and minutes", function()
    local a = assert(V.parse_mint_args({ "Implementer", "src/Foo/", "60" }))
    assert.are.equal("Implementer", a.role)
    assert.are.equal("src/Foo/", a.scope)
    assert.are.equal(60, a.ttl_minutes)
  end)

  it("reads a role in any case and sends it the way the daemon spells it", function()
    assert.are.equal("Observer", assert(V.parse_mint_args({ "observer" })).role)
    assert.are.equal("Verifier", assert(V.parse_mint_args({ "VERIFIER" })).role)
  end)

  it("refuses no role, naming the four there are", function()
    local a, err = V.parse_mint_args({})
    assert.is_nil(a)
    for _, role in ipairs({ "Observer", "Analysis", "Verifier", "Implementer" }) do
      assert.truthy(err:find(role, 1, true))
    end
  end)

  it("refuses a role it does not know, and says which", function()
    local a, err = V.parse_mint_args({ "Admin" })
    assert.is_nil(a)
    assert.truthy(err:find("Admin", 1, true))
  end)

  it("refuses minutes that are not a whole number from 0 to 480", function()
    for _, bad in ipairs({ "soon", "-5", "481", "1.5" }) do
      local a, err = V.parse_mint_args({ "Analysis", ".", bad })
      assert.is_nil(a, bad)
      assert.truthy(err:find("480", 1, true), bad)
    end
  end)

  it("refuses an argument it has no place for", function()
    local a, err = V.parse_mint_args({ "Analysis", ".", "60", "extra" })
    assert.is_nil(a)
    assert.truthy(err)
  end)

  it("refuses a pasted token as a scope, without printing it", function()
    local a, err = V.parse_mint_args({ "Analysis", TOKEN })
    assert.is_nil(a)
    assert.is_nil(err:find(TOKEN, 1, true))
  end)
end)

describe("member_view.parse_revoke_args", function()
  it("takes a cap:<hex> id", function()
    assert.are.equal("cap:0123456789abcdef", assert(V.parse_revoke_args({ "cap:0123456789abcdef" })))
  end)

  it("refuses no id", function()
    local id, err = V.parse_revoke_args({})
    assert.is_nil(id)
    assert.truthy(err:find("cap:", 1, true))
  end)

  it("refuses an id that is not a minted run, and names what it takes", function()
    local id, err = V.parse_revoke_args({ "mcp:m-0123456789abcdef" })
    assert.is_nil(id)
    assert.truthy(err:find("cap:", 1, true))
  end)

  it("refuses a pasted token, without printing it", function()
    local id, err = V.parse_revoke_args({ TOKEN })
    assert.is_nil(id)
    assert.is_nil(err:find(TOKEN, 1, true))
  end)
end)

describe("member_view.mint", function()
  it("calls mint_member with the plugin's name, the role, the scope and the lifetime, and no token", function()
    local client, ui = fake_client({ ok = true, text = MINTED }), fake_ui()
    V.mint({ "Analysis", "src/Foo/", "60" }, { client = client, say = ui.say, show_once = ui.show_once })
    assert.are.equal(1, #client.calls)
    assert.are.equal("mint_member", client.calls[1].name)
    assert.are.same({ agentName = "sagefs.nvim", role = "Analysis", scope = "src/Foo/", ttl_minutes = 60 }, client.calls[1].args)
  end)

  it("shows the reply once in a float, and says nothing that carries the token", function()
    local client, ui = fake_client({ ok = true, text = MINTED }), fake_ui()
    V.mint({ "Analysis" }, { client = client, say = ui.say, show_once = ui.show_once })
    assert.are.equal(1, #ui.floats)
    local shown = table.concat(ui.floats[1], "\n")
    assert.truthy(shown:find(TOKEN, 1, true))
    assert.truthy(shown:find("cap:0123456789abcdef", 1, true))
    assert.truthy(shown:lower():find("only time", 1, true))
    assert.is_nil(everything_said(ui):find(TOKEN, 1, true))
  end)

  it("announces the member id and not the token", function()
    local client, ui = fake_client({ ok = true, text = MINTED }), fake_ui()
    V.mint({ "Analysis" }, { client = client, say = ui.say, show_once = ui.show_once })
    local said = everything_said(ui)
    assert.truthy(said:find("cap:0123456789abcdef", 1, true))
    assert.is_nil(said:find("sfm_", 1, true))
  end)

  it("says why when the daemon refuses, shows no float, and scrubs a token from the words", function()
    local client, ui = fake_client({ ok = false, text = "Error: not the cohort conductor " .. TOKEN }), fake_ui()
    V.mint({ "Analysis" }, { client = client, say = ui.say, show_once = ui.show_once })
    assert.are.equal(0, #ui.floats)
    local said = everything_said(ui)
    assert.truthy(said:find("not the cohort conductor", 1, true))
    assert.is_nil(said:find(TOKEN, 1, true))
    assert.are.equal(vim.log.levels.ERROR, ui.said[#ui.said].level)
  end)

  it("a reply with no token in it is said, not floated, and calls nothing twice", function()
    local client, ui = fake_client({ ok = true, text = "Minted nothing." }), fake_ui()
    V.mint({ "Analysis" }, { client = client, say = ui.say, show_once = ui.show_once })
    assert.are.equal(0, #ui.floats)
    assert.truthy(everything_said(ui):find("Minted nothing.", 1, true))
    assert.are.equal(1, #client.calls)
  end)

  it("calls nothing on bad arguments and says what is wrong", function()
    local client, ui = fake_client({ ok = true, text = MINTED }), fake_ui()
    V.mint({ "Admin" }, { client = client, say = ui.say, show_once = ui.show_once })
    assert.are.equal(0, #client.calls)
    assert.truthy(everything_said(ui):find("Admin", 1, true))
  end)
end)

describe("member_view.revoke", function()
  it("calls revoke_member with the plugin's name and the id", function()
    local client, ui = fake_client({ ok = true, text = "Revoked cap:0123456789abcdef." }), fake_ui()
    V.revoke({ "cap:0123456789abcdef" }, { client = client, say = ui.say, show_once = ui.show_once })
    assert.are.same({ { name = "revoke_member", args = { agentName = "sagefs.nvim", member_id = "cap:0123456789abcdef" } } }, client.calls)
    assert.truthy(everything_said(ui):find("Revoked cap:0123456789abcdef.", 1, true))
    assert.are.equal(0, #ui.floats)
  end)

  it("says why when the daemon refuses", function()
    local client, ui = fake_client({ ok = false, text = "Error: no such member token" }), fake_ui()
    V.revoke({ "cap:0123456789abcdef" }, { client = client, say = ui.say, show_once = ui.show_once })
    assert.truthy(everything_said(ui):find("no such member token", 1, true))
    assert.are.equal(vim.log.levels.ERROR, ui.said[#ui.said].level)
  end)

  it("calls nothing when the id is not a minted run", function()
    local client, ui = fake_client({ ok = true, text = "x" }), fake_ui()
    V.revoke({ TOKEN }, { client = client, say = ui.say, show_once = ui.show_once })
    assert.are.equal(0, #client.calls)
    assert.is_nil(everything_said(ui):find(TOKEN, 1, true))
  end)
end)
