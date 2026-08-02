local helpers = require('helpers')
local registry = require('zsnip.registry')

before_each(helpers.reset)
after_each(helpers.cleanup)

describe('registry discovery', function()
  it('finds VSCode packages on the runtimepath', function()
    helpers.use_rtp(helpers.vscode_pack({
      lua = { req = { prefix = 'req', body = "require '$1'" } },
    }))
    require('zsnip.loaders.from_vscode').lazy_load()

    assert.are.same({ 'req' }, helpers.prefixes(registry.get('lua')))
  end)

  it('finds snipmate files on the runtimepath', function()
    helpers.use_rtp(helpers.snipmate_pack({ pkl = 'snippet cls\n\tclass $1 {}' }))
    require('zsnip.loaders.from_snipmate').lazy_load()

    assert.are.same({ 'cls' }, helpers.prefixes(registry.get('pkl')))
  end)

  it('takes the filetype from the directory for snippets/<ft>/<name>.snippets', function()
    local dir = helpers.tempdir()
    helpers.write(dir .. '/snippets/pkl/misc.snippets', 'snippet cls\n\tclass $1 {}')
    helpers.use_rtp(dir)
    require('zsnip.loaders.from_snipmate').lazy_load()

    assert.are.same({ 'cls' }, helpers.prefixes(registry.get('pkl')))
  end)

  it('reads nothing until a filetype asks for it', function()
    helpers.use_rtp(helpers.vscode_pack({ lua = { req = { prefix = 'req', body = 'b' } } }))
    require('zsnip.loaders.from_vscode').lazy_load()

    assert.are.same({}, registry.get('python'))
    assert.are.same({ 'req' }, helpers.prefixes(registry.get('lua')))
  end)

  it('ignores a format whose loader was never registered', function()
    helpers.use_rtp(helpers.snipmate_pack({ lua = 'snippet cls\n\tclass' }))
    require('zsnip.loaders.from_vscode').lazy_load()

    assert.are.same({}, registry.get('lua'))
  end)

  it('reads directories passed as paths', function()
    local dir = helpers.tempdir()
    helpers.write(dir .. '/snippets/lua.json', vim.json.encode({ a = { prefix = 'a', body = 'b' } }))
    helpers.write(dir .. '/package.json', vim.json.encode({
      contributes = { snippets = { { language = 'lua', path = './snippets/lua.json' } } },
    }))
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    assert.are.same({ 'a' }, helpers.prefixes(registry.get('lua')))
  end)

  it('honours include and exclude', function()
    helpers.use_rtp(helpers.vscode_pack({
      lua = { a = { prefix = 'a', body = 'b' } },
      python = { c = { prefix = 'c', body = 'd' } },
    }))
    require('zsnip.loaders.from_vscode').lazy_load({ include = { 'lua' } })
    assert.are.same({ 'a' }, helpers.prefixes(registry.get('lua')))
    assert.are.same({}, registry.get('python'))

    helpers.reset()
    require('zsnip.loaders.from_vscode').lazy_load({ exclude = { 'lua' } })
    assert.are.same({}, registry.get('lua'))
    assert.are.same({ 'c' }, helpers.prefixes(registry.get('python')))
  end)

  it('rescans when the runtimepath changes', function()
    helpers.use_rtp(helpers.vscode_pack({ lua = { a = { prefix = 'a', body = 'b' } } }))
    require('zsnip.loaders.from_vscode').lazy_load()
    assert.are.same({ 'a' }, helpers.prefixes(registry.get('lua')))

    -- A plugin that loads on a filetype joins the runtimepath after we have
    -- already answered for that filetype.
    helpers.use_rtp(helpers.vscode_pack({ lua = { late = { prefix = 'late', body = 'b' } } }))
    assert.are.same({ 'late', 'a' }, helpers.prefixes(registry.get('lua')))
  end)
end)

