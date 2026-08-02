<h1 align="center">zsnip.nvim</h1>
<div align="center">
  <img src="https://img.shields.io/github/actions/workflow/status/zuqini/zsnip.nvim/tests.yml?style=for-the-badge&logo=githubactions&logoColor=white&label=tests&labelColor=1e1b4b"> <img src="https://img.shields.io/github/issues/zuqini/zsnip.nvim?style=for-the-badge&logo=github&logoColor=white&color=8b5cf6&labelColor=1e1b4b"> <img src="https://img.shields.io/github/last-commit/zuqini/zsnip.nvim?style=for-the-badge&logo=neovim&color=8b5cf6&labelColor=1e1b4b"> <img src="https://img.shields.io/github/license/zuqini/zsnip.nvim?style=for-the-badge&logo=opensourceinitiative&logoColor=white&color=8b5cf6&labelColor=1e1b4b">
</div>

<p align="center">Snippet collections for Neovim's built-in snippet engine — the loading, not a second engine.</p>

**[Why zsnip?](#why-zsnip)** | **[Quick start](#quick-start)** | **[Completion](#wiring-it-into-a-completion-menu)** | **[API](docs/api.md)** | **[Integrations](docs/integrations.md)**

## Why zsnip?

Neovim ships `vim.snippet`: it expands an LSP snippet body, runs the session,
and moves between tabstops. What it does not ship is everything around that —
finding the snippet packages on your runtimepath, reading the two formats they
come in, deciding which ones a filetype gets, and handing them to a completion
menu.

Every established option answers that by bringing its own engine along:
LuaSnip, vim-vsnip, nvim-snippy and mini.snippets each re-implement expansion
and session management. zsnip does not. It loads snippets and hands the body
to `vim.snippet.expand()`, which means the engine running your snippets is the
one Neovim maintains.

What that leaves zsnip to do, it does completely:

- **Both formats.** VSCode packages with a `package.json` manifest
  (rafamadriz/friendly-snippets and anything shaped like it) *and* snipmate
  `.snippets` files, including their `extends` lines.
- **The variables Neovim doesn't resolve.** Core knows the `TM_*` set and
  turns every other variable into a tabstop holding its own name — which is
  why an unpatched `copyright` snippet inserts a literal `CURRENT_YEAR`.
  zsnip resolves the date, workspace, comment-marker, clipboard, `UUID` and
  `RANDOM` families before the body reaches the engine.
- **Bodies core cannot parse.** ~4% of friendly-snippets' bodies fail the LSP
  snippet grammar. Expanding one raises *after* the completion engine has
  deleted the word you typed, so it takes the word with it. zsnip drops them
  on load instead.
- **`${0:text}`.** Core treats `$0` strictly as the exit point, so a
  placeholder sitting on it lands in the buffer unreachable — and a body whose
  only tabstop is `$0` gets no session at all. zsnip renumbers it past the
  last real tabstop.
- **One line to any completion menu.** An in-process LSP server serves the
  snippets, so blink.cmp, nvim-cmp and `vim.lsp.completion` pick them up with
  no per-engine source to install or maintain.

## Requirements

- Neovim 0.11.0+
- A snippet collection, e.g. [friendly-snippets](https://github.com/rafamadriz/friendly-snippets)

## Installation

```lua
-- vim.pack
vim.pack.add({
  'https://github.com/zuqini/zsnip.nvim',
  'https://github.com/rafamadriz/friendly-snippets',
})

-- lazy.nvim / zpack.nvim
{ 'zuqini/zsnip.nvim', dependencies = { 'rafamadriz/friendly-snippets' } }
```

## Quick start

```lua
require('zsnip').setup()

require('zsnip.loaders.from_vscode').lazy_load()
require('zsnip.loaders.from_snipmate').lazy_load()

-- Offer them in every completion menu that speaks LSP.
require('zsnip').start_lsp_server()
```

Nothing is read at startup. A package is scanned and decoded the first time a
filetype it covers is opened, and the runtimepath is re-checked on every
lookup, so a plugin that loads on a filetype and brings its own snippets is
picked up the moment it arrives.

## Wiring it into a completion menu

The in-process LSP server is the recommended route — it works for every engine
at once, including Neovim's own:

```lua
require('zsnip').start_lsp_server()

-- Built-in completion (no plugin at all):
vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args) vim.lsp.completion.enable(true, args.data.client_id, args.buf) end,
})
```

blink.cmp and nvim-cmp consume it through their existing LSP source — see
[docs/integrations.md](docs/integrations.md) for per-engine notes, and for
building your own source with `completion_items()`.

## Snippets from Lua

```lua
require('zsnip').add_snippets('lua', {
  { prefix = 'req', body = "local ${1:mod} = require '$1'", description = 'require' },
  { prefix = 'stamp', body = function() return os.date('%Y-%m-%d') end },
})

-- Available everywhere:
require('zsnip').add_snippets('all', {
  { prefix = 'todo', body = '$LINE_COMMENT TODO ($CURRENT_YEAR-$CURRENT_MONTH-$CURRENT_DATE): $0' },
})
```

A function body is called each time the snippet is used, which covers a body
that depends on the buffer or the moment. It cannot react to what you type
*into* a tabstop — `vim.snippet` owns the session and offers no hook for that,
so LuaSnip's dynamic nodes have no equivalent here.

## Filetype inheritance

```lua
require('zsnip').setup({
  extend = { typescriptreact = { 'typescript', 'javascript' } },
})

-- or later
require('zsnip').filetype_extend('svelte', { 'html' })
```

Every filetype also inherits the `all` bucket, and snipmate's `extends` lines
are honoured as written.

## Keymaps

zsnip installs none — every completion engine already has an opinion about
`<Tab>`. Bind what you want:

```lua
vim.keymap.set({ 'i', 's' }, '<C-k>', function() require('zsnip').expand_or_jump() end)
vim.keymap.set({ 'i', 's' }, '<C-j>', function() require('zsnip').jump(-1) end)
```

## Configuration

```lua
require('zsnip').setup({
  extend = {},              -- filetype -> filetypes it inherits from
  global_filetype = 'all',  -- bucket every filetype inherits; false to disable
  max_items = 100,          -- default cap for completion_items()
  documentation = true,     -- attach the body as item documentation
  command = true,           -- create :ZSnip
})
```

## Commands

| Command | What it does |
| --- | --- |
| `:ZSnip` | Pick a snippet for the current filetype and expand it |
| `:ZSnip list` | Show every snippet the current filetype has, and where each came from |
| `:ZSnip reload` | Forget everything read from disk and rescan |

`:checkhealth zsnip` reports the engine, the registered loaders and how much
was actually found.

## Coming from LuaSnip

The loader and registry API is deliberately shaped like LuaSnip's, so most
configs move over by renaming the module:

| LuaSnip | zsnip |
| --- | --- |
| `require('luasnip.loaders.from_vscode').lazy_load()` | `require('zsnip.loaders.from_vscode').lazy_load()` |
| `require('luasnip.loaders.from_snipmate').lazy_load()` | `require('zsnip.loaders.from_snipmate').lazy_load()` |
| `ls.add_snippets(ft, ...)` | `zsnip.add_snippets(ft, ...)` |
| `ls.filetype_extend(ft, ...)` | `zsnip.filetype_extend(ft, ...)` |
| `ls.expand_or_jump()` / `ls.jumpable()` | `zsnip.expand_or_jump()` / `zsnip.jumpable()` |
| snippet node DSL (`s`, `i`, `t`, `f`, `c`, `d`) | not supported — bodies are LSP snippet syntax, or a function returning it |

## License

MIT
