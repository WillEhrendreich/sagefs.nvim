# As-You-Type Live Testing for .fs Files

## Why This Matters

As-you-type live testing is table stakes — VS Enterprise already does it. The differentiator:
- **Faster**: Scope-level reloading via tree-sitter, not whole-solution Roslyn rebuild
- **Lighter**: No VS Enterprise license. No IDE lock-in.
- **Cross-editor**: Neovim, VS Code, VS — identical experience everywhere
- **F#-native**: Built for F# from the ground up, not a C#-first afterthought

## Problem

Live testing in SageFs only triggers on file SAVE (filesystem watcher). Users editing `.fs` files
get ZERO feedback until they save. The whole point of live testing is seeing test results react to
what you're typing IN REAL TIME — before you decide to save.

## Design Principles (NON-NEGOTIABLE)

- **NO auto-save.** The file on disk is NEVER touched. The user decides when to save.
- **Tree-sitter scoping.** Neovim uses tree-sitter to identify the function/let binding being edited.
  Tree-sitter does error-tolerant incremental parsing — even mid-keystroke with broken syntax, it
  still identifies the enclosing function scope (ERROR nodes are INSIDE the scope, not replacing it).
- **Pre-computed affected test mappings.** SageFs already knows which tests map to which source files.
  The mapping from "this function in this file" → "these test IDs" should be pre-computed at discovery.
- **Send just the scope.** The plugin sends the changed function chunk, NOT the whole buffer.
- **SageFs patches server-side.** SageFs maintains an in-memory copy of loaded files. It splices
  the changed function into its cached copy, writes to a temp path (NOT the source file), and
  `#load`s it. Module gets redefined, tests pick up new definitions.
- **Tree-sitter IS the broken-code guard.** Broken code mid-typing simply fails type-check on the
  SageFs side and doesn't advance to `#load`. FSI session is never touched until compilation succeeds.
  No special guard needed — just the normal pipeline.
- **Results via SSE.** Existing SSE infrastructure pushes results. No new transport.

## Architecture

```
TextChanged/TextChangedI (*.fs)
  → debounce 300-500ms
  → tree-sitter: find enclosing value_declaration
  → extract { filePath, scopeName, scopeText, startLine, endLine }
  → POST /api/live-testing/evaluate-scope
  → SageFs patches in-memory file copy at line range
  → type-check patched file (broken code just doesn't advance — normal flow)
  → if OK: #load temp file → run affected tests → SSE results
  → if error: SSE diagnostic event, FSI untouched
```

## Implementation Plan

### Phase 1: sagefs.nvim — Tree-Sitter Scope Extraction + TextChanged

1. Add `TextChanged` + `TextChangedI` autocmds for `*.fs` in `commands.lua`
2. Debounce timer (300-500ms, configurable)
3. Tree-sitter query to find enclosing `value_declaration` / `function_or_value_defn`
4. Extract scope: name, text, start/end lines
5. POST to SageFs endpoint with extracted scope + file path
6. Handle response (202 accepted, scope queued for eval)

### Phase 2: SageFs — Evaluate-Scope Endpoint

1. New endpoint: `POST /api/live-testing/evaluate-scope`
2. Accepts: `{ filePath, scopeName, scopeText, startLine, endLine }`
3. Maintain in-memory shadow copies of loaded `.fs` files
4. Patch shadow copy: replace lines startLine..endLine with scopeText
5. Write patched file to temp path (NOT the real file)
6. Type-check patched file via FCS
7. If OK: `#load` temp file in FSI → run pre-mapped affected tests
8. If error: emit `scope_check_failed` SSE event with diagnostics
9. Clean up temp file after reload

### Phase 3: Pre-computed Function→Test Mappings

1. During test discovery, SageFs already has source locations for tests
2. Extend mapping: source file + function name → test IDs
3. When evaluate-scope arrives, use mapping to determine WHICH tests to run
4. Only run tests affected by the specific function being edited

### Phase 4: Editor-Agnostic (VS Code, VS, other editors)

1. The endpoint is HTTP — any editor can call it
2. VS Code extension: use tree-sitter-equivalent (semantic tokens) for scope detection
3. VS extension: Roslyn for scope detection
4. Same POST, same SSE results

## Key Technical Details

- **FSI module redefinition**: When you `#load` a file that declares a module, FSI redefines that
  module. Tests that reference `ModuleName.functionName` pick up the new definition automatically.
- **Tree-sitter node types**: F# tree-sitter grammar uses `value_declaration` for let bindings.
  Walk up from cursor node to find the enclosing one. `vim.treesitter.get_node()` + parent walk.
- **Debounce**: Use `vim.fn.timer_start` with cancel-on-new-change pattern (same as existing
  `schedule_render` in init.lua).
- **Transport**: Use existing `sagefs.transport` module for HTTP POST to SageFs daemon.
