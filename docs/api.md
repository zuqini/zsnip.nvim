# API reference

Everything below is on `require('zsnip')` unless stated otherwise. Nothing
requires `setup()` to have run — it only stores options and creates `:ZSnip`.

## Loading

### `zsnip.setup(opts?)`

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `extend` | `table<string, string\|string[]>` | `{}` | Filetype inheritance |
| `global_filetype` | `string\|false` | `'all'` | Bucket every filetype inherits from |
| `max_items` | `integer` | `100` | Default cap for `completion_items()` |
| `documentation` | `boolean` | `true` | Attach the body as item documentation |
| `command` | `boolean` | `true` | Create the `:ZSnip` command |

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

A VSCode `path` is a directory containing a `package.json`. A snipmate `path`
is a directory containing `*.snippets` files, or per-filetype directories of
them.

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
| `trigger_characters` | `string[]` | Characters that make a client ask unprompted (default: none) |

The whole filetype is returned in one uncut list (`isIncomplete = false`),
which is what lets the client do its own filtering and ranking.

`require('zsnip.lsp').server(opts)` returns the `cmd` function on its own, for
wiring the server up by hand.

### `zsnip.blink`

A blink.cmp source module — `{ module = 'zsnip.blink' }`. Its provider `opts`
accept `limit`, `documentation` and `filter`, forwarded to
`completion_items()`. Requires nothing from blink itself.

### `zsnip.cmp`

An nvim-cmp source. `require('zsnip.cmp').register(opts)` registers it under
the name `zsnip`; `opts` are the same three. nvim-cmp is required by
`register()` only, so the module loads without it.

Use one of these *or* `start_lsp_server()`, not both — see
[integrations](integrations.md).
