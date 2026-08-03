# API reference

Everything below is on `require('zsnip')` unless stated otherwise. Nothing
requires `setup()` to have run — it only stores options and creates `:ZSnip`.

## Loading

### `zsnip.setup(opts?)`

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `extend` | `table<string, string\|string[]>` | `{}` | Filetype inheritance |
| `global_filetype` | `string\|false` | `'all'` | Bucket every filetype inherits from |
| `max_items` | `integer` | `100` | Default cap for `completion_items()` and for `zsnip.complete`. The `blink`, `cmp` and `lsp` sources ask for an uncapped list, since the engine behind them filters and ranks it; `zsnip.complete` matches for itself and hands the result straight to the menu, so it is bounded by this |
| `documentation` | `boolean` | `true` | Attach the body as item documentation |
| `command` | `boolean` | `true` | Create the [`:ZSnip`](#the-zsnip-command) command |

### `zsnip.loaders.from_vscode.lazy_load(opts?)` / `.load(opts?)`
### `zsnip.loaders.from_snipmate.lazy_load(opts?)` / `.load(opts?)`

Register a loader. `lazy_load()` defers every read until a filetype asks for
it; `load()` scans and decodes everything up front, which costs a full pass
over the runtimepath.

| Option | Type | Meaning |
| --- | --- | --- |
| `paths` | `string\|string[]` | Directories to read in addition to the runtimepath |
| `include` | `string[]` | Only load these languages |
| `exclude` | `string[]` | Load every language except these |

A snipmate `path` is a directory containing `*.snippets` files, or per-filetype
directories of them.

A VSCode `path` is a directory containing a `package.json`, **or** one holding
loose snippet files the way VSCode keeps a user's own — so
`~/.config/Code/User/snippets` works as-is:

| File | Serves |
| --- | --- |
| `<language>.json` | the filetype it is named after |
| `*.code-snippets` | the languages each snippet's `scope` names, comma-separated; an unscoped entry reaches every filetype via `global_filetype` |
| `package.json` | still decides when present; files it names are not read again from the glob |

Loose files are only looked for under a configured `path`, never on the
runtimepath — a plugin there declares what it contributes in a `package.json`.

Calls merge, so two `lazy_load { paths = ... }` calls add up rather than
replacing each other.

## Registering snippets

### `zsnip.add_snippets(filetype, snippets)`

```lua
require('zsnip').add_snippets('lua', {
  { prefix = 'req', body = "local ${1:mod} = require '$1'", description = 'require' },
  { prefix = 'stamp', body = function() return os.date('%Y-%m-%d') end },
})
```

A snippet is `{ prefix, body, description? }`. `body` is LSP snippet syntax, or
a function returning it — called each time the snippet is used, with `nil` (or
a raise, or an unparseable result) meaning "skip this one".

Snippets added here come before file-loaded ones for the same filetype, so a
config can shadow a pack.

### `zsnip.filetype_extend(filetype, inherits)`

Give `filetype` everything registered for `inherits` (a filetype or a list of
them). Cycles are safe.

## Reading

### `zsnip.get(filetype?)` → `zsnip.Snippet[]`

Every snippet available to a filetype (its own, then inherited, then global),
in shadowing order. Defaults to the current buffer's filetype. Each entry
carries a `filetype` field naming where it came from.

### `zsnip.available()` → `table<string, zsnip.Snippet[]>`

Every filetype zsnip knows snippets for, mapped to them. Parses everything
discovered, so it is an introspection call, not a hot path.

Both this and `get()` hand back a list you may sort and filter freely. The
snippets *in* it are not copies, and deliberately so — an entry from here is
what `expand_snippet()` expects back.

### `zsnip.completion_items(opts?)` → `lsp.CompletionItem[]`

| Option | Type | Meaning |
| --- | --- | --- |
| `prefix` | `string` | Fuzzy-match triggers against this; unset returns everything |
| `filetype` | `string` | Defaults to the filetype of `bufnr` |
| `bufnr` | `integer` | Defaults to the current buffer |
| `limit` | `integer` | Overrides `max_items` |
| `documentation` | `boolean` | Overrides the configured default |
| `filter` | `fun(snippet): boolean` | Keep only the snippets this returns true for |

`filter` runs before matching and before `limit`, so the cap is spent on
snippets the caller will actually keep — which is what a source merging zsnip
into a menu that already holds LSP items wants.

Items carry `insertTextFormat = Snippet` and a resolved `insertText`, so a
client expands them with no further work. One item per trigger — the first
occurrence in shadowing order wins.

`sortText` is set only when `prefix` was given, i.e. when zsnip did the
ranking. Without it the order is whichever order the packs were read in, and
pinning a client to that would stop it applying the ranking it does better;
the three built-in sources rely on that and pass no `prefix`.

### `zsnip.resolve(body)` → `string`

Resolve the variables Neovim does not know in an arbitrary body. Applied
automatically to everything zsnip hands out; exposed for bodies that come from
somewhere else.

### `zsnip.reload()`

Forget everything read from disk; the next lookup rescans. Snippets added
through `add_snippets()` survive.

## Expanding

### `zsnip.match()` → `zsnip.Snippet?`

The snippet whose trigger ends at the cursor, longest trigger first. A trigger
starting with a keyword character has to start a word, so `x` does not fire in
the middle of `max`.

### `zsnip.expandable()` → `boolean`
### `zsnip.expand()` → `boolean`

Replace the trigger before the cursor with its snippet. Returns false when
there is nothing to expand.

### `zsnip.expand_snippet(snippet)` → `boolean`

Expand a snippet table at the cursor, trigger or not.

### `zsnip.expand_or_jump()` → `boolean`

Expand what is under the cursor, otherwise jump to the next tabstop.

### `zsnip.jump(direction)` / `zsnip.jumpable(direction)`
### `zsnip.active(filter?)` / `zsnip.stop()`

Thin wrappers over `vim.snippet`, so a config can bind one namespace. `jump()`
returns whether it moved.

## Serving

### `zsnip.start_lsp_server(opts?)`

Start an in-process language server that answers `textDocument/completion`
with the snippets of the requesting buffer's filetype, and attach it to every
buffer that gets a filetype. Idempotent.

| Option | Type | Meaning |
| --- | --- | --- |
| `name` | `string` | Client name as it appears in `:checkhealth lsp` (default `'zsnip'`) |
| `filetypes` | `string[]` | Attach only to these filetypes |
| `limit` | `integer` | Cap on items per response (default: uncapped) |
| `documentation` | `boolean` | Attach the body as item documentation |
| `filter` | `fun(snippet): boolean` | Keep only the snippets it returns true for |
| `trigger_characters` | `string[]` | Characters that make a client ask unprompted (default: none) |
| `completion` | `boolean\|table` | Wire each attached buffer up for `vim.lsp.completion`; a table is forwarded to its `enable()` |

`completion` is what makes an accepted item expand — the handler that reads
`insertTextFormat` is installed only by `vim.lsp.completion.enable()`, so
without it accepting a snippet inserts a literal `${1:mod}`. It is applied to
zsnip's own client only, never to your language servers.

The whole filetype is returned in one uncut list (`isIncomplete = false`),
which is what lets the client do its own filtering and ranking.

`require('zsnip.lsp').server(opts)` returns the `cmd` function on its own, for
wiring the server up by hand.

### The `:ZSnip` command

Created by `setup()` unless `command = false`.

| Subcommand | Does |
| --- | --- |
| `:ZSnip` / `:ZSnip expand` | Pick a snippet for the current filetype with `vim.ui.select` and expand it |
| `:ZSnip list` | Open a scratch buffer listing every snippet the filetype has, with the filetype each came from — which inheritance and the global bucket otherwise make hard to eyeball |
| `:ZSnip reload` | Forget everything read from disk; the next lookup rescans. Snippets added through `add_snippets()` survive |

### `zsnip.blink`

A blink.cmp source module — `{ module = 'zsnip.blink' }`. Its provider `opts`
accept `limit`, `documentation` and `filter`, forwarded to
`completion_items()`. Requires nothing from blink itself.

### `zsnip.cmp`

An nvim-cmp source. `require('zsnip.cmp').register(opts)` registers it under
the name `zsnip`; `opts` are the same three. nvim-cmp is required by
`register()` only, so the module loads without it.

### `zsnip.complete`

A source for Neovim's own insert-mode completion, through `'complete'`.
Requires Neovim 0.12. Needs no completion plugin and no LSP client.

| Function | Does |
| --- | --- |
| `require('zsnip.complete').enable(opts?)` | Append zsnip to `'complete'` and install the `CompleteDone` handler that expands what is accepted. Idempotent; `opts` are the same three, plus `complete = false` |
| `require('zsnip.complete').disable()` | Remove both again |
| `require('zsnip.complete').source()` | The entry to put in `'complete'` yourself; append `^{count}` to cap it |
| `require('zsnip.complete').completefunc(findstart, base)` | The raw [`complete-functions`](https://neovim.io/doc/user/insert.html#complete-functions) implementation, for putting in `'complete'` yourself |

`enable()` does not set `'autocomplete'` — CTRL-N reaches the source either
way, and whether the menu opens by itself is your decision.

If you set `'complete'` yourself — a config that owns the option, or one that
caps the source — pair it with `enable({ complete = false })`, which installs
the `CompleteDone` handler and leaves the option alone. `enabled()` and
`disable()` recognise the entry with or without a `^{count}` cap, so a capped
setup is neither appended to twice nor missed by `:checkhealth`.

Unlike the other three sources this one matches (`{ refresh = 'always' }`, so
zsnip is re-asked on every change) and expands (nothing else on this path
knows what a snippet body is) for itself. The replaced range is the whole
non-blank run before the cursor, since real triggers mix words and symbols —
`console.log`, `<div`, `#!/usr/bin/env`.

Use exactly one of these four — see [integrations](integrations.md).
