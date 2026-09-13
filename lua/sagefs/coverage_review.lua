-- sagefs/coverage_review.lua — Navigable coverage review view
--
-- Turns the flat "N% covered" summary into something you can actually
-- browse: a quickfix list of files → uncovered lines, with an overall
-- and per-file summary at the top. Jump to any uncovered line with <CR>
-- or :cnext/:cprev, same as any other quickfix list.
--
-- Split like the rest of the plugin: `build_qflist_items`/`empty_message`
-- are pure (testable under busted); `open`/`refresh`/`is_active` are the
-- thin vim.fn/vim.cmd glue, exercised via spec/nvim_harness.lua.

local coverage = require("sagefs.coverage")

local M = {}

-- Title used to identify "our" quickfix list among any others the user
-- has open, so live refreshes never clobber an unrelated list.
M.TITLE = "SageFs Coverage"

-- ─── Pure: quickfix item construction ───────────────────────────────────────

--- Build quickfix items from a coverage state: an overall summary line,
--- then per-file summary lines followed by a jumpable entry for each of
--- that file's uncovered lines. Returns an empty list when there is no
--- coverage data at all (caller should show `empty_message` instead of
--- opening an empty list).
---@param state table coverage state (sagefs.coverage)
---@return table[] items suitable for vim.fn.setqflist({}, ' ', { items = ... })
function M.build_qflist_items(state)
  local review = coverage.build_review(state)
  local items = {}

  if #review.files == 0 then
    return items
  end

  table.insert(items, { text = string.format("Overall: %s", coverage.format_summary(review.total)) })
  table.insert(items, { text = "" })

  for _, f in ipairs(review.files) do
    table.insert(items, {
      text = string.format("%s  %s", coverage.format_summary(f.summary), f.path),
    })
    if #f.uncovered == 0 then
      table.insert(items, { text = "  (fully covered)" })
    else
      for _, line in ipairs(f.uncovered) do
        table.insert(items, {
          filename = f.path,
          lnum = line,
          col = 1,
          text = "uncovered",
        })
      end
    end
  end

  return items
end

--- Friendly message shown when there is no coverage data to review yet.
---@return string
function M.empty_message()
  return "No coverage data yet — run tests to see coverage."
end

-- ─── Vim-dependent glue ──────────────────────────────────────────────────────

--- Whether the SageFs coverage list is the currently active quickfix list.
--- Used to decide whether a live SSE update should refresh it in place.
---@return boolean
function M.is_active()
  local ok, info = pcall(vim.fn.getqflist, { title = 1 })
  return ok and type(info) == "table" and info.title == M.TITLE
end

--- Open (or reopen) the coverage review as a quickfix list. Shows the
--- friendly empty-state message instead of an empty window when there's
--- no coverage data yet.
---@param state table coverage state (sagefs.coverage)
function M.open(state)
  local items = M.build_qflist_items(state)
  if #items == 0 then
    vim.notify("[SageFs] " .. M.empty_message(), vim.log.levels.INFO)
    return
  end
  vim.fn.setqflist({}, " ", { title = M.TITLE, items = items })
  vim.cmd("copen")
end

--- Refresh the coverage quickfix list in place — but only when it is the
--- currently active list, so a user who navigated to some other quickfix
--- list never has it silently replaced underneath them. Safe to call on
--- every coverage-related SSE event; it is a no-op when not open.
---@param state table coverage state (sagefs.coverage)
function M.refresh(state)
  if not M.is_active() then return end
  local items = M.build_qflist_items(state)
  if #items == 0 then
    -- Coverage was cleared (e.g. coverage_cleared / session change) while
    -- the review was open — replace it with the empty-state message
    -- rather than leaving stale entries on screen.
    vim.fn.setqflist({}, "r", { title = M.TITLE, items = { { text = M.empty_message() } } })
    return
  end
  vim.fn.setqflist({}, "r", { title = M.TITLE, items = items })
end

return M
