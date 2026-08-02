# Integrations

zsnip offers snippets two ways: as a language server every engine already
knows how to talk to, or as completion items you place yourself.

## The LSP server (recommended)

```lua
require('zsnip').start_lsp_server()
```

One call covers every engine at once, and there is no per-engine source to
keep working as that engine's API moves.

### Built-in completion

No completion plugin needed:

```lua
-- vim.lsp.completion decides when to ask from the server's trigger
-- characters, so a keyword-triggered source has to name them.
require('zsnip').start_lsp_server({
  trigger_characters = vim.split('abcdefghijklmnopqrstuvwxyz_', ''),
})

vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    vim.lsp.completion.enable(true, args.data.client_id, args.buf, { autotrigger = true })
  end,
})
```

`vim.lsp.completion` expands snippet items itself, and `vim.snippet` runs the
session — nothing else is involved. Without `autotrigger`, drop
`trigger_characters` and ask for the menu with `<C-x><C-o>`.

### blink.cmp

The snippets arrive through blink's existing `lsp` source. Leave blink's own
snippet preset on `default` (it uses `vim.snippet`), and turn off its built-in
`snippets` source so packs are not offered twice:

```lua
require('blink.cmp').setup({
  snippets = { preset = 'default' },
  sources = { default = { 'lsp', 'path', 'buffer' } },
})
```

### nvim-cmp

Same idea — `nvim_lsp` carries them, and `vim.snippet` expands them:

```lua
require('cmp').setup({
  snippet = { expand = function(args) vim.snippet.expand(args.body) end },
  sources = { { name = 'nvim_lsp' } },
})
```

## Building your own source

`completion_items()` returns plain `lsp.CompletionItem[]`, already resolved and
marked as snippets:

```lua
local items = require('zsnip').completion_items({
  prefix = keyword_under_cursor,
  bufnr = bufnr,
  limit = 20,
  documentation = false, -- let the popup preview the expanded body instead
})
```

Feed them to `vim.fn.complete()`, to `vim.lsp.completion`'s handler, or into
whatever menu you assemble yourself.

## Without a completion menu at all

Bind the trigger expansion directly:

```lua
vim.keymap.set({ 'i', 's' }, '<C-k>', function() require('zsnip').expand_or_jump() end)
vim.keymap.set({ 'i', 's' }, '<C-j>', function() require('zsnip').jump(-1) end)
```

`expand_or_jump()` expands the trigger before the cursor when there is one and
moves to the next tabstop otherwise.

## Snippet packs

Anything on the runtimepath is found automatically:

- **VSCode packs** — a `package.json` with `contributes.snippets`, e.g.
  [friendly-snippets](https://github.com/rafamadriz/friendly-snippets).
- **snipmate packs** — `snippets/<filetype>.snippets` or
  `snippets/<filetype>/<name>.snippets`, e.g.
  [pkl-neovim](https://github.com/apple/pkl-neovim) and
  [vim-snippets](https://github.com/honza/vim-snippets).

Your own snippets need no plugin — point a loader at a directory:

```lua
require('zsnip.loaders.from_vscode').lazy_load({ paths = vim.fn.stdpath('config') .. '/snippets' })
```
