# Integrations

zsnip offers snippets four ways. Pick **one** — a native source for your
engine, the LSP server, or Neovim's own completion. Running two offers every
snippet twice.

| | Use when | Trade-off |
| --- | --- | --- |
| `zsnip.blink` | You use blink.cmp | Snippets stay their own provider, so blink's `score_offset`, `min_keyword_length` and kind styling apply to them |
| `zsnip.cmp` | You use nvim-cmp | Same, for nvim-cmp's source config |
| `zsnip.complete` | You want no completion plugin at all | Nothing to install and nothing to start, and `'complete'` caps each source separately — but zsnip has to match and expand for itself, so it is the one path with its own code on the accept |
| `zsnip.start_lsp_server()` | Anything else | One call covers every LSP-speaking menu, but the items arrive folded in with your language servers' |

The last two need no completion plugin, and `zsnip.complete` needs no LSP
client either.

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

## Neovim's built-in completion (`'complete'`)

```lua
require('zsnip.complete').enable()

vim.o.autocomplete = true            -- optional; CTRL-N reaches it either way
vim.o.completeopt = 'menu,popup,noinsert,fuzzy'
```

A function source in `'complete'`, which `'autocomplete'` drives as you type.
No completion plugin, and unlike the LSP server, no LSP client either —
`enable()` appends one entry to `'complete'` and installs two handlers: a
`CompleteDone` expander, which only fires on an accepted item — `<C-y>`, or a
mapping that sends it; `<CR>`, `<Space>` and `<Tab>` are *discard* in Vim, same
as a typed character or `<Esc>`, and never expand — and a `CompleteChanged`
stylist for the preview.
Because `'complete'` is buffer-local, `enable()` appends to the global default
and to every buffer already open, not just the current one, so lazy-loading
it on `InsertEnter` still reaches buffers that were open before that fired.

Snippets then rank next to buffer words in a single menu, and each source can
be capped on its own. Setting `'complete'` yourself means `enable()` should not
also append to it, so pass `complete = false` and it installs only the
handlers:

```lua
vim.o.complete = ".^5,w," .. require('zsnip.complete').source() .. '^10'
require('zsnip.complete').enable({ complete = false })
```

`enabled()` and `disable()` read the entry with or without its `^{count}`, so a
capped setup is still recognised — by `:checkhealth zsnip` too.

`enable()` takes the same `limit`, `documentation` and `filter` as the other
sources. It deliberately does not touch `'autocomplete'`: whether the menu
opens by itself is your decision, not zsnip's. With it on, an empty base
returns nothing — the whole filetype is not a useful menu after every space,
and Vim's own `.` source shows nothing there either; a manual CTRL-N with
`'autocomplete'` off still lists the lot.

The preview shows exactly what `vim.lsp.completion` would render for the same
snippet — the description as prose, then the body syntax-highlighted — so the
menu row stays the trigger and its kind alone. The styling reaches the float
that `popup` in `'completeopt'` opens (the `preview` split shows the markdown
raw), and comes back off when selection moves to another source's plain item,
since one menu reuses the same float — except onto an item served by
`vim.lsp.completion`, which core restyles on its own schedule and zsnip leaves
alone; it comes back off as usual on the next plain item. Pass
`description_style = 'classic'` to keep the description in the menu row
instead, visible without selecting, with a plain body in the preview.

Two things are specific to this path:

- **zsnip does the matching.** The other three hand the whole filetype over
  and let the engine filter; here the completion function is given the text to
  match and returns `{ refresh = 'always' }`, so it is re-asked on every
  change and stays in control. That means the fuzzy match is zsnip's, and
  without `fuzzy` in `'completeopt'` Vim narrows the result again by its own
  plain-keyword rule — so a hit whose `word` is not a prefix of the keyword
  under the cursor (`clog` for `console.log`, `rq` for `req`) is filtered back
  out and never shown at all.
