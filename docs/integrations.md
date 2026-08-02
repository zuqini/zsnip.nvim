# Integrations

zsnip offers snippets three ways. Pick **one** — a native source for your
engine, or the LSP server. Running both offers every snippet twice.

| | Use when | Trade-off |
| --- | --- | --- |
| `zsnip.blink` | You use blink.cmp | Snippets stay their own provider, so blink's `score_offset`, `min_keyword_length` and kind styling apply to them |
| `zsnip.cmp` | You use nvim-cmp | Same, for nvim-cmp's source config |
| `zsnip.start_lsp_server()` | Anything else, or nothing at all | One call covers every LSP-speaking menu, but the items arrive folded in with your language servers' |

## blink.cmp

```lua
require('blink.cmp').setup({
  -- 'default' is blink's own vim.snippet wrapper -- the engine zsnip loads for.
  snippets = { preset = 'default' },
  sources = {
    default = { 'lsp', 'path', 'zsnip', 'buffer' },
    providers = {
      zsnip = {
        name = 'zsnip',
        module = 'zsnip.blink',
        -- opts are optional; all three are passed to completion_items()
        opts = { documentation = true },
      },
    },
  },
})
```

Leave blink's own built-in `snippets` source out of `default`: it reads the
same VSCode packs, so listing both offers everything twice — and it cannot see
the snipmate ones at all.

The source requires nothing from blink. It is a table with `new`, `enabled`
and `get_completions`, returning plain LSP completion items, so there is no
blink internal for it to drift against.

## nvim-cmp

```lua
require('zsnip.cmp').register({ documentation = true })

require('cmp').setup({
  snippet = { expand = function(args) vim.snippet.expand(args.body) end },
  sources = { { name = 'nvim_lsp' }, { name = 'zsnip' } },
})
```

The `snippet.expand` line is what makes nvim-cmp use Neovim's engine rather
than asking for LuaSnip. `register()` is the only thing that requires nvim-cmp,
so the module loads fine on a config without it.

## The LSP server

```lua
require('zsnip').start_lsp_server()
```

An in-process language server answering `textDocument/completion` with the
snippets of the requesting buffer's filetype. Nothing is spawned and nothing
leaves the process.

### Built-in completion

No completion plugin needed:

```lua
-- vim.lsp.completion only asks on the characters a server names, and a
-- snippet trigger can begin with any of them: `2x1table` and `#!` are both
-- real friendly-snippets triggers, so a letters-only list would leave the
-- first firing a keystroke late and the second never firing at all.
local triggers = {}
for byte = 33, 126 do
  triggers[#triggers + 1] = string.char(byte)
end

require('zsnip').start_lsp_server({ trigger_characters = triggers })

vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    vim.lsp.completion.enable(true, args.data.client_id, args.buf, { autotrigger = true })
  end,
})
```

`start_lsp_server()` also takes `limit`, `documentation` and `filter`, which it
forwards to `completion_items()` — the same three the native sources accept.

`vim.lsp.completion` expands snippet items itself, and `vim.snippet` runs the
session — nothing else is involved. Without `autotrigger`, drop
`trigger_characters` and ask for the menu with `<C-x><C-o>`.

blink.cmp and nvim-cmp can consume the server too, through their existing LSP
source, if you would rather not add a provider. The cost is that snippets are
no longer separable from your language servers' items in that engine's config.

## Building your own source

`completion_items()` returns plain `lsp.CompletionItem[]`, already resolved and
marked as snippets:

```lua
local items = require('zsnip').completion_items({
  prefix = keyword_under_cursor,
  bufnr = bufnr,
  limit = 20,
  documentation = false, -- let the popup preview the expanded body instead
  filter = function(snippet) return not already_offered[snippet.prefix] end,
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