describe('registry resolution', function()
  it('adds the global bucket to every filetype', function()
    helpers.use_rtp(helpers.vscode_pack({
      lua = { own = { prefix = 'own', body = 'b' } },
      all = { every = { prefix = 'every', body = 'b' } },
    }))
    require('zsnip.loaders.from_vscode').lazy_load()

    assert.are.same({ 'own', 'every' }, helpers.prefixes(registry.get('lua')))
    assert.are.same({ 'every' }, helpers.prefixes(registry.get('python')))
  end)

  it('can be told not to have a global bucket', function()
    helpers.use_rtp(helpers.vscode_pack({ all = { every = { prefix = 'every', body = 'b' } } }))
    require('zsnip.config').setup({ global_filetype = false })
    require('zsnip.loaders.from_vscode').lazy_load()

    assert.are.same({}, registry.get('lua'))
  end)

  it('inherits from filetypes declared through the API', function()
    helpers.use_rtp(helpers.vscode_pack({
      javascript = { js = { prefix = 'js', body = 'b' } },
      typescript = { ts = { prefix = 'ts', body = 'b' } },
    }))
    require('zsnip.loaders.from_vscode').lazy_load()
    registry.extend('typescript', 'javascript')

    assert.are.same({ 'ts', 'js' }, helpers.prefixes(registry.get('typescript')))
    assert.are.same({ 'js' }, helpers.prefixes(registry.get('javascript')))
  end)

  it('inherits from filetypes declared in setup()', function()
    helpers.use_rtp(helpers.vscode_pack({
      javascript = { js = { prefix = 'js', body = 'b' } },
      typescript = { ts = { prefix = 'ts', body = 'b' } },
    }))
    require('zsnip.config').setup({ extend = { typescript = { 'javascript' } } })
    require('zsnip.loaders.from_vscode').lazy_load()

    assert.are.same({ 'ts', 'js' }, helpers.prefixes(registry.get('typescript')))
  end)

  it('inherits from an extends line in a snipmate file', function()
    helpers.use_rtp(helpers.snipmate_pack({
      html = 'snippet div\n\t<div>$1</div>',
      eruby = 'extends html\nsnippet erb\n\t<%= $1 %>',
    }))
    require('zsnip.loaders.from_snipmate').lazy_load()

    assert.are.same({ 'erb', 'div' }, helpers.prefixes(registry.get('eruby')))
  end)

  it('survives an inheritance cycle', function()
    helpers.use_rtp(helpers.vscode_pack({
      a = { one = { prefix = 'one', body = 'b' } },
      b = { two = { prefix = 'two', body = 'b' } },
    }))
    require('zsnip.loaders.from_vscode').lazy_load()
    registry.extend('a', 'b')
    registry.extend('b', 'a')

    assert.are.same({ 'one', 'two' }, helpers.prefixes(registry.get('a')))
  end)

  it('puts snippets added from Lua ahead of the ones read from disk', function()
    helpers.use_rtp(helpers.vscode_pack({ lua = { packed = { prefix = 'packed', body = 'b' } } }))
    require('zsnip.loaders.from_vscode').lazy_load()
    registry.add('lua', { { prefix = 'mine', body = 'b' } })

    assert.are.same({ 'mine', 'packed' }, helpers.prefixes(registry.get('lua')))
  end)

  it('records the filetype a snippet came from', function()
    helpers.use_rtp(helpers.vscode_pack({
      lua = { own = { prefix = 'own', body = 'b' } },
      all = { every = { prefix = 'every', body = 'b' } },
    }))
    require('zsnip.loaders.from_vscode').lazy_load()

    local snippets = registry.get('lua')
    assert.are.equal('lua', helpers.find(snippets, 'own').filetype)
    assert.are.equal('all', helpers.find(snippets, 'every').filetype)
  end)

  it('reports which filetypes it knows about', function()
    helpers.use_rtp(helpers.vscode_pack({ lua = { a = { prefix = 'a', body = 'b' } } }))
    require('zsnip.loaders.from_vscode').lazy_load()
    registry.add('rust', { { prefix = 'r', body = 'b' } })

    local available = registry.available()
    assert.is_not_nil(available.lua)
    assert.is_not_nil(available.rust)
  end)
end)

describe('registry normalization', function()
  it('drops bodies the engine cannot parse', function()
    helpers.use_rtp(helpers.vscode_pack({
      lua = {
        good = { prefix = 'good', body = 'local ${1:x}' },
        bad = { prefix = 'bad', body = '${1:' },
      },
    }))
    require('zsnip.loaders.from_vscode').lazy_load()

    assert.are.same({ 'good' }, helpers.prefixes(registry.get('lua')))
  end)

  it('makes a placeholder on the exit point reachable', function()
    registry.add('lua', { { prefix = 'a', body = '${1:x} ${0:done}' } })
    assert.are.equal('${1:x} ${2:done}', helpers.find(registry.get('lua'), 'a').body)
  end)

  it('drops entries without a usable trigger', function()
    registry.add('lua', {
      { prefix = 'ok', body = 'b' },
      { prefix = '', body = 'b' },
      { prefix = 'no body' },
    })
    assert.are.same({ 'ok' }, helpers.prefixes(registry.get('lua')))
  end)

  it('leaves a function body to be called later', function()
    registry.add('lua', { { prefix = 'a', body = function() return 'x' end } })
    assert.are.equal('function', type(helpers.find(registry.get('lua'), 'a').body))
  end)
end)

describe('registry.reload', function()
  it('forgets files but keeps snippets added from Lua', function()
    helpers.use_rtp(helpers.vscode_pack({ lua = { packed = { prefix = 'packed', body = 'b' } } }))
    require('zsnip.loaders.from_vscode').lazy_load()
    registry.add('lua', { { prefix = 'mine', body = 'b' } })
    registry.get('lua')

    registry.invalidate()
    assert.are.same({ 'mine', 'packed' }, helpers.prefixes(registry.get('lua')))
  end)
end)