- **zsnip does the expanding.** Nothing else on this path knows what a snippet
  body is, so `enable()`'s `CompleteDone` handler replaces the accepted
  trigger and calls `vim.snippet.expand()`. The range it replaces is the whole
  non-blank run before the cursor, because a third of real triggers mix words
  and symbols — `console.log`, `<div`, `#!/usr/bin/env`. A trigger typed after
  a bracket still works: `(req` keeps the `(` and expands `req`.

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
-- Only needed for autotrigger. vim.lsp.completion asks unprompted on the
-- characters a server names, and a snippet trigger can begin with any of
-- them: `2x1table` and `#!` are both real friendly-snippets triggers, so a
-- letters-only list would leave the first firing a keystroke late and the
-- second never firing at all. Which items are offered, and what each replaces,
-- is settled by the textEdit zsnip sends -- not by this list.
local triggers = {}
for byte = 33, 126 do
  triggers[#triggers + 1] = string.char(byte)
end

require('zsnip').start_lsp_server({
  trigger_characters = triggers,
  completion = { autotrigger = true },
})
```

`completion` is what makes an accepted item expand. Attaching a client is not
enough: the handler that reads `insertTextFormat` lives in
`vim.lsp.completion` and is installed only by its `enable()`, so without this
the items arrive and accepting one puts a literal `${1:mod}` in your buffer.
Pass `true` for the defaults, or a table forwarded to
`vim.lsp.completion.enable()` — `autotrigger`, `convert`, `cmp`.

It is applied to zsnip's own client only. Enabling it for every client, which
a hand-written `LspAttach` hook does unless it checks, would take over
completion for your language servers as a side effect of asking for snippets:

```lua
-- Equivalent to `completion = { autotrigger = true }`, and the check is the
-- part that is easy to leave out.
vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if client and client.name == 'zsnip' then
      vim.lsp.completion.enable(true, client.id, args.buf, { autotrigger = true })
    end
  end,
})
```

`start_lsp_server()` also takes `limit`, `documentation` and `filter`, which it
forwards to `completion_items()` — the same three the native sources accept.

`vim.lsp.completion` expands snippet items itself, and `vim.snippet` runs the
session — nothing else is involved. Without `autotrigger`, drop
`trigger_characters` and ask for the menu with `<C-x><C-o>`.

`require('zsnip').stop_lsp_server()` undoes all of it — the autocmd and the
clients it attached — which `:checkhealth zsnip` then reports accurately.

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

Passing `prefix` makes zsnip fuzzy-match and rank, and it then sets `sortText`
to pin the order. Omit it to get the whole filetype unranked and with no
`sortText`, which is what you want if your menu ranks for itself.

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

A directory named this way needs no `package.json`. It is read the way VSCode
reads its own user-snippets folder, so you can point one at
`~/.config/Code/User/snippets` and get what is already there:

| File | Serves |
| --- | --- |
| `<language>.json` | the filetype the file is named after — `python.json`, `lua.json` |
| `*.code-snippets` | whichever languages each snippet's `scope` names, comma-separated; an entry with no `scope` goes to every filetype, through `global_filetype` |
| `package.json` | if one is present it still decides, and the files it names are not read a second time from the glob |

`scope` decides who a file serves in the `*.code-snippets` row alone — the
other two take their filetype from a filename and from the manifest, and a
`scope` key inside one of those is ignored rather than filtered on. Real packs
carry TextMate scopes (`source.lua`) there harmlessly, and filtering on them
drops most of what the pack serves.

Loose files are only looked for under a `paths` directory you configured.
Plugins on the runtimepath declare what they contribute in a `package.json`,
and globbing every plugin directory for stray JSON would turn up a great deal
that is not a snippet.

Either loader follows symlinks under a `paths` directory: a snippet file that
is one is read like any other, so a stow or dotfiles setup that routes every
file through a link is found rather than passed over. A symlinked directory is
descended into by the snipmate loader alone, whose per-filetype directories sit
below the one you configured; a VSCode loose file has to sit in the configured
directory itself, link or not. A link pointing at nothing is skipped.
