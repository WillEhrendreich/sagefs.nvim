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
3. After debounce: POST full buffer text + editRegion hint + generation counter
4. Display results from existing SSE subscription (already done)

## Neovim-Specific: Tree-Sitter for editRegion Hint

Neovim's unique advantage: tree-sitter provides **error-tolerant** scope detection.
Even mid-keystroke with broken syntax, tree-sitter identifies the enclosing function
scope (ERROR nodes appear INSIDE the scope, not replacing it).

The `editRegion` hint uses tree-sitter `value_declaration` node walk:

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
      local sr, _, er, _ = node:range()
      return { startLine = sr, endLine = er }
    end
    node = node:parent()
  end
  return nil  -- fallback: server does full-file scope detection
end
```

This is ~15 lines of Lua. If tree-sitter can't find a scope (grammar mismatch, no parser),
the hint is omitted and the server falls back to full-file analysis.

## Implementation

### Step 1: Fix TextChanged Autocmds (`commands.lua`)

In `register_autocmds`, add `TextChanged` + `TextChangedI` for `*.fs`:

```lua
-- existing: TextChanged for *.fsx
-- ADD: TextChanged + TextChangedI for *.fs
vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
  pattern = "*.fs",
  callback = function(ev)
    if not state.live_testing_enabled then return end
    debounce_post_buffer(ev.buf)
  end,
})
```

### Step 2: Debounce + POST Full Buffer

```lua
local debounce_timer = nil
local generation = 0

local function debounce_post_buffer(bufnr)
  if debounce_timer then
    vim.fn.timer_stop(debounce_timer)
  end
  debounce_timer = vim.fn.timer_start(300, function()
    generation = generation + 1
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local full_text = table.concat(lines, "\n")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local edit_region = find_enclosing_scope(bufnr, cursor[1] - 1)

    transport.post("/api/live-testing/evaluate-scope", {
      filePath = vim.api.nvim_buf_get_name(bufnr),
      fullText = full_text,
      editRegion = edit_region or { startLine = 0, endLine = #lines - 1 },
      generation = generation,
    })
  end)
end
```

### Step 3: Existing SSE Handles Results

No changes needed. `LiveTestingListener` already processes test result SSE events
and `render_test_signs` already displays gutter markers.

## Files to Modify

1. `lua/sagefs/commands.lua` — add `TextChanged`/`TextChangedI` autocmds for `*.fs`
2. `lua/sagefs/init.lua` — add `debounce_post_buffer` and `find_enclosing_scope`
3. `lua/sagefs/transport.lua` — ensure `post` function exists (may already exist)

## Dependencies

- **Requires** `POST /api/live-testing/evaluate-scope` endpoint in SageFs daemon
- **tree-sitter fsharp grammar** for editRegion hint (optional — fallback is full-file range)
- No new plugin dependencies
