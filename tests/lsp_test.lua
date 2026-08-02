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

  it('answers anything else with an empty result', function()
    assert.is_nil(request(start_server(), 'shutdown', {}))
    assert.is_nil(request(start_server(), 'textDocument/definition', {}))
  end)

  it('reports exit and closing state', function()
    local client, exits = start_server()

    assert.is_false(client.is_closing())
    client.notify('exit')
    assert.are.equal(1, #exits)

    client.terminate()
    assert.is_true(client.is_closing())
  end)
end)
