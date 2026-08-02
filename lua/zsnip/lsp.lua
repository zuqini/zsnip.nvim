---An in-process LSP server that serves the registry's snippets.
---
---Snippets reach a completion menu through whatever the menu already speaks.
---Rather than write and maintain a source for each engine, zsnip answers
---`textDocument/completion` as a language server that never leaves the
---process: blink.cmp, nvim-cmp, |vim.lsp.completion()| and anything else that
---consumes LSP picks it up with no glue.
---
---The whole filetype is returned in one uncut list (`isIncomplete = false`),
---which is what lets the client do its own filtering and ranking -- the same
---deal every real server offers.

local completion = require('zsnip.completion')

local M = {}

---@class zsnip.LspOpts
---@field name? string Client name, as it appears in `:LspInfo` (default 'zsnip')
---@field filetypes? string[] Attach only to these filetypes (default: all)
---@field limit? integer Cap on items per response (default: uncapped)
---@field documentation? boolean Attach the body as item documentation
---@field filter? fun(snippet: zsnip.Snippet): boolean
---@field trigger_characters? string[] Characters that make a client ask unprompted (default: none)

---What |vim.lsp.start()| expects back from a `cmd` function. Declared here
---because the runtime's own alias for it is private.
---@class zsnip.RpcClient
---@field request fun(method: string, params: table?, callback: fun(err: any, result: any, request_id: integer?), notify_reply: fun(request_id: integer)?): boolean, integer?
---@field notify fun(method: string, params: table?): boolean
---@field is_closing fun(): boolean
---@field terminate fun()

---@param opts zsnip.LspOpts
---@return fun(dispatchers: vim.lsp.rpc.Dispatchers): zsnip.RpcClient
local function server(opts)
  return function(dispatchers)
    local request_id = 0
    local closing = false

    ---Both ways a client ends a server -- an `exit` notification and a forced
    ---terminate -- land here, and either way the exit is reported once.
    local function close()
      if closing then
        return
      end
      closing = true
      dispatchers.on_exit(0, 15)
    end

    ---@param params lsp.CompletionParams
    ---@return lsp.CompletionList
    local function complete(params)
      local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
      local filetype = vim.bo[bufnr].filetype
      return {
        isIncomplete = false,
        items = completion.items({
          bufnr = bufnr,
          filetype = filetype ~= '' and filetype or nil,
          limit = opts.limit or math.huge,
          documentation = opts.documentation,
          filter = opts.filter,
        }),
      }
    end

    return {
      ---`notify_reply` is how a client learns the request is done -- it is the
      ---only thing that clears the entry |vim.lsp.Client:request()| registers,
      ---and it fires an LspRequest autocmd either way. Answering without it
      ---leaves one 'pending' request behind per completion, forever, which
      ---under `autotrigger` is one per keystroke. Calling it before returning
      ---also tells the client we resolved synchronously, so it never registers
      ---the request at all.
      request = function(method, params, callback, notify_reply)
        request_id = request_id + 1
        local id = request_id

        if method == 'initialize' then
          callback(nil, {
            capabilities = {
              completionProvider = {
                -- Empty by default, as |vim.lsp.completion| reads this to
                -- decide when to ask unprompted: blink.cmp and nvim-cmp ask
                -- on every keystroke of their own accord, and a client that
                -- does not should be told which characters matter by the
                -- config that knows what its triggers look like.
                triggerCharacters = opts.trigger_characters or {},
                resolveProvider = false,
              },
            },
            serverInfo = { name = opts.name or 'zsnip' },
          }, id)
        elseif method == 'textDocument/completion' then
          callback(nil, complete(params), id)
        else
          -- 'shutdown' and anything a client asks for that was never
          -- advertised: an empty result is a valid answer to all of them.
          callback(nil, nil, id)
        end

        if notify_reply then
          notify_reply(id)
        end
        return true, id
      end,
      notify = function(method)
        if method == 'exit' then
          close()
        end
        return true
      end,
      is_closing = function()
        return closing
      end,
      ---A forced stop -- |vim.lsp.Client:stop()| with `force`, `:LspStop!`, a
      ---restart -- calls this instead of sending 'exit', so this is the only
      ---place that reports the exit on that path. Without it the client never
      ---learns the server is gone: the user's `on_exit` never runs and the
      ---client is never reaped.
      terminate = close,
    }
  end
end

---Exposed for tests and for anyone wiring the server up by hand.
---@param opts? zsnip.LspOpts
---@return fun(dispatchers: vim.lsp.rpc.Dispatchers): zsnip.RpcClient
function M.server(opts)
  return server(opts or {})
end

---@type integer?
local augroup = nil

---Start the server and attach it to every buffer that gets a filetype.
---Idempotent: calling it again replaces the autocmd rather than stacking one.
---@param opts? zsnip.LspOpts
function M.start(opts)
  opts = opts or {}
  local name = opts.name or 'zsnip'
  local cmd = server(opts)

  local function attach(bufnr)
    local filetype = vim.bo[bufnr].filetype
    if filetype == '' then
      return
    end
    if opts.filetypes and not vim.tbl_contains(opts.filetypes, filetype) then
      return
    end
    vim.lsp.start({ name = name, cmd = cmd }, { bufnr = bufnr })
  end

  augroup = vim.api.nvim_create_augroup('zsnip.lsp', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = augroup,
    callback = function(args)
      attach(args.buf)
    end,
  })

  -- Buffers that already have a filetype missed the autocmd.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      attach(bufnr)
    end
  end
end

---@return boolean
function M.started()
  return augroup ~= nil
end

return M
