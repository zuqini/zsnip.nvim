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

- `init.lua` — the public API for loading, matching and expanding snippets.
  `loaders/*`, `lsp.lua`, `blink.lua`, `cmp.lua` and `complete.lua` are public
  entry points too, for serving them. `registry.lua`, `body.lua`,
  `completion.lua`, `util.lua` and `parsers/*` are implementation details.
- `config.lua` — resolved `setup()` options. Usable before `setup()` runs.
- `registry.lua` — discovery, caching and resolution: which snippets a
  filetype gets, when the runtimepath is rescanned, and (`kinds()`) which
  loader kinds exist and in what order they scan.
- `parsers/vscode.lua` / `parsers/snipmate.lua` — one format each, pure
  functions from a path to snippets. `parsers/vscode.lua` also exports
  `contributions(manifest)` and `scopes(path)`, the manifest and scope readers
  discovery needs.
- `loaders/from_vscode.lua` / `loaders/from_snipmate.lua` — the public
  `lazy_load()`/`load()` entry points; thin wrappers over `registry.enable()`.
- `body.lua` — everything between a body as written and a body
  `vim.snippet.expand()` accepts: variable resolution, line-ending collapse,
  `${0:…}` renumbering, and validation — which is the grammar *and* the two
  asserts inside expand() that the grammar does not cover.
- `completion.lua` — two layers: `matches()` selects and resolves, `items()`
  projects those onto `lsp.CompletionItem[]` and anchors the `textEdit` every
  source needs so a symbol-leading trigger is reachable. `zsnip.complete` uses
  `matches()` and the shared rules beneath `items()`, never `items()` itself.
- `lsp.lua` — the in-process language server that serves them. It must answer
  on the next tick, never inline: `vim.lsp.completion` calls it from inside
  'omnifunc', where textlock forbids `complete()`.
- `blink.lua` / `cmp.lua` — native completion sources. Neither may `require`
  its engine at module scope: they must load on a config that does not have it.
- `complete.lua` — a `'complete'` function source for Neovim's own completion.
  The only source that matches and expands for itself; the other three hand an
  `lsp.CompletionItem` to something that already knows what to do with it.
- `commands.lua` — the `:ZSnip` user command.
- `health.lua` — `:checkhealth zsnip` diagnostics.
- `util.lua` — the shared filesystem seam (`read_lines`, `read_json`,
  `files`): every read discovery and the parsers do goes through it, and
  every one of them is a `pcall`.
- `types.lua` — mostly annotations; the module itself is empty. Shared
  types (`zsnip.Snippet`, `zsnip.Config`, ...) live here, but per-source option
  classes (`zsnip.LspOpts`, `zsnip.CompleteOpts`, `zsnip.BlinkOpts`,
  `zsnip.CmpOpts`) live beside their source, and `zsnip.RegistryState` /
  `zsnip.RpcClient` live beside their consumers.

## Conventions & Patterns

- Code is self-documenting; add comments only where the logic is non-obvious —
  and when it is, say *why*, not what.
- `lua/` is kept type-clean (`lua-language-server --check`) and lint-clean
  (`luacheck`); both run in CI on every PR.
- Target PUC Lua 5.1 / LuaJIT — no `goto`, no 5.2+ stdlib.
- Neovim 0.13.0 is the floor (nightly, until 0.13 releases). Anything newer
  must be feature-detected.
- Nothing may read the filesystem at startup: discovery is a runtimepath-wide
  manifest scan, triggered by the first lookup of any filetype; parsing a
  package into snippets happens per filetype, lazily, after that.
- The *base install* must not pull `vim.lsp` in. `setup()` plus the two
  `lazy_load()`s are what every config runs, and after them the only
  `vim.lsp.*` module loaded is `body.lua`'s leaf `vim.lsp._snippet_grammar`.
  What buys that is `commands.lua` requiring `zsnip.completion` inside
  `expand()`/`list()` instead of at module scope, since `completion.lua` reads
  `vim.lsp.protocol` at module scope; `tests/integration_test.lua` pins it in a
  child Neovim, `package.loaded` being suite-wide. **Registering a source is
  where the rule stops**: `complete.lua`, `blink.lua` and `cmp.lua` each
  require `zsnip.completion` at module scope, so
  `require('zsnip.complete').enable()` loads `vim.lsp` and seven submodules.
  That is deliberate and is the boundary, not a violation — a config that asked
  for a completion source is going to complete. So module scope is fine in a
  source module and not on a path `setup()` reaches.
- Who hears about a failure depends on whose mistake it is. A mistake in the
  user's own config is said out loud, once, with `vim.notify` — `setup()`'s
  unknown keys, `:ZSnip`'s unknown subcommand. A problem in someone else's
  file on disk is silent and counted instead, for `:checkhealth` to report in
  aggregate: a pack has thousands of bodies and a message per bad one is
  unusable. Nothing raises out of a completion path — every read in `util.lua`
  is a `pcall`, and `lsp.lua` turns a raise into an error response rather than
  letting it skip the reply. `zsnip.add_snippets()` is the deliberate
  exception: it is config-time, but it shares `normalize()` with the packs and
  so is counted, not announced.
- Update `README.md`, `docs/` and `doc/zsnip.txt` alongside code changes.
