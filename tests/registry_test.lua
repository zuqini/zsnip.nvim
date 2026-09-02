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

  -- What the docs have always told people to do -- "point a loader at a
  -- directory" -- with the directory VSCode itself writes: no package.json,
  -- just files named after the filetype they serve.
  it('finds <language>.json in a directory with no manifest', function()
    local dir = helpers.standalone_dir({
      ['python.json'] = { main = { prefix = 'ifmain', body = "if __name__ == '__main__':\n\t$0" } },
      ['lua.json'] = { req = { prefix = 'req', body = "require '$1'" } },
    })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    assert.are.same({ 'ifmain' }, helpers.prefixes(registry.get('python')))
    assert.are.same({ 'req' }, helpers.prefixes(registry.get('lua')))
  end)

  it('splits a .code-snippets file by each snippet scope', function()
    local dir = helpers.standalone_dir({
      ['mine.code-snippets'] = {
        log = { scope = 'javascript, typescript', prefix = 'clg', body = 'console.log($1)' },
        pyd = { scope = 'python', prefix = 'def', body = 'def $1():' },
      },
    })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    assert.are.same({ 'clg' }, helpers.prefixes(registry.get('javascript')))
    assert.are.same({ 'clg' }, helpers.prefixes(registry.get('typescript')))
    assert.are.same({ 'def' }, helpers.prefixes(registry.get('python')))
  end)

  -- One file, several languages: the filetype stamped on each copy has to be
  -- the one that asked, not whichever opened first.
  it('stamps each scope with its own filetype', function()
    local dir = helpers.standalone_dir({
      ['mine.code-snippets'] = {
        log = { scope = 'javascript,typescript', prefix = 'clg', body = 'b' },
      },
    })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    assert.are.equal('javascript', registry.get('javascript')[1].filetype)
    assert.are.equal('typescript', registry.get('typescript')[1].filetype)
  end)

  it('gives an unscoped .code-snippets entry to every filetype', function()
    local dir = helpers.standalone_dir({
      ['global.code-snippets'] = { todo = { prefix = 'todo', body = 'TODO: $1' } },
    })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    assert.are.same({ 'todo' }, helpers.prefixes(registry.get('rust')))
    assert.are.same({ 'todo' }, helpers.prefixes(registry.get('haskell')))
  end)

  -- `scope` only has meaning in a global/project `.code-snippets` file --
  -- VSCode itself does not read it from a manifest-declared file, which is
  -- why packs put harmless TextMate scopes (`text.html`, `source.python`)
  -- in them. A manifest's `language` decides who is served, not `scope`.
  it('serves a manifest-declared file whose entries carry a TextMate scope, not a filetype', function()
    local dir = helpers.vscode_pack({
      html = { div = { scope = 'text.html', prefix = 'div', body = '<div>$0</div>' } },
    })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    assert.are.same({ 'div' }, helpers.prefixes(registry.get('html')))
  end)

  -- Same contract for a loose `<language>.json`: the filename decides, not
  -- an unrelated scope on its entries.
  it('serves <language>.json whose entries carry a TextMate scope, not a filetype', function()
    local dir = helpers.standalone_dir({
      ['html.json'] = { div = { scope = 'text.html', prefix = 'div', body = '<div>$0</div>' } },
    })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    assert.are.same({ 'div' }, helpers.prefixes(registry.get('html')))
  end)

  -- Only `.code-snippets` gets to filter by `scope`: a language a manifest or
  -- filename never declared must still not see it.
  it('still drops a .code-snippets entry scoped to a language other than the one asked about', function()
    local dir = helpers.standalone_dir({
      ['mine.code-snippets'] = { pyd = { scope = 'python', prefix = 'def', body = 'def $1():' } },
    })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    assert.are.same({}, helpers.prefixes(registry.get('lua')))
    assert.are.same({ 'def' }, helpers.prefixes(registry.get('python')))
  end)

  -- friendly-snippets' own shape: one manifest file declared for several
  -- languages at once, entries carrying a TextMate scope that names none of
  -- them. Every declared language must still see it.
  it('serves a shared manifest file to every declared language regardless of scope', function()
    local dir = helpers.vscode_shared_pack(
      { 'markdown', 'gitcommit' },
      { note = { scope = 'text.html', prefix = 'note', body = 'b' } }
    )
    helpers.use_rtp(dir)
    require('zsnip.loaders.from_vscode').lazy_load()

    assert.are.same({ 'note' }, helpers.prefixes(registry.get('markdown')))
    assert.are.same({ 'note' }, helpers.prefixes(registry.get('gitcommit')))
  end)

  -- The global bucket path: a manifest naming the language `all` files under
  -- global_filetype regardless of scope too -- the same manifest/filename
  -- rule applies once the alias resolves the bucket.
  it('serves a manifest entry filed to the global bucket regardless of scope', function()
    require('zsnip.config').setup({ global_filetype = 'global' })
    local dir = helpers.vscode_pack({
      all = { note = { scope = 'text.html', prefix = 'note', body = 'b' } },
    })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    assert.are.same({ 'note' }, helpers.prefixes(registry.get('global')))
  end)

  -- A `.code-snippets` entry whose `scope` literally names the user's custom
  -- global bucket is asked for by that name, not by `all` -- the pack
  -- spelling the registry records is the one the entry actually carries.
  it('serves a .code-snippets entry scoped to a custom global bucket by its own name', function()
    require('zsnip.config').setup({ global_filetype = 'global' })
    local dir = helpers.standalone_dir({
      ['mine.code-snippets'] = { note = { scope = 'global', prefix = 'note', body = 'b' } },
    })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    assert.are.same({ 'note' }, helpers.prefixes(registry.get('global')))
  end)

  -- A manifest is still the authority for the files it names; globbing beside
  -- it must not offer the same file a second time under a name from disk.
  it('does not double up a file a package.json already claimed', function()
    local dir = helpers.vscode_pack({ lua = { req = { prefix = 'req', body = 'b' } } })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    assert.are.same({ 'req' }, helpers.prefixes(registry.get('lua')))
  end)

  it('leaves loose files alone on the runtimepath', function()
    local dir = helpers.standalone_dir({
      ['lua.json'] = { req = { prefix = 'req', body = 'b' } },
    })
    helpers.use_rtp(dir)
    require('zsnip.loaders.from_vscode').lazy_load()

    assert.are.same({}, helpers.prefixes(registry.get('lua')))
  end)

  it('finds snipmate files on the runtimepath', function()
    helpers.use_rtp(helpers.snipmate_pack({ pkl = 'snippet cls\n\tclass $1 {}' }))
    require('zsnip.loaders.from_snipmate').lazy_load()

    assert.are.same({ 'cls' }, helpers.prefixes(registry.get('pkl')))
  end)

  -- snipmate's convention for "every filetype" is `_.snippets` --
  -- honza/vim-snippets ships one -- which is what `global_filetype` already
  -- means here.
  it('files _.snippets under global_filetype', function()
    helpers.use_rtp(helpers.snipmate_pack({ _ = 'snippet todo\n\tTODO: $1' }))
    require('zsnip.loaders.from_snipmate').lazy_load()

    assert.are.same({ 'todo' }, helpers.prefixes(registry.get('lua')))
  end)

  it('files _.snippets under a renamed global_filetype', function()
    require('zsnip.config').setup({ global_filetype = 'global' })
    helpers.use_rtp(helpers.snipmate_pack({ _ = 'snippet todo\n\tTODO: $1' }))
    require('zsnip.loaders.from_snipmate').lazy_load()

    local snippets = registry.get('lua')
    assert.are.equal(1, #snippets)
    assert.are.equal('global', snippets[1].filetype)
  end)

  it('drops _.snippets entirely when global_filetype is disabled', function()
    helpers.use_rtp(helpers.snipmate_pack({ _ = 'snippet todo\n\tTODO: $1' }))
    require('zsnip.config').setup({ global_filetype = false })
    require('zsnip.loaders.from_snipmate').lazy_load()

    assert.are.same({}, helpers.prefixes(registry.get('lua')))
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

  it('accepts a bare string for include and exclude, same as a one-element list', function()
    helpers.use_rtp(helpers.vscode_pack({
      lua = { a = { prefix = 'a', body = 'b' } },
      python = { c = { prefix = 'c', body = 'd' } },
    }))
    require('zsnip.loaders.from_vscode').lazy_load({ include = 'lua' })
    assert.are.same({ 'a' }, helpers.prefixes(registry.get('lua')))
    assert.are.same({}, registry.get('python'))

    helpers.reset()
    require('zsnip.loaders.from_vscode').lazy_load({ exclude = 'lua' })
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

  -- Neovim assigns these itself for some filetypes (javascript.glimmer), and
  -- users set others (yaml.ansible). LuaSnip splits on '.', and zsnip sells
  -- LuaSnip parity.
  it('gives a dotted filetype its own bucket, then each component, then global', function()
    registry.add('yaml.ansible', { { prefix = 'own', body = 'b' } })
    registry.add('yaml', { { prefix = 'yaml_snip', body = 'b' } })
    registry.add('ansible', { { prefix = 'ansible_snip', body = 'b' } })
    registry.add('all', { { prefix = 'global', body = 'b' } })

    assert.are.same(
      { 'own', 'yaml_snip', 'ansible_snip', 'global' },
      helpers.prefixes(registry.get('yaml.ansible'))
    )
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

describe('registry cache invalidation', function()
  it('notices a setup() that lands after the first lookup', function()
    registry.add('javascript', { { prefix = 'js', body = 'b' } })
    registry.add('typescript', { { prefix = 'ts', body = 'b' } })
    registry.add('all', { { prefix = 'global', body = 'b' } })

    assert.are.same({ 'ts', 'global' }, helpers.prefixes(registry.get('typescript')))

    require('zsnip.config').setup({
      extend = { typescript = { 'javascript' } },
      global_filetype = false,
    })

    assert.are.same({ 'ts', 'js' }, helpers.prefixes(registry.get('typescript')))
  end)

  it('notices a config reset just the same', function()
    registry.add('lua', { { prefix = 'own', body = 'b' } })
    registry.add('all', { { prefix = 'global', body = 'b' } })

    require('zsnip.config').setup({ global_filetype = false })
    assert.are.same({ 'own' }, helpers.prefixes(registry.get('lua')))

    require('zsnip.config').reset()
    assert.are.same({ 'own', 'global' }, helpers.prefixes(registry.get('lua')))
  end)
end)

describe('registry.enable', function()
  it('accumulates include across repeated calls rather than replacing it', function()
    helpers.use_rtp(helpers.vscode_pack({
      lua = { a = { prefix = 'lua_snip', body = 'b' } },
      python = { a = { prefix = 'py_snip', body = 'b' } },
      ruby = { a = { prefix = 'rb_snip', body = 'b' } },
    }))
    local loader = require('zsnip.loaders.from_vscode')

    loader.lazy_load({ include = { 'lua' } })
    loader.lazy_load({ include = { 'python' } })

    assert.are.same({ 'lua_snip' }, helpers.prefixes(registry.get('lua')))
    assert.are.same({ 'py_snip' }, helpers.prefixes(registry.get('python')))
    assert.are.same({}, helpers.prefixes(registry.get('ruby')))
  end)

  it('accumulates exclude the same way', function()
    helpers.use_rtp(helpers.vscode_pack({
      lua = { a = { prefix = 'lua_snip', body = 'b' } },
      python = { a = { prefix = 'py_snip', body = 'b' } },
      ruby = { a = { prefix = 'rb_snip', body = 'b' } },
    }))
    local loader = require('zsnip.loaders.from_vscode')

    loader.lazy_load({ exclude = { 'lua' } })
    loader.lazy_load({ exclude = { 'python' } })

    assert.are.same({}, helpers.prefixes(registry.get('lua')))
    assert.are.same({}, helpers.prefixes(registry.get('python')))
    assert.are.same({ 'rb_snip' }, helpers.prefixes(registry.get('ruby')))
  end)

  it('accumulates a scalar include with a later list, not just list with list', function()
    helpers.use_rtp(helpers.vscode_pack({
      lua = { a = { prefix = 'lua_snip', body = 'b' } },
      python = { a = { prefix = 'py_snip', body = 'b' } },
      ruby = { a = { prefix = 'rb_snip', body = 'b' } },
    }))
    local loader = require('zsnip.loaders.from_vscode')

    loader.lazy_load({ include = 'lua' })
    loader.lazy_load({ include = { 'python' } })

    assert.are.same({ 'lua_snip' }, helpers.prefixes(registry.get('lua')))
    assert.are.same({ 'py_snip' }, helpers.prefixes(registry.get('python')))
    assert.are.same({}, helpers.prefixes(registry.get('ruby')))
  end)

  it('copies the include it was handed rather than keeping the caller\'s table', function()
    helpers.use_rtp(helpers.vscode_pack({
      lua = { a = { prefix = 'lua_snip', body = 'b' } },
      python = { a = { prefix = 'py_snip', body = 'b' } },
    }))
    local mine = { 'lua' }
    require('zsnip.loaders.from_vscode').lazy_load({ include = mine })
    mine[1] = 'python'

    assert.are.same({ 'lua_snip' }, helpers.prefixes(registry.get('lua')))
    assert.are.same({}, helpers.prefixes(registry.get('python')))
  end)

  it('does not read a nil include as "everything from now on"', function()
    helpers.use_rtp(helpers.vscode_pack({
      lua = { a = { prefix = 'lua_snip', body = 'b' } },
      python = { a = { prefix = 'py_snip', body = 'b' } },
    }))
    local loader = require('zsnip.loaders.from_vscode')

    loader.lazy_load({ include = { 'lua' } })
    loader.lazy_load({ paths = helpers.tempdir() })

    assert.are.same({}, helpers.prefixes(registry.get('python')))
  end)
end)

describe('registry parse caching', function()
  -- friendly-snippets contributes one file to several languages 19 times over;
  -- `global.json` alone covers six. Cached by path alone, whichever filetype
  -- was looked up first stamps its name onto every copy.
  it('stamps each language onto its own copy of a shared file', function()
    helpers.use_rtp(helpers.vscode_shared_pack({ 'javascript', 'typescript' }, {
      log = { prefix = 'log', body = 'console.log($1)' },
    }))
    require('zsnip.loaders.from_vscode').lazy_load()

    assert.are.equal('typescript', registry.get('typescript')[1].filetype)
    assert.are.equal('javascript', registry.get('javascript')[1].filetype)
  end)

  it('gives the same answer whichever language is asked for first', function()
    helpers.use_rtp(helpers.vscode_shared_pack({ 'javascript', 'typescript' }, {
      log = { prefix = 'log', body = 'console.log($1)' },
    }))
    require('zsnip.loaders.from_vscode').lazy_load()

    assert.are.equal('javascript', registry.get('javascript')[1].filetype)
    assert.are.equal('typescript', registry.get('typescript')[1].filetype)
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

describe('registry sources shared between filetypes', function()
  -- One `.code-snippets` file serves several languages, and each visit hands
  -- back only what is in scope for the one asked about. Deduplicating on the
  -- path alone, a typescript buffer that inherits javascript sees the file
  -- once -- as typescript -- and the javascript snippets in it are gone.
  it('reads a multi-scope file once per language it is reached as', function()
    local dir = helpers.tempdir()
    helpers.write(
      dir .. '/mine.code-snippets',
      vim.json.encode({
        tsonly = { scope = 'typescript', prefix = 'tsx', body = 'TS' },
        jsonly = { scope = 'javascript', prefix = 'jsx', body = 'JS' },
      })
    )
    require('zsnip').setup({ extend = { typescript = { 'javascript' } } })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    local prefixes = helpers.prefixes(registry.get('typescript'))
    assert.contains(prefixes, 'tsx')
    assert.contains(prefixes, 'jsx')
  end)

  it('still offers a shared file only once per language', function()
    local dir = helpers.vscode_shared_pack({ 'lua' }, { one = { prefix = 'a', body = 'b' } })
    helpers.use_rtp(dir)
    require('zsnip.loaders.from_vscode').lazy_load()

    assert.are.same({ 'a' }, helpers.prefixes(registry.get('lua')))
  end)
end)

describe('registry discovery of awkward paths', function()
  -- A configured path is data, not a pattern. glob() treats a `[` in one as
  -- syntax and matches nothing at all -- for that whole directory, silently.
  it('reads a directory whose name holds glob metacharacters', function()
    local dir = helpers.tempdir() .. '/snip[s]'
    helpers.write(dir .. '/lua.json', vim.json.encode({ one = { prefix = 'a', body = 'b' } }))
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    assert.are.same({ 'a' }, helpers.prefixes(registry.get('lua')))
  end)

  it('does not mind a configured path that is not there', function()
    require('zsnip.loaders.from_vscode').lazy_load({ paths = '/nope/not/here' })
    assert.are.same({}, registry.get('lua'))
  end)

  it('reads snipmate files loose and one directory down', function()
    local dir = helpers.tempdir()
    helpers.write(dir .. '/lua.snippets', 'snippet loose\n\tbody')
    helpers.write(dir .. '/python/whatever.snippets', 'snippet nested\n\tbody')
    require('zsnip.loaders.from_snipmate').lazy_load({ paths = dir })

    assert.are.same({ 'loose' }, helpers.prefixes(registry.get('lua')))
    assert.are.same({ 'nested' }, helpers.prefixes(registry.get('python')))
  end)

  -- A stow/dotfiles setup routes every file it manages through a symlink, so
  -- ~/.config/nvim/snippets/lua.json is really a link into the dotfiles repo.
  it('follows a symlinked VSCode snippet file under paths', function()
    local real = helpers.tempdir()
    helpers.write(real .. '/lua.json', vim.json.encode({ req = { prefix = 'req', body = 'b' } }))

    local paths_dir = helpers.tempdir()
    assert(vim.uv.fs_symlink(real .. '/lua.json', paths_dir .. '/lua.json'))
    require('zsnip.loaders.from_vscode').lazy_load({ paths = paths_dir })

    assert.are.same({ 'req' }, helpers.prefixes(registry.get('lua')))
  end)

  it('follows a symlinked snipmate snippet file under paths', function()
    local real = helpers.tempdir()
    helpers.write(real .. '/lua.snippets', 'snippet cls\n\tclass $1 {}')

    local paths_dir = helpers.tempdir()
    assert(vim.uv.fs_symlink(real .. '/lua.snippets', paths_dir .. '/lua.snippets'))
    require('zsnip.loaders.from_snipmate').lazy_load({ paths = paths_dir })

    assert.are.same({ 'cls' }, helpers.prefixes(registry.get('lua')))
  end)

  it('descends into a symlinked directory of snipmate snippet files', function()
    local real_dir = helpers.tempdir()
    helpers.write(real_dir .. '/misc.snippets', 'snippet cls\n\tclass $1 {}')

    local paths_dir = helpers.tempdir()
    assert(vim.uv.fs_symlink(real_dir, paths_dir .. '/python'))
    require('zsnip.loaders.from_snipmate').lazy_load({ paths = paths_dir })

    assert.are.same({ 'cls' }, helpers.prefixes(registry.get('python')))
  end)
end)

describe('registry.dropped', function()
  -- The other half of "my snippet is missing": found, then discarded for being
  -- one vim.snippet.expand() would raise on. Nothing else reports it.
  it('counts the bodies that were thrown away', function()
    assert.are.equal(0, registry.dropped())
    registry.add('lua', {
      { prefix = 'good', body = 'fine' },
      { prefix = 'bad', body = '${' },
      { prefix = 'worse', body = '$0$0' },
    })

    assert.are.same({ 'good' }, helpers.prefixes(registry.get('lua')))
    assert.are.equal(2, registry.dropped())
  end)

  -- A rescan re-reads the packs, so the count from them has to start over --
  -- but it does not re-read what a config registered, so that half must not.
  it('starts the file-derived count over on a rescan, and keeps the rest', function()
    local dir = helpers.vscode_pack({ lua = { bad = { prefix = 'x', body = '${' } } })
    helpers.use_rtp(dir)
    require('zsnip.loaders.from_vscode').lazy_load()
    registry.add('lua', { { prefix = 'alsobad', body = '$0$0' } })

    registry.get('lua')
    assert.are.equal(2, registry.dropped())

    registry.invalidate()
    assert.are.equal(1, registry.dropped())
  end)

  -- One `.code-snippets` file scoped to several languages is one bad body,
  -- not one per language it happens to serve.
  it('counts a shared file dropping one body once, not once per language', function()
    local dir = helpers.tempdir()
    helpers.write(
      dir .. '/mine.code-snippets',
      vim.json.encode({ bad = { scope = 'javascript,typescript', prefix = 'x', body = '${' } })
    )
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    registry.get('javascript')
    registry.get('typescript')

    assert.are.equal(1, registry.dropped())
  end)

  -- A per-entry `scope` means different languages see different entry sets,
  -- so a bad body scoped to only one of them must be counted once regardless
  -- of which language happens to be opened -- and therefore parsed -- first.
  it('counts a body scoped to one language of a mixed file the same, lua opened first', function()
    local dir = helpers.standalone_dir({
      ['mine.code-snippets'] = {
        good = { scope = 'lua', prefix = 'good', body = 'fine' },
        bad = { scope = 'python', prefix = 'bad', body = '${1:a} ${1:b}' },
      },
    })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    registry.get('lua')
    registry.get('python')

    assert.are.equal(1, registry.dropped())
  end)

  it('counts a body scoped to one language of a mixed file the same, python opened first', function()
    local dir = helpers.standalone_dir({
      ['mine.code-snippets'] = {
        good = { scope = 'lua', prefix = 'good', body = 'fine' },
        bad = { scope = 'python', prefix = 'bad', body = '${1:a} ${1:b}' },
      },
    })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    registry.get('python')
    registry.get('lua')

    assert.are.equal(1, registry.dropped())
  end)
end)

describe('registry.loader', function()
  it('hands back what a loader was registered with', function()
    assert.is_nil(registry.loader('vscode'))

    require('zsnip.loaders.from_vscode').lazy_load({ paths = '/tmp/one', exclude = { 'lua' } })
    local opts = registry.loader('vscode')

    assert.are.same({ '/tmp/one' }, opts.paths)
    assert.are.same({ 'lua' }, opts.exclude)
  end)

  -- A re-run config -- lazy_load { paths = dir } called twice -- must not
  -- leave { dir, dir }: :checkhealth would list the same path twice.
  it('does not duplicate a path registered more than once', function()
    require('zsnip.loaders.from_vscode').lazy_load({ paths = '/tmp/one' })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = '/tmp/one' })

    assert.are.same({ '/tmp/one' }, registry.loader('vscode').paths)
  end)

  -- `~/x` and its expansion are the same directory, not the same string;
  -- :checkhealth would otherwise list both.
  it('does not duplicate a path against its normalized form', function()
    local expanded = vim.fs.normalize('~/zsnip-test-path')
    require('zsnip.loaders.from_vscode').lazy_load({ paths = '~/zsnip-test-path' })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = expanded })

    assert.are.same({ expanded }, registry.loader('vscode').paths)
  end)
end)

describe('registry definition dedupe', function()
  -- friendly-snippets' real shape: a manifest lists one file under several
  -- languages, including the global one, so the file is reachable through
  -- both its own bucket and the global bucket for the same lookup.
  it('serves a manifest file listed under its own language and the global one only once', function()
    local dir = helpers.vscode_shared_pack({ 'markdown', 'all' }, { note = { prefix = 'note', body = 'b' } })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    local snippets = registry.get('markdown')
    assert.are.equal(1, #snippets)
    assert.are.equal('markdown', snippets[1].filetype)
  end)

  -- Reached only through the global bucket -- never doubled to begin with --
  -- but pinned so the dedupe above cannot start dropping the entry instead.
  it('still reaches that file through the global bucket alone', function()
    local dir = helpers.vscode_shared_pack({ 'markdown', 'all' }, { note = { prefix = 'note', body = 'b' } })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    local snippets = registry.get('python')
    assert.are.equal(1, #snippets)
    assert.are.equal('all', snippets[1].filetype)
  end)

  it('serves a scope naming two languages, one of them global, only once', function()
    local dir = helpers.standalone_dir({
      ['mine.code-snippets'] = { x = { scope = 'lua, all', prefix = 'x', body = 'b' } },
    })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    local snippets = registry.get('lua')
    assert.are.equal(1, #snippets)
    assert.are.equal('lua', snippets[1].filetype)
  end)

  -- parse() keeps an unscoped entry for every language it is asked about, so
  -- a mixed file filed under both its own bucket and the global one served
  -- the unscoped entry twice.
  it('serves the unscoped entry of a mixed file only once', function()
    local dir = helpers.standalone_dir({
      ['mine.code-snippets'] = {
        scoped = { scope = 'lua', prefix = 'onlylua', body = 'b' },
        free = { prefix = 'everyone', body = 'b' },
      },
    })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    local prefixes = helpers.prefixes(registry.get('lua'))
    assert.are.equal(2, #prefixes)
    assert.contains(prefixes, 'onlylua')
    assert.contains(prefixes, 'everyone')
  end)
end)

describe('registry.components', function()
  it('is the exact filetype, then each dot-separated component', function()
    assert.are.same({ 'yaml.ansible', 'yaml', 'ansible' }, registry.components('yaml.ansible'))
  end)

  it('is just the filetype when it has no dot', function()
    assert.are.same({ 'lua' }, registry.components('lua'))
  end)

  it('does not choke on an empty filetype', function()
    assert.are.same({ '' }, registry.components(''))
  end)
end)

describe('registry global alias for vscode "all"', function()
  it('files a scope literally named all under global_filetype', function()
    require('zsnip.config').setup({ global_filetype = 'global' })
    local dir = helpers.standalone_dir({
      ['mine.code-snippets'] = { x = { scope = 'all', prefix = 'x', body = 'b' } },
    })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    local snippets = registry.get('lua')
    assert.are.equal(1, #snippets)
    assert.are.equal('global', snippets[1].filetype)
  end)

  it('files a manifest language literally named all under global_filetype', function()
    require('zsnip.config').setup({ global_filetype = 'global' })
    local dir = helpers.tempdir()
    helpers.write(dir .. '/snippets/x.json', vim.json.encode({ note = { prefix = 'note', body = 'b' } }))
    helpers.write(
      dir .. '/package.json',
      vim.json.encode({ contributes = { snippets = { { language = 'all', path = './snippets/x.json' } } } })
    )
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    local snippets = registry.get('lua')
    assert.are.equal(1, #snippets)
    assert.are.equal('global', snippets[1].filetype)
  end)

  it('drops a scope literally named all when global_filetype is disabled', function()
    require('zsnip.config').setup({ global_filetype = false })
    local dir = helpers.standalone_dir({
      ['mine.code-snippets'] = { x = { scope = 'all', prefix = 'x', body = 'b' } },
    })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = dir })

    assert.are.same({}, registry.get('lua'))
  end)

  -- A mixed file the parser cannot see the bucket for: one entry scoped to a
  -- real language, one unscoped, one scoped to the literal `all`. The parser
  -- stays a pure scope matcher, so filing the `all` entry under whichever
  -- bucket global_filetype names -- or dropping it -- is entirely
  -- registry.lua's job.
  local function mixed_pack()
    return helpers.standalone_dir({
      ['mine.code-snippets'] = {
        scoped = { scope = 'lua', prefix = 'onlylua', body = 'b' },
        free = { prefix = 'everyone', body = 'b' },
        everywhere = { scope = 'all', prefix = 'viaall', body = 'b' },
      },
    })
  end

  it('drops the all entry of a mixed file when global_filetype is disabled, keeping the rest', function()
    require('zsnip.config').setup({ global_filetype = false })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = mixed_pack() })

    local prefixes = helpers.prefixes(registry.get('lua'))
    assert.are.equal(2, #prefixes)
    assert.contains(prefixes, 'onlylua')
    assert.contains(prefixes, 'everyone')
  end)

  it('drops the all entry of a mixed file when the global bucket is excluded, keeping the rest', function()
    require('zsnip.config').setup({ global_filetype = 'global' })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = mixed_pack(), exclude = { 'global' } })

    local prefixes = helpers.prefixes(registry.get('lua'))
    assert.are.equal(2, #prefixes)
    assert.contains(prefixes, 'onlylua')
    assert.contains(prefixes, 'everyone')
  end)

  it('serves the all entry of a mixed file to an unrelated language, stamped with the global bucket', function()
    require('zsnip.config').setup({ global_filetype = 'global' })
    require('zsnip.loaders.from_vscode').lazy_load({ paths = mixed_pack() })

    local viaall = helpers.find(registry.get('python'), 'viaall')
    assert.is_not_nil(viaall)
    assert.are.equal('global', viaall.filetype)
  end)
end)

describe('registry.kinds', function()
  it('names the loader kinds in the order they are scanned', function()
    assert.are.same({ 'vscode', 'snipmate' }, registry.kinds())
  end)
end)
