---A blink.cmp source.
---
---```lua
---require('blink.cmp').setup({
---  snippets = { preset = 'default' },
---  sources = {
---    default = { 'lsp', 'path', 'zsnip', 'buffer' },
---    providers = { zsnip = { name = 'zsnip', module = 'zsnip.blink' } },
---  },
---})
---```
---
---Deliberately requires nothing from blink: the items are plain LSP completion
---items, so the only thing shared with it is the shape of these three methods.
---An alternative to |zsnip.start_lsp_server()|, not a companion -- run both and
---every snippet is offered twice.

local completion = require('zsnip.completion')

---@class zsnip.BlinkOpts : zsnip.SourceOpts

local M = {}

---@param opts? zsnip.BlinkOpts
---@return table
function M.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = M })
end

---@return boolean
function M:enabled()
  return true
end

---Everything for the filetype in one uncut response: blink caches it for the
---session and does its own filtering and ranking, which it does better than a
---prefix match here would.
---@param ctx table blink's completion context
---@param callback fun(response: table)
---@return fun() cancel
function M:get_completions(ctx, callback)
  callback({
    is_incomplete_forward = false,
    is_incomplete_backward = false,
    items = completion.items(completion.source_opts(self.opts, ctx and ctx.bufnr or nil)),
  })
  return function() end
end

return M
