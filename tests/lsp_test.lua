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

---@param client table
---@param method string
---@param params table?
---@return any
local function request(client, method, params)
  local result
  client.request(method, params, function(_, response)
    result = response
  end)
  return result
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

    local bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(bufnr, helpers.tempdir() .. '/file.lua')
    vim.bo[bufnr].filetype = 'lua'

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

    local bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(bufnr, helpers.tempdir() .. '/big.lua')
    vim.bo[bufnr].filetype = 'lua'

    local result = request(start_server(), 'textDocument/completion', {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      position = { line = 0, character = 0 },
    })
    assert.are.equal(200, #result.items)

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('forwards documentation and filter to the completion items', function()
    registry.add('lua', { { prefix = 'req', body = 'b' }, { prefix = 'skip', body = 'b' } })

    local bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(bufnr, helpers.tempdir() .. '/opts.lua')
    vim.bo[bufnr].filetype = 'lua'
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

    assert.are.same({ 1, 2, 3 }, replied)
    assert.are.same({ 1, 2, 3 }, ids)
  end)

  it('still answers a client that offers no reply callback', function()
    local client = start_server()
    local ok, id = client.request('initialize', {}, function() end)

    assert.is_true(ok)
    assert.are.equal(1, id)
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

  ---@param filetype string
  ---@return integer
  local function buffer(filetype)
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, helpers.tempdir() .. '/attach.' .. filetype)
    vim.bo[bufnr].filetype = filetype
    return bufnr
  end

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
    local bufnr = buffer('lua')

    assert.are.equal(0, completedone_handlers(bufnr))
    local name = start({ completion = true })
    assert.are.equal(1, attached(bufnr, name))
    assert.are.equal(1, completedone_handlers(bufnr))

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('leaves completion alone by default', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    local bufnr = buffer('lua')

    local name = start()
    assert.are.equal(1, attached(bufnr, name))
    assert.are.equal(0, completedone_handlers(bufnr))

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  -- Enabling it for every client would take over completion for the user's
  -- language servers as a side effect of asking for snippets.
  it('wires up only its own client', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    local bufnr = buffer('lua')
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
    local bufnr = buffer('lua')

    local name = start()

    assert.are.equal(1, attached(bufnr, name))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('attaches to a buffer that gets one afterwards', function()
    local name = start()
    local bufnr = buffer('python')

    assert.are.equal(1, attached(bufnr, name))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('honours the filetypes gate', function()
    local name = start({ filetypes = { 'lua' } })
    local wanted, unwanted = buffer('lua'), buffer('python')

    assert.are.equal(1, attached(wanted, name))
    assert.are.equal(0, #vim.lsp.get_clients({ bufnr = unwanted, name = name }))

    vim.api.nvim_buf_delete(wanted, { force = true })
    vim.api.nvim_buf_delete(unwanted, { force = true })
  end)

  it('reports that it started, and stacks neither autocmd nor client', function()
    counter = counter + 1
    local name = 'zsnip_start_' .. counter
    lsp.start({ name = name })
    lsp.start({ name = name })
    lsp.start({ name = name })
    local bufnr = buffer('lua')

    assert.is_true(lsp.started())
    assert.are.equal(1, attached(bufnr, name))
    assert.are.equal(
      1,
      #vim.api.nvim_get_autocmds({ group = 'zsnip.lsp', event = 'FileType' })
    )

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  -- The leak this guards is only observable through the real client: the
  -- server's reply callback is what stops Client:request() registering a
  -- request it will never clear.
  it('leaves no request pending after a completion through a real client', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    local bufnr = buffer('lua')
    local name = start()
    assert.are.equal(1, attached(bufnr, name))

    local client = vim.lsp.get_clients({ bufnr = bufnr, name = name })[1]
    for _ = 1, 5 do
      client:request('textDocument/completion', {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        position = { line = 0, character = 0 },
      }, function() end, bufnr)
    end

    assert.are.equal(0, vim.tbl_count(client.requests))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('serves the shipped name to a buffer', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    local bufnr = buffer('lua')

    lsp.start()

    assert.are.equal(1, attached(bufnr, 'zsnip'))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
