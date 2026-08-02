---Type declarations for zsnip.nvim.
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
---@field max_items? integer Default cap for |zsnip.completion_items()| (default 100)
---@field documentation? boolean Attach the snippet body as item documentation (default true)
---@field command? boolean Create the `:ZSnip` user command (default true)

---@class zsnip.CompletionOpts
---@field prefix? string Keyword to fuzzy-match triggers against; unset returns everything
---@field filetype? string Defaults to the filetype of `bufnr`
---@field bufnr? integer Defaults to the current buffer
---@field limit? integer Overrides `max_items`
---@field documentation? boolean Overrides the configured default
---@field filter? fun(snippet: zsnip.Snippet): boolean Keep only the snippets this returns true for

---What the three built-in sources (`zsnip.lsp`, `zsnip.blink`, `zsnip.cmp`)
---forward to |zsnip.completion_items()|, on top of whatever their own engine
---needs. The names match `zsnip.CompletionOpts` so they pass straight through.
---@class zsnip.SourceOpts
---@field limit? integer Cap on items per response (default: uncapped -- the engine filters)
---@field documentation? boolean Attach the body as item documentation
---@field filter? fun(snippet: zsnip.Snippet): boolean Keep only the snippets this returns true for

---A discovered snippet file, before it is read.
---@class zsnip.Source
---@field kind zsnip.LoaderKind
---@field path string

return {}
