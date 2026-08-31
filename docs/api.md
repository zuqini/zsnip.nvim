# API reference

Everything below is on `require('zsnip')` unless stated otherwise. Nothing
requires `setup()` to have run — it only stores options and creates `:ZSnip`.

## Loading

### `zsnip.setup(opts?)`

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `extend` | `table<string, string\|string[]>` | `{}` | Filetype inheritance |
| `global_filetype` | `string\|false` | `'all'` | Bucket every filetype inherits from. This is a bucket name, not a filetype — naming it after a real one (`'lua'`) is unsupported |
| `max_items` | non-negative integer, or `math.huge` for no cap | `100` | Default cap for `completion_items()` and for `zsnip.complete`. The `blink`, `cmp` and `lsp` sources ask for an uncapped list, since the engine behind them filters and ranks it; `zsnip.complete` matches for itself and hands the result straight to the menu, so it is bounded by this |
| `documentation` | `boolean` | `true` | Attach the body and description to each item |
| `command` | `boolean` | `true` | Create the [`:ZSnip`](#the-zsnip-command) command |

An unknown key, or a known one of the wrong type, is reported with
`vim.notify` and dropped — the rest of the config still applies, and the
default is used in its place. So is a known key whose value it cannot use
(`global_filetype = true`, a fractional or negative `max_items`). `command =
false` removes an existing `:ZSnip` as well as declining to create one, so a
later `setup()` can undo an earlier one.

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
directories of them. `_.snippets` — snipmate's convention for "every
filetype", which honza/vim-snippets ships one of — is filed under
`global_filetype` instead of a filetype literally named `_`, and dropped
entirely when `global_filetype` is `false`. `${VISUAL}`/`$VISUAL`, snipmate's
own name for the selected text, is rewritten to `TM_SELECTED_TEXT` on the way
in. A VSCode pack's spelling of "every filetype" is the language `all` — in a
manifest's `language` list or a `.code-snippets` entry's `scope` — and it is
filed under `global_filetype`, or dropped, the same way.

A VSCode `path` is a directory containing a `package.json`, **or** one holding
loose snippet files the way VSCode keeps a user's own — so
`~/.config/Code/User/snippets` works as-is:

| File | Serves |
| --- | --- |
| `<language>.json` | the filetype it is named after |
| `*.code-snippets` | the languages each snippet's `scope` names, comma-separated; an unscoped entry reaches every filetype via `global_filetype` |
| `package.json` | still decides when present; files it names are not read again from the glob |

`scope` decides which languages a file serves in the `*.code-snippets` row
alone. A `<language>.json` takes its filetype from its filename and a
manifest-declared file takes its from the manifest; VSCode gives `scope` no
meaning in either, so a `scope` key inside one of those is ignored rather than
filtered on. This is deliberate, not an oversight: real packs carry TextMate
scopes (`source.lua`, `text.html`) in exactly those files, where they are
harmless — filtering on them drops most of what the pack serves.

Loose files are only looked for under a configured `path`, never on the
runtimepath — a plugin there declares what it contributes in a `package.json`.

Comments and trailing commas are accepted in any of these. VSCode generates
every user snippet file with a `//` header block, and strict JSON would reject
the file — and every snippet in it — for that alone.

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

Every snippet available to a filetype (its own, then inherited, then each
dot-separated component of a dotted filetype, then global), in shadowing
order. A dotted filetype such as `javascript.glimmer` — which Neovim assigns
itself for some filetypes, and which users set for others, e.g.
`yaml.ansible` — gets everything registered for `javascript` and `glimmer`
too. Defaults to the current buffer's filetype. Each entry carries a
`filetype` field naming where it came from.

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
| `position` | `lsp.Position` | Cursor the response is anchored to; defaults to the real one when `bufnr` is the current buffer |
| `limit` | non-negative integer, or `math.huge` for no cap | Overrides `max_items` |
| `documentation` | `boolean` | Overrides the configured default |
| `filter` | `fun(snippet): boolean` | Keep only the snippets this returns true for |

`filter` runs before matching and before `limit`, so the cap is spent on
snippets the caller will actually keep — which is what a source merging zsnip
into a menu that already holds LSP items wants.

Items carry `insertTextFormat = Snippet` and a resolved `insertText`, so a
client expands them with no further work. One item per trigger — the first
occurrence in shadowing order wins.

The description travels in `documentation` — markdown, as prose above the
fenced body — never in `detail`, which clients (`vim.lsp.completion` included)
fence as code in the buffer's filetype.

They also carry a `textEdit` naming the span to replace: the whole non-blank
run before the cursor. Left to pick that span itself a client picks the keyword
before the cursor, which is not what a trigger is — `<div` would be filtered
out for not matching the prefix `div`, and `#!` would be inserted in front of
its own expansion rather than over it. Every item in a response shares one
span, because `vim.lsp.completion` filters the whole list against the lowest
start it is given.

Where the run holds text the trigger does not account for — the `(` of `(req` —
that text is inside the replaced span, so it goes back in front of the body
(escaped, not as snippet syntax) in `insertText`/`newText` regardless. It only
also goes into `filterText` when some suffix of the run actually matched the
trigger (`(req` against `req`); left out otherwise, or a client that filters
by prefix alone would offer every snippet after a bare `(`. How much of the
run is buffer text is decided per legal start of the run, longest first: the
first one the trigger fuzzy-matches from — whether that start began the
trigger outright or only fuzzy-matched it — is where the head ends. `(c.log`
against `console.log` keeps `(` as head, since the match starts one byte in,
at `c.log`; `c.c` against `console.clear` keeps nothing, since the match
already starts at the run's first byte.

`textEdit` needs a cursor to anchor to. There is none when `bufnr` is not the
current buffer and no `position` was given; the items are then plain, as
before.

`sortText` is set only when `prefix` was given, i.e. when zsnip did the
ranking. Without it the order is whichever order the packs were read in, and
pinning a client to that would stop it applying the ranking it does better;
the three LSP-shaped sources rely on that and pass no `prefix`.

### `zsnip.resolve(body)` → `string`

Resolve the variables Neovim does not know in an arbitrary body. Applied
automatically to everything zsnip hands out; exposed for bodies that come from
somewhere else.

All four spellings are handled: `$VAR`, `${VAR}`, `${VAR:default}` and
`${VAR/regex/format/}`. The last two collapse to the plain value — the default
because we have one (`vim.snippet.expand()` discards it anyway and inserts the
variable's *name*), the transform because Neovim implements none, so
`${TM_FILENAME/(.*)\\..*/$1/}` already inserts the whole filename today.

A name zsnip does not know is left exactly as written, for `vim.snippet` to
deal with — plenty of bodies contain a `$NAME` that is text.

### `zsnip.reload()`

Forget everything read from disk; the next lookup rescans. Snippets added
through `add_snippets()` survive.

### `zsnip.version` → `string`

The plugin's own version, e.g. `'0.1.0'`. `:checkhealth zsnip` reports it.

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
with the snippets of the requesting buffer's filetype, and attach it to the
buffers that qualify. Idempotent: calling it again stops whatever a
previous call started, clients included, before starting the new one.

A buffer holds the client when it has a filetype, has no `'buftype'` (prompts,
terminals, `:help`, ...), and, if `filetypes` is given, its filetype or one of
a dotted filetype's dot-separated components is on the list. This gate re-runs
on every `FileType`, so a buffer that stops qualifying loses the client it
already has, not only one that never gets one.

| Option | Type | Meaning |
| --- | --- | --- |
| `name` | `string` | Client name as it appears in `:checkhealth vim.lsp` (default `'zsnip'`) |
| `filetypes` | `string[]` | Attach only to these filetypes, or a dotted one's dot-separated components (`javascript` also attaches to `javascript.glimmer`) |
| `limit` | non-negative integer, or `math.huge` for no cap | Cap on items per response (default: uncapped) |
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

### `zsnip.stop_lsp_server()`

Stop it again: the autocmd that attaches it goes, and so do the clients it
attached. Idempotent, and the exact undo of `start_lsp_server()`.

| Function | Does |
| --- | --- |
| `require('zsnip.lsp').started()` | Whether the attaching autocmd is installed |
| `require('zsnip.lsp').running()` | Whether a client is actually up. Registered is not the same as serving: a `filetypes` list that excluded every buffer opened so far, or a `:LspStop`, leaves the autocmd in place with nothing behind it |
| `require('zsnip.lsp').server(opts)` | The `cmd` function on its own, for wiring the server up by hand |

The server answers on the next tick rather than inline. Being in-process makes
a synchronous reply possible and it is wrong: `vim.lsp.completion` drives
`'omnifunc'`, which returns `-2` to say "the items come later" precisely
because textlock forbids `complete()` while the option is being evaluated.

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
Needs no completion plugin and no LSP client. `opts` are the same `limit`,
`documentation` and `filter` as the other three — except that `limit` defaults
to `max_items` here rather than to uncapped, since nothing downstream trims
what this source returns — plus three of its own: `complete = false` when you
set `'complete'` yourself, `expand` to replace `vim.snippet.expand()` as what
turns the accepted body into a session, and `description_style = 'classic'`
to keep the description in the menu row with a plain-body preview instead of
the default LSP-style rendering.

| Function | Does |
| --- | --- |
| `require('zsnip.complete').enable(opts?)` | Append zsnip to `'complete'` and install the handlers — a `CompleteDone` expander and a `CompleteChanged` preview stylist. Idempotent; `opts` as above |
| `require('zsnip.complete').disable()` | Remove the entry and the handlers again |
| `require('zsnip.complete').source()` | The entry to put in `'complete'` yourself; append `^{count}` to cap it |
| `require('zsnip.complete').enabled(bufnr?)` | Whether zsnip is in `'complete'` for `bufnr` (default the current buffer), with or without a `^{count}` cap |
| `require('zsnip.complete').completefunc(findstart, base)` | The raw [`complete-functions`](https://neovim.io/doc/user/insert.html#complete-functions) implementation. Pair it with `enable({ complete = false })`, which installs the handlers without touching the option — without that, accepting an item inserts a literal `${1:mod}` |

`enable()` does not set `'autocomplete'` — CTRL-N reaches the source either
way, and whether the menu opens by itself is your decision. With it on, an
empty base returns nothing: the whole filetype is not a useful menu after
every space, and Vim's own `.` source shows nothing there either. A manual
CTRL-N with `'autocomplete'` off still lists the lot.

If you set `'complete'` yourself — a config that owns the option, or one that
caps the source — pair it with `enable({ complete = false })`, which installs
the handlers and leaves the option alone. `enabled()` and
`disable()` recognise the entry with or without a `^{count}` cap, so a capped
setup is neither appended to twice nor missed by `:checkhealth`.

Unlike the other three sources this one matches (`{ refresh = 'always' }`, so
zsnip is re-asked on every change) and expands (nothing else on this path
knows what a snippet body is) for itself. The replaced range is the whole
non-blank run before the cursor, since real triggers mix words and symbols —
`console.log`, `<div`, `#!/usr/bin/env`.

Use exactly one of these four — see [integrations](integrations.md).
