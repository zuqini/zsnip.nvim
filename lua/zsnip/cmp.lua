---An nvim-cmp source.
---
---```lua
---require('zsnip.cmp').register()
---
---require('cmp').setup({
---  snippet = { expand = function(args) vim.snippet.expand(args.body) end },
---  sources = { { name = 'zsnip' }, { name = 'nvim_lsp' } },
---})
---```
---
---nvim-cmp is only required by `register()`, so the module loads on a config
---that does not have it. An alternative to |zsnip.start_lsp_server()|, not a
---companion -- run both and every snippet is offered twice.

local completion = require('zsnip.completion')

---@class zsnip.CmpOpts : zsnip.SourceOpts

local M = {}

---@param opts? zsnip.CmpOpts
---@return table
function M.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = M })
end

---@return string
function M:get_debug_name()
  return 'zsnip'
end

---@return boolean
function M:is_available()
  return true
end

---Triggers are not all words: `#!` and `<div` have to be completable too, so
---the keyword is either a run of word characters or a run of symbols.
---@return string
function M:get_keyword_pattern()
  return [[\%(\k\+\|[^[:space:][:alnum:]_]\+\)]]
end

---@param params table
---@param callback fun(items: lsp.CompletionItem[])
function M:complete(params, callback)
  local bufnr = vim.tbl_get(params or {}, 'context', 'bufnr')
  callback(completion.items(completion.source_opts(self.opts, bufnr)))
end

---Register the source with nvim-cmp under the name 'zsnip'.
---@param opts? zsnip.CmpOpts
function M.register(opts)
  require('cmp').register_source('zsnip', M.new(opts))
end

return M
