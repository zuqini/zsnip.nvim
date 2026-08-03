---Type declarations for ZSnip.nvim.
---
---Loaded for its annotations only; the module itself is empty.

---A single expandable snippet.
---
---`body` is LSP snippet syntax (|vim.snippet.expand()| parses it). A function
---body is called when the snippet is turned into text -- at completion-item
---build time or at expansion -- which is how a body can depend on the moment
---it is used. Returning nil from it drops the snippet from that request.
---@class zsnip.Snippet
---@field prefix string Trigger typed by the user
---@field body string|fun(): string?
---@field description? string
---@field filetype? string Filetype the snippet was registered under; set by the registry

---@alias zsnip.LoaderKind "vscode" | "snipmate"

---Options accepted by both loaders' `load()`/`lazy_load()`.
---@class zsnip.LoaderOpts
---@field paths? string|string[] Directories to read in addition to the runtimepath
---@field include? string[] Only load these languages
---@field exclude? string[] Load every language except these

---@class zsnip.Config
---@field extend? table<string, string|string[]> Filetype inheritance, e.g. `{ typescriptreact = { 'typescript' } }`
---@field global_filetype? string|false Bucket every filetype inherits from (default `'all'`)
---@field max_items? integer Default cap for |zsnip.completion_items()| and `zsnip.complete` (default 100)
---@field documentation? boolean Attach the snippet body as item documentation (default true)
---@field command? boolean Create the `:ZSnip` user command (default true)

---@class zsnip.CompletionOpts
---@field prefix? string Keyword to fuzzy-match triggers against; unset returns everything
---@field filetype? string Defaults to the filetype of `bufnr`
---@field bufnr? integer Defaults to the current buffer
---@field position? lsp.Position Cursor the response is anchored to; defaults to the real one when `bufnr` is the current buffer
---@field limit? integer Overrides `max_items`
---@field documentation? boolean Overrides the configured default
---@field filter? fun(snippet: zsnip.Snippet): boolean Keep only the snippets this returns true for

---One snippet selected for a request, with its body resolved and ready for
---|vim.snippet.expand()|. What `zsnip.complete` builds its menu entries from,
---and what an `lsp.CompletionItem` is projected out of.
---@class zsnip.Match
---@field snippet zsnip.Snippet
---@field text string
---@field ranked boolean Whether zsnip ordered the response, rather than leaving it to the client

---What the four built-in sources (`zsnip.lsp`, `zsnip.blink`, `zsnip.cmp` and
---`zsnip.complete`) forward to the completion layer, on top of whatever their
---own engine needs. The names match `zsnip.CompletionOpts` so they pass
---straight through.
---@class zsnip.SourceOpts
---@field limit? integer Cap on items per response. The three LSP-shaped sources default to uncapped -- the engine filters; `zsnip.complete` matches for itself, so it defaults to `max_items`
---@field documentation? boolean Attach the body and description to the item
---@field filter? fun(snippet: zsnip.Snippet): boolean Keep only the snippets this returns true for

---A discovered snippet file, before it is read.
---@class zsnip.Source
---@field kind zsnip.LoaderKind
---@field path string

return {}
