local helpers = require('helpers')
local lsp = require('zsnip.lsp')
local registry = require('zsnip.registry')

before_each(helpers.reset)
after_each(helpers.cleanup)

---@return table client, table exits
local function start_server(opts)
  local exits = {}
  local client = lsp.server(opts)({
    on_exit = function(code, signal)
      exits[#exits + 1] = { code = code, signal = signal }
    end,
  })
  return client, exits
end

---The server answers on the next tick rather than inline -- see the comment on
---`request` in `zsnip.lsp` -- so every reply here is waited for.
---@param client table
---@param method string
---@param params table?
---@return any
local function request(client, method, params)
  local result, answered = nil, false
  client.request(method, params, function(_, response)
    result, answered = response, true
  end)
  assert.is_true(vim.wait(2000, function()
    return answered
  end))
  return result
end

---A buffer backed by a real file under `helpers.tempdir()` -- the URI round
---trip a real client's completion request takes, unlike `helpers.typed()`'s
---scratch buffer.
---@param filetype string
---@param name? string defaults to a name derived from the filetype
---@return integer
local function named_buffer(filetype, name)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, helpers.tempdir() .. '/' .. (name or ('attach.' .. filetype)))
  vim.bo[bufnr].filetype = filetype
  return bufnr
end

---A buffer with no name at all, made current -- deliberately, to exercise
---`lsp.requesting_buffer()`'s fallback to the current buffer, not the URI
---round trip `named_buffer()` covers.
---@param filetype string
---@return integer
local function unnamed_buffer(filetype)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.bo[bufnr].filetype = filetype
  return bufnr
end

