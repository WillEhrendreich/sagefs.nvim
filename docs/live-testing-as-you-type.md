# As-You-Type Live Testing — Neovim Plugin

> See `docs/live-testing-as-you-type.md` in the SageFs repo for the centralized architecture,
> endpoint contract, server pipeline, and decision log. This doc covers **Neovim-specific** implementation only.

## Current State

- Plugin uses tree-sitter for test discovery (`[<Test>]`/`[<Fact>]` attributes)
- Connects to SageFs daemon via HTTP + SSE (port 37749)
- Has SSE listener, gutter rendering, Telescope integration
- `TextChanged` autocmd fires for `*.fsx` only — **NOT** for `*.fs` files (this is the #1 bug)
- Live testing is observe-only for `.fs` files (no reaction to typing)

## What Needs to Change

Per the centralized design, the editor's only job is:

1. Register `TextChanged` + `TextChangedI` autocmds for `*.fs` files (currently only `*.fsx`)
2. On change: debounce 300ms, cancel previous timer
3. After debounce: use tree-sitter to find enclosing function scope, POST it to SageFs
4. Display results from existing SSE subscription (already done)

## Neovim-Specific: Tree-Sitter for Scope Extraction

Neovim's unique advantage: tree-sitter provides **error-tolerant** scope detection.
Even mid-keystroke with broken syntax, tree-sitter identifies the enclosing function
scope (ERROR nodes appear INSIDE the scope, not replacing it).

Tree-sitter `value_declaration` node walk extracts the function being edited:

```lua
local function find_enclosing_scope(bufnr, cursor_row)
  local parser = vim.treesitter.get_parser(bufnr, "fsharp")
  if not parser then return nil end
  local tree = parser:parse()[1]
  if not tree then return nil end

  local node = tree:root():named_descendant_for_range(cursor_row, 0, cursor_row, 0)
  while node do
    if node:type() == "value_declaration"
      or node:type() == "function_or_value_defn" then
      local sr, sc, er, ec = node:range()
      local lines = vim.api.nvim_buf_get_lines(bufnr, sr, er + 1, false)
      local text = table.concat(lines, "\n")
      -- extract function name from first line
      local name = lines[1] and lines[1]:match("let%s+(%w+)") or "unknown"
      return { scopeName = name, scopeText = text, startLine = sr, endLine = er }
    end
    node = node:parent()
  end
  return nil
end
```

This is ~20 lines of Lua. If tree-sitter can't find a scope (grammar mismatch, no parser),
nothing is POSTed — user sees stale results until code stabilizes.

## Implementation

### Step 1: Fix TextChanged Autocmds (`commands.lua`)

In `register_autocmds`, add `TextChanged` + `TextChangedI` for `*.fs`:

```lua
vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
  pattern = "*.fs",
  callback = function(ev)
    if not state.live_testing_enabled then return end
    debounce_post_scope(ev.buf)
  end,
})
```

### Step 2: Debounce + Extract Scope + POST

```lua
local debounce_timer = nil
local generation = 0

local function debounce_post_scope(bufnr)
  if debounce_timer then
    vim.fn.timer_stop(debounce_timer)
  end
  debounce_timer = vim.fn.timer_start(300, function()
    vim.schedule(function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local scope = find_enclosing_scope(bufnr, cursor[1] - 1)
      if not scope then return end

      generation = generation + 1
      transport.post("/api/live-testing/evaluate-scope", {
        filePath = vim.api.nvim_buf_get_name(bufnr),
        scopeName = scope.scopeName,
        scopeText = scope.scopeText,
        startLine = scope.startLine,
        endLine = scope.endLine,
        generation = generation,
      })
    end)
  end)
end
```

### Step 3: Existing SSE Handles Results

No changes needed. `LiveTestingListener` already processes test result SSE events
and `render_test_signs` already displays gutter markers.

## Files to Modify

1. `lua/sagefs/commands.lua` — add `TextChanged`/`TextChangedI` autocmds for `*.fs`
2. `lua/sagefs/init.lua` — add `debounce_post_scope` and `find_enclosing_scope`
3. `lua/sagefs/transport.lua` — ensure `post` function exists (may already exist)

## Dependencies

- **Requires** `POST /api/live-testing/evaluate-scope` endpoint in SageFs daemon
- **tree-sitter fsharp grammar** for scope extraction (if unavailable, nothing is POSTed)
- No new plugin dependencies
