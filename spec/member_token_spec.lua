-- The member capability token: where it comes from, how it is named, and how it
-- is kept out of everything that prints. A token (`sfm_` plus 43 URL-safe
-- characters) is minted by the daemon's mint_member tool and presented in the
-- X-SageFs-Member-Token header; SageFs keeps only its hash, so a token that
-- leaks into a log or a message cannot be taken back, only revoked.
require("spec.helper")
local T = require("sagefs.member_token")

local TOKEN = "sfm_Zk3vQ9mT1xWc7Yh2LpB8aDfG5jRuN0sEoIqXtVyHwKc"

describe("member_token names", function()
  it("sends the header the daemon reads and reads the variable the bridge reads", function()
    assert.are.equal("X-SageFs-Member-Token", T.HEADER)
    assert.are.equal("SAGEFS_MEMBER_TOKEN", T.ENV)
  end)
end)

describe("member_token.resolve: the setup option, else the environment", function()
  it("takes the setup option when there is one", function()
    assert.are.equal(TOKEN, T.resolve(TOKEN, nil))
  end)

  it("falls back to the environment variable", function()
    assert.are.equal(TOKEN, T.resolve(nil, TOKEN))
  end)

  it("lets the setup option win over the environment", function()
    assert.are.equal(TOKEN, T.resolve(TOKEN, "sfm_other"))
  end)

  it("treats unset, empty and blank as no token, so no header goes out", function()
    assert.is_nil(T.resolve(nil, nil))
    assert.is_nil(T.resolve("", ""))
    assert.is_nil(T.resolve("   ", "\t"))
    assert.is_nil(T.resolve(false, nil))
    assert.is_nil(T.resolve(42, nil))
  end)

  it("skips a blank option and uses the environment", function()
    assert.are.equal(TOKEN, T.resolve("  ", TOKEN))
  end)

  it("trims the whitespace a copy and paste or an export line leaves around a token", function()
    assert.are.equal(TOKEN, T.resolve("  " .. TOKEN .. "\n", nil))
  end)
end)

describe("member_token.redact: nothing printed carries a token", function()
  it("replaces the configured token wherever it appears", function()
    local out = T.redact("request failed for " .. TOKEN .. " twice: " .. TOKEN, TOKEN)
    assert.is_nil(out:find(TOKEN, 1, true))
    assert.truthy(out:find("request failed for", 1, true))
  end)

  it("replaces anything shaped like a token even when it is not the configured one", function()
    local out = T.redact("the daemon echoed sfm_AAAA_bbbb-CCCC1234 back", nil)
    assert.is_nil(out:find("sfm_AAAA", 1, true))
  end)

  it("leaves text without a token alone", function()
    assert.are.equal("Error: no cohort owner", T.redact("Error: no cohort owner", TOKEN))
    assert.are.equal("Error: no cohort owner", T.redact("Error: no cohort owner", nil))
  end)

  it("answers an empty string for a non-string", function()
    assert.are.equal("", T.redact(nil, TOKEN))
  end)
end)

describe("member_token.redact_headers: a header table safe to print", function()
  it("hides the token header's value, whatever the case of its name", function()
    local safe = T.redact_headers({ Accept = "x", ["X-SageFs-Member-Token"] = TOKEN, ["x-sagefs-member-token"] = TOKEN })
    assert.are.equal("x", safe.Accept)
    for _, v in pairs(safe) do assert.is_nil(tostring(v):find(TOKEN, 1, true)) end
  end)

  it("does not touch the table it was given", function()
    local h = { ["X-SageFs-Member-Token"] = TOKEN }
    T.redact_headers(h)
    assert.are.equal(TOKEN, h["X-SageFs-Member-Token"])
  end)
end)

describe("member_token.describe: how a config display says a token is set", function()
  it("says set and hidden, never the value", function()
    local text = T.describe(TOKEN)
    assert.truthy(text:find("set", 1, true))
    assert.is_nil(text:find(TOKEN, 1, true))
    assert.is_nil(text:find("sfm_", 1, true))
  end)

  it("says not set for nothing", function()
    assert.are.equal("not set", T.describe(nil))
  end)
end)

describe("health.config_lines: the configuration line :checkhealth prints", function()
  local health = require("sagefs.health")

  it("is silent about a token when none is configured, so today's output does not change", function()
    local lines = health.config_lines({ port = 37749 }, nil)
    assert.is_nil(table.concat(lines, ", "):find("member_token", 1, true))
  end)

  it("says a token is set and hides it, from the setup option", function()
    local text = table.concat(health.config_lines({ port = 37749, member_token = TOKEN }, nil), ", ")
    assert.truthy(text:find("member_token = set", 1, true))
    assert.is_nil(text:find(TOKEN, 1, true))
  end)

  it("says a token is set and hides it, from the environment", function()
    local text = table.concat(health.config_lines({ port = 37749 }, TOKEN), ", ")
    assert.truthy(text:find("member_token = set", 1, true))
    assert.is_nil(text:find(TOKEN, 1, true))
  end)
end)
