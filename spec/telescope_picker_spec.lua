-- =============================================================================
-- Telescope Picker Tests — sagefs/telescope_picker.lua
-- =============================================================================
-- Tests cover:
--   1. Module loads without error regardless of telescope availability
--   2. Warning notification emitted when telescope is missing
--   3. Status prefix formatting: PASS/FAIL/STALE/RUN/NEW/SKIP/OFF
-- =============================================================================

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function reset_module()
  package.loaded["sagefs.telescope_picker"] = nil
  vim._notifications = {}
end

local function unload_telescope()
  -- Remove any cached telescope modules so pcall(require,"telescope") fails
  package.loaded["telescope"]                          = nil
  package.loaded["telescope.pickers"]                  = nil
  package.loaded["telescope.finders"]                  = nil
  package.loaded["telescope.config"]                   = nil
  package.loaded["telescope.actions"]                  = nil
  package.loaded["telescope.actions.state"]            = nil
  package.loaded["telescope.pickers.entry_display"]    = nil
  package.loaded["telescope.previewers"]               = nil
end

local function install_fake_telescope()
  -- Minimal telescope stubs sufficient for module load
  local select_default = { replace = function() end }
  package.loaded["telescope"] = {
    register_extension = function(e) return e end,
  }
  package.loaded["telescope.pickers"] = {
    new = function(_, _opts) return { find = function() end } end,
  }
  package.loaded["telescope.finders"] = {
    new_table = function(o) return o end,
  }
  package.loaded["telescope.config"] = {
    values = {
      generic_sorter   = function() return {} end,
      grep_previewer   = function() return {} end,
    },
  }
  package.loaded["telescope.actions"] = {
    close           = function() end,
    select_default  = select_default,
  }
  package.loaded["telescope.actions.state"] = {
    get_selected_entry = function() return nil end,
    get_current_line   = function() return "" end,
  }
  package.loaded["telescope.pickers.entry_display"] = {
    create = function(_)
      return function(items) return items end
    end,
  }
  package.loaded["telescope.previewers"] = {
    new_buffer_previewer = function(o) return o end,
  }
end

local function remove_fake_telescope()
  package.loaded["telescope"]                        = nil
  package.loaded["telescope.pickers"]                = nil
  package.loaded["telescope.finders"]                = nil
  package.loaded["telescope.config"]                 = nil
  package.loaded["telescope.actions"]                = nil
  package.loaded["telescope.actions.state"]          = nil
  package.loaded["telescope.pickers.entry_display"]  = nil
  package.loaded["telescope.previewers"]             = nil
end

-- ─── Module load: telescope missing ──────────────────────────────────────────

describe("telescope_picker: telescope not available", function()
  before_each(function()
    unload_telescope()
    reset_module()
  end)

  it("loads without error", function()
    local ok, result = pcall(require, "sagefs.telescope_picker")
    assert.is_true(ok, "module should load without error even when telescope is missing")
    assert.is_table(result, "should return a table")
  end)

  it("emits a WARN notification about telescope not found", function()
    require("sagefs.telescope_picker")
    local found = false
    for _, n in ipairs(vim._notifications) do
      if type(n.msg) == "string"
        and n.msg:lower():find("telescope")
        and n.level == vim.log.levels.WARN
      then
        found = true
        break
      end
    end
    assert.is_true(found, "expected a WARN notification mentioning telescope")
  end)

  it("does not expose pick_test when telescope is missing", function()
    local m = require("sagefs.telescope_picker")
    -- pick_test should be nil (telescope not loaded → guarded section skipped)
    assert.is_nil(m.pick_test, "pick_test should not be defined without telescope")
  end)

  it("still exposes format_status_prefix", function()
    local m = require("sagefs.telescope_picker")
    assert.is_function(m.format_status_prefix, "format_status_prefix should always be available")
  end)
end)

-- ─── Module load: telescope available (mocked) ───────────────────────────────

describe("telescope_picker: telescope available (mocked)", function()
  before_each(function()
    unload_telescope()
    reset_module()
    install_fake_telescope()
  end)

  after_each(function()
    remove_fake_telescope()
    reset_module()
  end)

  it("loads without error when telescope is present", function()
    local ok, result = pcall(require, "sagefs.telescope_picker")
    assert.is_true(ok, "module should load without error when telescope is present")
    assert.is_table(result)
  end)

  it("exposes pick_test when telescope is present", function()
    local m = require("sagefs.telescope_picker")
    assert.is_function(m.pick_test, "pick_test should be a function when telescope is available")
  end)

  it("does not emit a warning when telescope is present", function()
    require("sagefs.telescope_picker")
    for _, n in ipairs(vim._notifications) do
      if type(n.msg) == "string" and n.msg:lower():find("telescope") and n.level == vim.log.levels.WARN then
        assert.fail("unexpected telescope warning when telescope is available: " .. n.msg)
      end
    end
  end)
end)

-- ─── Entry formatting: status prefixes ───────────────────────────────────────

describe("telescope_picker: format_status_prefix", function()
  local m

  before_each(function()
    unload_telescope()
    reset_module()
    -- Load without telescope so we get just the pure functions
    m = require("sagefs.telescope_picker")
  end)

  it("formats Passed as [PASS]", function()
    assert.are.equal("[PASS]", m.format_status_prefix("Passed"))
  end)

  it("formats Failed as [FAIL]", function()
    assert.are.equal("[FAIL]", m.format_status_prefix("Failed"))
  end)

  it("formats Stale as [STALE]", function()
    assert.are.equal("[STALE]", m.format_status_prefix("Stale"))
  end)

  it("formats Running as [RUN ]", function()
    assert.are.equal("[RUN ]", m.format_status_prefix("Running"))
  end)

  it("formats Queued as [RUN ]", function()
    assert.are.equal("[RUN ]", m.format_status_prefix("Queued"))
  end)

  it("formats Detected as [NEW ]", function()
    assert.are.equal("[NEW ]", m.format_status_prefix("Detected"))
  end)

  it("formats Skipped as [SKIP]", function()
    assert.are.equal("[SKIP]", m.format_status_prefix("Skipped"))
  end)

  it("formats PolicyDisabled as [OFF ]", function()
    assert.are.equal("[OFF ]", m.format_status_prefix("PolicyDisabled"))
  end)

  it("returns fallback [    ] for unknown status", function()
    assert.are.equal("[    ]", m.format_status_prefix("banana"))
    assert.are.equal("[    ]", m.format_status_prefix(nil))
    assert.are.equal("[    ]", m.format_status_prefix(""))
  end)
end)

-- ─── STATUS_PREFIX table completeness ────────────────────────────────────────

describe("telescope_picker: STATUS_PREFIX table", function()
  local m

  before_each(function()
    unload_telescope()
    reset_module()
    m = require("sagefs.telescope_picker")
  end)

  it("covers all statuses used by sagefs.testing", function()
    local testing_statuses = {
      "Detected", "Queued", "Running", "Passed",
      "Failed", "Skipped", "Stale", "PolicyDisabled",
    }
    for _, status in ipairs(testing_statuses) do
      local prefix = m.format_status_prefix(status)
      assert.is_string(prefix, "should return string for status: " .. status)
      assert.is_true(#prefix > 0, "prefix should not be empty for status: " .. status)
    end
  end)
end)
