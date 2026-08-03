local helpers = require('helpers')
local registry = require('zsnip.registry')

before_each(helpers.reset)
after_each(helpers.cleanup)

---@return integer
local function lua_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].filetype = 'lua'
  return bufnr
end

describe('the blink.cmp source', function()
  local blink = require('zsnip.blink')

  it('answers with the buffer filetype in blink response shape', function()
    registry.add('lua', { { prefix = 'req', body = "require '$1'" } })
    registry.add('python', { { prefix = 'imp', body = 'import $1' } })

    local response
    local cancel = blink.new():get_completions({ bufnr = lua_buffer() }, function(result)
      response = result
    end)

    assert.are.equal('function', type(cancel))
    assert.is_false(response.is_incomplete_forward)
    assert.is_false(response.is_incomplete_backward)
    assert.are.equal(1, #response.items)
    assert.are.equal('req', response.items[1].label)
    assert.are.equal(vim.lsp.protocol.InsertTextFormat.Snippet, response.items[1].insertTextFormat)
  end)

  it('leaves the cap off so blink can filter the whole filetype', function()
    local snippets = {}
    for index = 1, 150 do
      snippets[index] = { prefix = ('p%03d'):format(index), body = 'b' }
    end
    registry.add('lua', snippets)

    local response
    blink.new():get_completions({ bufnr = lua_buffer() }, function(result)
      response = result
    end)
    assert.are.equal(150, #response.items)
  end)

  it('passes its options through', function()
    registry.add('lua', { { prefix = 'keep', body = 'b' }, { prefix = 'drop', body = 'b' } })

    local response
    blink.new({
      limit = 1,
      documentation = false,
      filter = function(snippet)
        return snippet.prefix ~= 'drop'
      end,
    }):get_completions({ bufnr = lua_buffer() }, function(result)
      response = result
    end)

    assert.are.equal(1, #response.items)
    assert.are.equal('keep', response.items[1].label)
    assert.is_nil(response.items[1].documentation)
  end)

  it('is enabled', function()
    assert.is_true(blink.new():enabled())
  end)
end)

describe('the nvim-cmp source', function()
  local cmp = require('zsnip.cmp')

  it('answers with the buffer filetype', function()
    registry.add('lua', { { prefix = 'req', body = "require '$1'" } })

    local items
    cmp.new():complete({ context = { bufnr = lua_buffer() } }, function(result)
      items = result
    end)

    assert.are.equal(1, #items)
    assert.are.equal('req', items[1].label)
    assert.are.equal(vim.lsp.protocol.CompletionItemKind.Snippet, items[1].kind)
  end)

  it('completes symbol triggers as well as words', function()
    local pattern = cmp.new():get_keyword_pattern()
    assert.are.equal('#!', vim.fn.matchstr('x #!', pattern .. '$'))
    assert.are.equal('req', vim.fn.matchstr('local req', pattern .. '$'))
  end)

  it('reports itself to cmp', function()
    assert.are.equal('zsnip', cmp.new():get_debug_name())
    assert.is_true(cmp.new():is_available())
  end)

  it('loads without nvim-cmp installed', function()
    assert.is_false(pcall(require, 'cmp'))
    assert.are.equal('table', type(cmp.new()))
  end)
end)

describe('the loaders', function()
  ---@param loader table
  ---@param dir string
  ---@param filetype string
  ---@param prefix string
  local function reads_eagerly(loader, dir, filetype, prefix)
    helpers.use_rtp(dir)
    loader.load()

    -- The distinguishing half of load(): the files are read before anything
    -- asks for a filetype, so `available()` already knows them.
    assert.contains(vim.tbl_keys(registry.available()), filetype)
    assert.contains(helpers.prefixes(registry.get(filetype)), prefix)
  end

  it('reads a VSCode pack up front on load', function()
    reads_eagerly(
      require('zsnip.loaders.from_vscode'),
      helpers.vscode_pack({ lua = { one = { prefix = 'req', body = 'b' } } }),
      'lua',
      'req'
    )
  end)

  it('reads a snipmate pack up front on load', function()
    reads_eagerly(
      require('zsnip.loaders.from_snipmate'),
      helpers.snipmate_pack({ lua = 'snippet req\n\tbody' }),
      'lua',
      'req'
    )
  end)

  it('passes its options through on load', function()
    helpers.use_rtp(helpers.vscode_pack({
      lua = { one = { prefix = 'req', body = 'b' } },
      python = { two = { prefix = 'imp', body = 'b' } },
    }))
    require('zsnip.loaders.from_vscode').load({ include = { 'lua' } })

    assert.are.same({ 'req' }, helpers.prefixes(registry.get('lua')))
    assert.are.same({}, registry.get('python'))
  end)
end)

describe('registering the nvim-cmp source', function()
  -- The sole integration point with nvim-cmp, and the only line in the module
  -- that touches it. Stubbed because cmp is not installed here -- which is
  -- also the condition the module has to load under.
  it('hands cmp a source under the name zsnip', function()
    local registered = {}
    package.loaded['cmp'] = {
      register_source = function(name, source)
        registered[name] = source
      end,
    }

    require('zsnip.cmp').register({ limit = 5 })
    package.loaded['cmp'] = nil

    assert.is_not_nil(registered.zsnip)
    assert.are.equal('zsnip', registered.zsnip:get_debug_name())
    assert.are.equal(5, registered.zsnip.opts.limit)
  end)
end)