describe('the in-process server', function()
  it('advertises completion', function()
    local client = start_server()
    local result = request(client, 'initialize', {})

    assert.is_not_nil(result.capabilities.completionProvider)
    assert.are.same({}, result.capabilities.completionProvider.triggerCharacters)
    assert.are.equal('zsnip', result.serverInfo.name)
  end)

  it('advertises the trigger characters it was given', function()
    local client = start_server({ name = 'snips', trigger_characters = { 'a', 'b' } })
    local result = request(client, 'initialize', {})

    assert.are.same({ 'a', 'b' }, result.capabilities.completionProvider.triggerCharacters)
    assert.are.equal('snips', result.serverInfo.name)
  end)

  it('answers with the snippets of the requesting buffer', function()
    registry.add('lua', { { prefix = 'req', body = "require '$1'" } })
    registry.add('python', { { prefix = 'imp', body = 'import $1' } })

    local bufnr = named_buffer('lua', 'file.lua')

    local client = start_server()
    local result = request(client, 'textDocument/completion', {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      position = { line = 0, character = 0 },
    })

    assert.is_false(result.isIncomplete)
    assert.are.equal(1, #result.items)
    assert.are.equal('req', result.items[1].label)

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('returns the whole filetype, uncapped, so the client can filter', function()
    local snippets = {}
    for index = 1, 200 do
      snippets[index] = { prefix = ('p%03d'):format(index), body = 'b' }
    end
    registry.add('lua', snippets)

    local bufnr = named_buffer('lua', 'big.lua')

    local result = request(start_server(), 'textDocument/completion', {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      position = { line = 0, character = 0 },
    })
    assert.are.equal(200, #result.items)

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('forwards documentation and filter to the completion items', function()
    registry.add('lua', { { prefix = 'req', body = 'b' }, { prefix = 'skip', body = 'b' } })

    local bufnr = named_buffer('lua', 'opts.lua')
    local params = {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      position = { line = 0, character = 0 },
    }

    local plain = request(
      start_server({
        documentation = false,
        filter = function(snippet)
          return snippet.prefix ~= 'skip'
        end,
      }),
      'textDocument/completion',
      params
    )

    assert.are.equal(1, #plain.items)
    assert.are.equal('req', plain.items[1].label)
    assert.is_nil(plain.items[1].documentation)

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('answers anything else with an empty result', function()
    assert.is_nil(request(start_server(), 'shutdown', {}))
    assert.is_nil(request(start_server(), 'textDocument/definition', {}))
  end)

  -- notify_reply is the only thing that clears the entry Client:request()
  -- registers. Without it every completion leaves a 'pending' request behind
  -- for the life of the session, and fires an LspRequest autocmd nothing ever
  -- matches -- one per keystroke under autotrigger.
  it('tells the client each reply is done', function()
    local client = start_server()
    local replied, ids = {}, {}

    for _ = 1, 3 do
      local ok, id = client.request('shutdown', {}, function(_, _, request_id)
        ids[#ids + 1] = request_id
      end, function(request_id)
        replied[#replied + 1] = request_id
      end)
      assert.is_true(ok)
      assert.is_number(id)
    end

    assert.is_true(vim.wait(2000, function()
      return #replied == 3
    end))
    assert.are.same({ 1, 2, 3 }, replied)
    assert.are.same({ 1, 2, 3 }, ids)
  end)

  -- pcall'd for the same reason notify_reply is unconditional above: a
  -- filter or documentation resolver that raises must not skip callback() or
  -- notify_reply() -- the same pending-request leak, from the handler failing
  -- instead of never running.
  it('answers with an error rather than leaking the request when the handler raises', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    local bufnr = named_buffer('lua', 'boom.lua')

    local client = start_server({
      filter = function()
        error('boom')
      end,
    })
    local err, replied = nil, false
    client.request('textDocument/completion', {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      position = { line = 0, character = 0 },
    }, function(request_err)
      err = request_err
    end, function()
      replied = true
    end)

    assert.is_true(vim.wait(2000, function()
      return replied
    end))
    assert.is_not_nil(err)
    assert.are.equal(-32603, err.code)

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('still answers a client that offers no reply callback', function()
    local client = start_server()
    local answered = false
    local ok, id = client.request('initialize', {}, function()
      answered = true
    end)

    assert.is_true(ok)
    assert.are.equal(1, id)
    assert.is_true(vim.wait(2000, function()
      return answered
    end))
  end)

  -- A reply lands on the next tick, and by then the client may be gone. The
  -- callback belongs to a request nobody is waiting for any more.
  it('does not answer once it has closed', function()
    local client = start_server()
    local answered = false
    client.request('initialize', {}, function()
      answered = true
    end)
    client.terminate()

    assert.is_false(vim.wait(200, function()
      return answered
    end))
  end)

  it('reports exit and closing state', function()
    local client, exits = start_server()

    assert.is_false(client.is_closing())
    client.notify('exit')
    assert.are.equal(1, #exits)
    assert.is_true(client.is_closing())
  end)

  -- A forced stop -- Client:stop(true), `:LspStop!`, a restart -- calls
  -- terminate() instead of sending 'exit'. Reporting the exit is the only way
  -- the client learns the server is gone; without it the user's on_exit
  -- callback never runs and the client is never reaped.
  it('reports an exit when it is terminated rather than asked to exit', function()
    local client, exits = start_server()

    client.terminate()

    assert.is_true(client.is_closing())
    assert.are.same({ { code = 0, signal = 15 } }, exits)
  end)

  it('reports that exit exactly once', function()
    local client, exits = start_server()

    client.terminate()
    client.terminate()
    client.notify('exit')

    assert.are.equal(1, #exits)
  end)
end)

describe('lsp.start', function()
  after_each(helpers.stop_lsp)

  -- vim.lsp's client registry is global and outlives a busted test, and
  -- vim.lsp.start() reuses by name. A name per test keeps these independent of
  -- whatever the rest of the suite left behind; the *shipped* name is what the
  -- default-name test below covers.
  local counter = 0
  ---@param opts? table
  ---@return string name
  local function start(opts)
    counter = counter + 1
    opts = vim.tbl_extend('force', opts or {}, { name = 'zsnip_start_' .. counter })
    lsp.start(opts)
    return opts.name
  end

  ---Attachment completes once the client has initialized, which is a round
  ---trip through the scheduler even for an in-process server.
  ---@param bufnr integer
  ---@param name string
  ---@return integer count
  local function attached(bufnr, name)
    vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = bufnr, name = name }) > 0
    end)
    return #vim.lsp.get_clients({ bufnr = bufnr, name = name })
  end

  ---@param bufnr integer
  ---@return integer
  local function completedone_handlers(bufnr)
    return #vim.api.nvim_get_autocmds({ event = 'CompleteDone', buffer = bufnr })
  end

  -- Without this the items arrive but nothing expands them: the handler that
  -- reads insertTextFormat lives in vim.lsp.completion and is installed only
  -- by enable(), so an accepted snippet would put `${1:mod}` in the buffer.
  it('wires the buffer up for vim.lsp.completion when asked', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    local bufnr = named_buffer('lua')

    assert.are.equal(0, completedone_handlers(bufnr))
    local name = start({ completion = true })
    assert.are.equal(1, attached(bufnr, name))
    assert.are.equal(1, completedone_handlers(bufnr))

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('leaves completion alone by default', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    local bufnr = named_buffer('lua')

    local name = start()
    assert.are.equal(1, attached(bufnr, name))
    assert.are.equal(0, completedone_handlers(bufnr))

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  -- Enabling it for every client would take over completion for the user's
  -- language servers as a side effect of asking for snippets.
  it('wires up only its own client', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    local bufnr = named_buffer('lua')
    local name = start({ completion = true })
    assert.are.equal(1, attached(bufnr, name))

    -- Named zsnip_* so the shared teardown reaps it; what the wiring keys on
    -- is the exact name it was started under, which this is not.
    local other = 'zsnip_other_' .. name
    vim.lsp.start({ name = other, cmd = lsp.server({ name = other }) }, { bufnr = bufnr })
    assert.are.equal(1, attached(bufnr, other))

    -- Still just ours: the second client attached without picking one up.
    assert.are.equal(1, completedone_handlers(bufnr))

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('attaches to a buffer that already had a filetype', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    local bufnr = named_buffer('lua')

    local name = start()

    assert.are.equal(1, attached(bufnr, name))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('attaches to a buffer that gets one afterwards', function()
    local name = start()
    local bufnr = named_buffer('python')

    assert.are.equal(1, attached(bufnr, name))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('honours the filetypes gate', function()
    local name = start({ filetypes = { 'lua' } })
    local wanted, unwanted = named_buffer('lua'), named_buffer('python')

    assert.are.equal(1, attached(wanted, name))
    assert.are.equal(0, #vim.lsp.get_clients({ bufnr = unwanted, name = name }))

    vim.api.nvim_buf_delete(wanted, { force = true })
    vim.api.nvim_buf_delete(unwanted, { force = true })
  end)

  -- The gate ran only on attach: a buffer allowed when its filetype was first
  -- set kept the client after the filetype changed to an excluded one.
  it('detaches when the filetype changes away from the gate', function()
    local name = start({ filetypes = { 'lua' } })
    local bufnr = named_buffer('lua')
    assert.are.equal(1, attached(bufnr, name))

    vim.bo[bufnr].filetype = 'python'
    assert.is_true(vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = bufnr, name = name }) == 0
    end))

    vim.bo[bufnr].filetype = 'lua'
    assert.are.equal(1, attached(bufnr, name))

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  -- filetype == '' was its own early return that never reached the detach
  -- loop, so `:set ft=` left the client attached -- the one exclusion the
  -- gate did not reconcile.
  it('detaches when the filetype is cleared, without a filetypes gate', function()
    local name = start()
    local bufnr = named_buffer('lua')
    assert.are.equal(1, attached(bufnr, name))

    vim.bo[bufnr].filetype = ''
    assert.is_true(vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = bufnr, name = name }) == 0
    end))

    vim.bo[bufnr].filetype = 'lua'
    assert.are.equal(1, attached(bufnr, name))

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  -- Neovim assigns dotted filetypes itself (javascript.glimmer) and users set
  -- others (yaml.ansible); the registry serves both the dotted filetype and
  -- each dot-separated component, so the gate has to honour a component too.
  it('honours the filetypes gate against a dot-separated component', function()
    local name = start({ filetypes = { 'javascript' } })
    local bufnr = named_buffer('javascript.glimmer')

    assert.are.equal(1, attached(bufnr, name))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  -- 'javascript.glimmer' is not one of its own components ('javascript',
  -- 'glimmer'), so naming it exactly must also attach.
  it('honours the filetypes gate against the exact dotted filetype', function()
    local name = start({ filetypes = { 'javascript.glimmer' } })
    local bufnr = named_buffer('javascript.glimmer')

    assert.are.equal(1, attached(bufnr, name))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  -- Prompts, help and other special buffers get a filetype too; a client
  -- attached there would pop global-bucket snippets up inside them.
  it('never attaches to a special buffer, even with a matching filetype', function()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].filetype = 'lua'
    local prompt = vim.api.nvim_create_buf(false, true)
    vim.bo[prompt].buftype = 'prompt'
    vim.bo[prompt].filetype = 'lua'

    local name = start()

    assert.are.equal('nofile', vim.bo[scratch].buftype)
    assert.are.equal(0, #vim.lsp.get_clients({ bufnr = scratch, name = name }))
    assert.are.equal(0, #vim.lsp.get_clients({ bufnr = prompt, name = name }))

    vim.api.nvim_buf_delete(scratch, { force = true })
    vim.api.nvim_buf_delete(prompt, { force = true })
  end)

  it('reports that it started, and stacks neither autocmd nor client', function()
    counter = counter + 1
    local name = 'zsnip_start_' .. counter
    lsp.start({ name = name })
    lsp.start({ name = name })
    lsp.start({ name = name })
    local bufnr = named_buffer('lua')

    assert.is_true(lsp.started())
    assert.are.equal(1, attached(bufnr, name))
    assert.are.equal(
      1,
      #vim.api.nvim_get_autocmds({ group = 'zsnip.lsp', event = 'FileType' })
    )

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  -- A second start() under a different name used to leave the first name's
  -- clients running alongside the new one, serving every snippet twice.
  it('stops the previous clients when restarted under a new name', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    local bufnr = named_buffer('lua')

    counter = counter + 1
    local first = 'zsnip_start_' .. counter .. '_a'
    lsp.start({ name = first })
    assert.are.equal(1, attached(bufnr, first))

    counter = counter + 1
    local second = 'zsnip_start_' .. counter .. '_b'
    lsp.start({ name = second })

    assert.are.equal(1, attached(bufnr, second))
    assert.are.equal(0, #vim.lsp.get_clients({ name = first }))
    assert.is_true(lsp.running())

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  -- A second start() under the *same* name reused the running client, so a
  -- changed trigger_characters never reached buffers already attached.
  it('replaces a running client rather than reusing its stale opts', function()
    local bufnr = named_buffer('lua')

    counter = counter + 1
    local name = 'zsnip_start_' .. counter
    lsp.start({ name = name, trigger_characters = { 'a' } })
    assert.are.equal(1, attached(bufnr, name))

    lsp.start({ name = name, trigger_characters = { 'b' } })

    -- The old client lingers in get_clients() until its own deferred
    -- detach runs, so waiting for "any client of this name" is not enough:
    -- wait for the one client left standing to be the new one.
    assert.is_true(vim.wait(2000, function()
      local clients = vim.lsp.get_clients({ bufnr = bufnr, name = name })
      return #clients == 1
        and vim.deep_equal(clients[1].server_capabilities.completionProvider.triggerCharacters, { 'b' })
    end))

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  -- get_clients() without _uninitialized skips a client that has not yet
  -- answered `initialize`, which a client started this same tick never has.
  -- The restart above waits for attachment between the two start() calls, so
  -- it never exercises that miss; this one does not wait.
  it('applies new opts even when restarted before the old client initialized', function()
    registry.add('lua', {
      { prefix = 'a', body = 'b' },
      { prefix = 'b', body = 'b' },
      { prefix = 'c', body = 'b' },
    })
    local bufnr = named_buffer('lua')

    counter = counter + 1
    local name = 'zsnip_start_' .. counter
    lsp.start({ name = name, limit = 1 })
    lsp.start({ name = name })

    assert.are.equal(1, attached(bufnr, name))
    local client = vim.lsp.get_clients({ bufnr = bufnr, name = name })[1]
    local items = nil
    client:request('textDocument/completion', {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      position = { line = 0, character = 0 },
    }, function(_, result)
      items = result.items
    end, bufnr)

    assert.is_true(vim.wait(2000, function()
      return items ~= nil
    end))
    assert.are.equal(3, #items)

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('stops a client that has not initialized yet', function()
    counter = counter + 1
    local name = 'zsnip_start_' .. counter
    lsp.start({ name = name })
    lsp.stop()

    assert.is_true(vim.wait(2000, function()
      return #vim.lsp.get_clients({ name = name, _uninitialized = true }) == 0
    end))
  end)

  -- Same miss as above, reached through the filetypes gate's detach arm
  -- instead of stop(): the first buffer's client is still uninitialized when
  -- the very next FileType event asks to detach it.
  it('detaches a client that has not initialized yet when the filetype changes away from the gate', function()
    local name = start({ filetypes = { 'lua' } })
    local bufnr = named_buffer('lua')

    vim.bo[bufnr].filetype = 'python'

    assert.is_true(vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = bufnr, name = name, _uninitialized = true }) == 0
    end))

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  -- The leak this guards is only observable through the real client: the
  -- server's reply callback is what stops Client:request() registering a
  -- request it will never clear.
  it('leaves no request pending after a completion through a real client', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    local bufnr = named_buffer('lua')
    local name = start()
    assert.are.equal(1, attached(bufnr, name))

    local client = vim.lsp.get_clients({ bufnr = bufnr, name = name })[1]
    local answered = 0
    for _ = 1, 5 do
      client:request('textDocument/completion', {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        position = { line = 0, character = 0 },
      }, function()
        answered = answered + 1
      end, bufnr)
    end

    assert.is_true(vim.wait(2000, function()
      return answered == 5
    end))
    assert.are.equal(0, vim.tbl_count(client.requests))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('serves the shipped name to a buffer', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    local bufnr = named_buffer('lua')

    lsp.start()

    assert.are.equal(1, attached(bufnr, 'zsnip'))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)

describe('the in-process server and awkward buffers', function()
  -- vim.uri_from_bufnr() has nothing to say about a buffer with no name: it
  -- returns a bare `file://`, which round-trips to a *different*,
  -- filetype-less buffer -- and creates one. Every scratch buffer and every
  -- `:enew | set ft=lua` used to be served nothing, and all of them collided
  -- onto the same bufnr.
  it('serves a buffer that has no name', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    local bufnr = unnamed_buffer('lua')

    local result = request(start_server(), 'textDocument/completion', {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      position = { line = 0, character = 0 },
    })

    assert.are.equal(1, #result.items)
    assert.are.equal('req', result.items[1].label)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('serves a request that names no document at all', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    local bufnr = unnamed_buffer('lua')

    local result = request(start_server(), 'textDocument/completion', { position = { line = 0, character = 0 } })

    assert.are.equal(1, #result.items)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)

describe('lsp.stop', function()
  after_each(helpers.stop_lsp)

  -- Without this `started()` stays true for the life of the session, so
  -- :checkhealth keeps reporting a server that is no longer there -- and no
  -- API gets back to a clean state short of restarting Neovim.
  it('undoes start, autocmd and clients alike', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    local bufnr = named_buffer('lua', 'stop.lua')
    helpers.start_lsp()

    assert.is_true(lsp.started())
    assert.is_true(lsp.running())

    lsp.stop()

    assert.is_false(lsp.started())
    assert.is_false(lsp.running())
    -- The group is gone entirely, not merely emptied; asking about one that
    -- does not exist is an error, which is the assertion.
    assert.is_false(pcall(vim.api.nvim_get_autocmds, { group = 'zsnip.lsp' }))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('does nothing twice over, or when never started', function()
    lsp.stop()
    lsp.stop()
    assert.is_false(lsp.started())
  end)
end)
