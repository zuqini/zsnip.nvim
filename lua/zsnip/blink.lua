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
---items, so the only thing shared with it is the shape of these four methods.
---An alternative to |zsnip.start_lsp_server()|, not a companion -- run both and
---every snippet is offered twice.

local completion = require('zsnip.completion')

---@class zsnip.BlinkOpts
---@field limit? integer Cap on items per response (default: uncapped -- blink filters)
---@field documentation? boolean Attach the body as item documentation
---@field filter? fun(snippet: zsnip.Snippet): boolean

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
    items = completion.items({
      bufnr = ctx and ctx.bufnr or nil,
      limit = self.opts.limit or math.huge,
      documentation = self.opts.documentation,
      filter = self.opts.filter,
    }),
  })
  return function() end
end

return M
