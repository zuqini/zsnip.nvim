# Project Instructions for AI Agents

## Build & Test

zsnip is a pure-Lua Neovim plugin — there is no build step. The test suite
runs under [busted](https://lunarmodules.github.io/busted/) inside Neovim.
busted must be installed into a project-local LuaRocks tree built against
LuaJIT — see `tests/TESTING.md` for the one-time `luarocks` setup.

```bash
# Run the full suite (must run inside Neovim — it exercises real vim.* APIs)
nvim -u NONE -l tests/busted.lua

# Lint and type-check (also run in CI)
luacheck lua/ tests/
lua-language-server --check "$PWD/lua" --checklevel=Warning --configpath="$PWD/.luarc.json"
```

## Architecture Overview

zsnip loads snippet collections and hands their bodies to Neovim's
`vim.snippet`. It does not implement expansion, sessions or tabstops.

- `init.lua` — the public API; every other module is an implementation detail.
- `config.lua` — resolved `setup()` options. Usable before `setup()` runs.
- `registry.lua` — discovery, caching and resolution: which snippets a
  filetype gets, and when the runtimepath is rescanned.
- `parsers/vscode.lua` / `parsers/snipmate.lua` — one format each, pure
  functions from a path to snippets.
- `loaders/from_vscode.lua` / `loaders/from_snipmate.lua` — the public
  `lazy_load()`/`load()` entry points; thin wrappers over `registry.enable()`.
- `body.lua` — everything between a body as written and a body
  `vim.snippet.expand()` accepts: variable resolution, `${0:…}` renumbering,
  grammar validation.
- `completion.lua` — snippets as `lsp.CompletionItem[]`.
- `lsp.lua` — the in-process language server that serves them.
- `blink.lua` / `cmp.lua` — native completion sources. Neither may `require`
  its engine at module scope: they must load on a config that does not have it.
- `complete.lua` — a `'complete'` function source for Neovim's own completion.
  The only source that matches and expands for itself; the other three hand an
  `lsp.CompletionItem` to something that already knows what to do with it.
- `commands.lua` — the `:ZSnip` user command.
- `health.lua` — `:checkhealth zsnip` diagnostics.
- `util.lua` — the shared filesystem seam: every read the parsers do goes
  through it, and every one of them is a `pcall`.
- `types.lua` — annotations only; the module itself is empty.

## Conventions & Patterns

- Code is self-documenting; add comments only where the logic is non-obvious —
  and when it is, say *why*, not what.
- `lua/` is kept type-clean (`lua-language-server --check`) and lint-clean
  (`luacheck`); both run in CI on every PR.
- Target PUC Lua 5.1 / LuaJIT — no `goto`, no 5.2+ stdlib.
- Neovim 0.12.0 is the floor. Anything newer must be feature-detected.
- Nothing may read the filesystem at startup: discovery is per filetype, on
  first use.
- Update `README.md`, `docs/` and `doc/zsnip.txt` alongside code changes.
