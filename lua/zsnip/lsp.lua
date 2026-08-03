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

---@class zsnip.LspOpts : zsnip.SourceOpts
---@field name? string Client name, as it appears in `:LspInfo` (default 'zsnip')
---@field filetypes? string[] Attach only to these filetypes (default: all)
---@field trigger_characters? string[] Characters that make a client ask unprompted (default: none)
---@field completion? boolean|vim.lsp.completion.BufferOpts Wire each buffer up for |vim.lsp.completion|

---What |vim.lsp.start()| expects back from a `cmd` function. Declared here
---because the runtime's own alias for it is private.
---@class zsnip.RpcClient
---@field request fun(method: string, params: table?, callback: fun(err: any, result: any, request_id: integer?), notify_reply: fun(request_id: integer)?): boolean, integer?
---@field notify fun(method: string, params: table?): boolean
---@field is_closing fun(): boolean
---@field terminate fun()

---The buffer a request came from.
---
---Not `vim.uri_to_bufnr()` alone: |vim.uri_from_bufnr()| has nothing to say
---about a buffer with no name and returns a bare `file://`, which round-trips
---to a *different*, filetype-less buffer -- and creates one, so every scratch
---buffer and every `:enew | set ft=lua` would be served nothing and collide
---onto the same bufnr. A request with no usable URI came from where the cursor
---is, which is the buffer we are in.
---@param uri string?
---@return integer
local function requesting_buffer(uri)
  if type(uri) ~= 'string' or uri == '' or uri == 'file://' then
    return vim.api.nvim_get_current_buf()
  end
  local bufnr = vim.uri_to_bufnr(uri)
  return vim.api.nvim_buf_is_loaded(bufnr) and bufnr or vim.api.nvim_get_current_buf()
end

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

    ---@param params lsp.CompletionParams?
    ---@return lsp.CompletionList
    local function complete(params)
      local bufnr = requesting_buffer(vim.tbl_get(params or {}, 'textDocument', 'uri'))
      local forwarded = completion.source_opts(opts, bufnr)
      forwarded.position = params and params.position or nil
      return { isIncomplete = false, items = completion.items(forwarded) }
    end

    ---@param method string
    ---@param params table?
    ---@return any
    local function answer(method, params)
      if method == 'initialize' then
        return {
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
            positionEncoding = 'utf-16',
          },
          serverInfo = { name = opts.name or 'zsnip' },
        }
      elseif method == 'textDocument/completion' then
        return complete(params)
      end
      -- 'shutdown' and anything a client asks for that was never advertised:
      -- an empty result is a valid answer to all of them.
      return nil
    end

    return {
      ---Answered on the next tick, never inline.
      ---
      ---Being in-process makes a synchronous reply possible, and it is wrong:
      ---|vim.lsp.completion| drives 'omnifunc', which returns -2 to say "the
      ---items come later" precisely because textlock forbids |complete()|
      ---while the option is being evaluated. Replying inside rpc.request()
      ---puts vim.fn.complete() back inside that window, and the whole path
      ---dies with E565 -- no menu at all, on every trigger. The same holds for
      ---the `autotrigger` route, which runs under InsertCharPre.
      ---
      ---`notify_reply` is how a client learns the request is done. Without it
      ---every completion leaves a 'pending' entry behind, forever -- under
      ---`autotrigger`, one per keystroke. Deferred, it lands after
      ---|vim.lsp.Client:request()| has registered the request, which is the
      ---ordinary out-of-process order and needs no version guard.
      request = function(method, params, callback, notify_reply)
        request_id = request_id + 1
        local id = request_id

        vim.schedule(function()
          if closing then
            return
          end
          callback(nil, answer(method, params), id)
          if notify_reply then
            notify_reply(id)
          end
        end)
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
---@type string?
local client_name = nil

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

  client_name = name
  augroup = vim.api.nvim_create_augroup('zsnip.lsp', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = augroup,
    callback = function(args)
      attach(args.buf)
    end,
  })

  -- Registered before anything can attach, so the buffers swept up below are
  -- wired too.
  if opts.completion then
    local requested = opts.completion
    ---@type vim.lsp.completion.BufferOpts
    local buffer_opts = type(requested) == 'table' and requested or {}
    vim.api.nvim_create_autocmd('LspAttach', {
      group = augroup,
      callback = function(args)
        -- Ours only. Enabling it for every client would take over completion
        -- for the user's language servers as a side effect of asking for
        -- snippets.
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if client and client.name == name then
          vim.lsp.completion.enable(true, client.id, args.buf, buffer_opts)
        end
      end,
    })
  end

  -- Buffers that already have a filetype missed the autocmd.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      attach(bufnr)
    end
  end
end

---Stop the server and forget it was ever started: the autocmd goes, and so do
---the clients it attached. Idempotent, and the exact undo of |M.start()| --
---without it `started()` stays true for the life of the session, so
---`:checkhealth zsnip` keeps reporting a server that is no longer there.
function M.stop()
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
  end
  for _, client in ipairs(client_name and vim.lsp.get_clients({ name = client_name }) or {}) do
    client:stop(true)
  end
  augroup, client_name = nil, nil
end

---Whether |zsnip.start_lsp_server()| has installed the autocmd that attaches
---the server to new buffers.
---@return boolean
function M.started()
  return augroup ~= nil
end

---Whether a client is actually up. Registered is not the same as serving: a
---`filetypes` list that excluded every buffer opened so far, or a `:LspStop`,
---leaves the autocmd in place with nothing behind it.
---@return boolean
function M.running()
  return client_name ~= nil and #vim.lsp.get_clients({ name = client_name }) > 0
end

return M
