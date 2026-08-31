local helpers = require('helpers')
local registry = require('zsnip.registry')
local zsnip = require('zsnip')

---@type integer?
local bufnr = nil

before_each(function()
  helpers.reset()
  -- The trigger sits *behind* the cursor, so these tests need the cursor one
  -- past the last character -- where insert mode puts it, and where normal
  -- mode clamps it back from unless 'virtualedit' allows it. typed() saves
  -- and cleanup() restores it.
  bufnr = helpers.typed('lua')
end)

after_each(function()
  -- cleanup() stops the snippet session first, which needs bufnr still
  -- current -- so it has to run before the buffer behind it is gone.
  helpers.cleanup()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end)

---@param line string
local function type_line(line)
  bufnr = helpers.typed('lua', line)
end

describe('zsnip.match', function()
  it('finds the trigger ending at the cursor', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    type_line('req')

    assert.are.equal('req', zsnip.match().prefix)
    assert.is_true(zsnip.expandable())
  end)

  it('prefers the longest trigger', function()
    registry.add('lua', { { prefix = 'fn', body = 'short' }, { prefix = 'afn', body = 'long' } })
    type_line('afn')

    assert.are.equal('afn', zsnip.match().prefix)
  end)

  it('will not fire a word trigger inside a word', function()
    registry.add('lua', { { prefix = 'ax', body = 'b' } })
    type_line('max')

    assert.is_nil(zsnip.match())
  end)

  -- The byte before 'ax' here is the continuation byte of 'é', not a space --
  -- [%w_] alone is ASCII-only and would call that a word boundary, firing the
  -- trigger in the middle of a word same as 'max' does above.
  it('will not fire a word trigger inside a multi-byte word', function()
    registry.add('lua', { { prefix = 'ax', body = 'b' } })
    type_line('éax')

    assert.is_nil(zsnip.match())
  end)

  it('still fires after a symbol', function()
    registry.add('lua', { { prefix = 'ax', body = 'b' } })
    type_line('(ax')

    assert.are.equal('ax', zsnip.match().prefix)
  end)

  -- A trigger that itself starts with a multi-byte letter is still a keyword
  -- trigger: [%w_] alone is ASCII-only and would call 'é' a symbol, letting
  -- it fire inside a word the way only a symbol trigger should.
  it('will not fire a multi-byte-leading trigger inside a word', function()
    registry.add('lua', { { prefix = 'éa', body = 'b' } })
    type_line('xéa')

    assert.is_nil(zsnip.match())
  end)

  it('still fires a multi-byte-leading trigger after a symbol', function()
    registry.add('lua', { { prefix = 'éa', body = 'b' } })
    type_line('(éa')

    assert.are.equal('éa', zsnip.match().prefix)
  end)

  it('fires a symbol trigger anywhere', function()
    registry.add('lua', { { prefix = '#!', body = 'b' } })
    type_line('x#!')

    assert.are.equal('#!', zsnip.match().prefix)
  end)

  it('finds nothing when the cursor follows something else', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    type_line('other ')

    assert.is_nil(zsnip.match())
    assert.is_false(zsnip.expandable())
  end)
end)

describe('zsnip.expand', function()
  it('replaces the trigger with the snippet', function()
    registry.add('lua', { { prefix = 'req', body = 'require' } })
    type_line('local x = req')

    assert.is_true(zsnip.expand())
    assert.are.equal('local x = require', vim.api.nvim_buf_get_lines(0, 0, -1, false)[1])
  end)

  it('resolves variables on the way in', function()
    registry.add('lua', { { prefix = 'year', body = '$CURRENT_YEAR' } })
    type_line('year')

    assert.is_true(zsnip.expand())
    assert.are.equal(os.date('%Y'), vim.api.nvim_buf_get_lines(0, 0, -1, false)[1])
  end)

  it('does nothing without a trigger', function()
    type_line('nothing')
    assert.is_false(zsnip.expand())
    assert.are.equal('nothing', vim.api.nvim_buf_get_lines(0, 0, -1, false)[1])
  end)

  it('expands a snippet handed to it directly', function()
    type_line('')
    assert.is_true(zsnip.expand_snippet({ prefix = 'x', body = 'inserted' }))
    assert.are.equal('inserted', vim.api.nvim_buf_get_lines(0, 0, -1, false)[1])
  end)

  it('refuses a snippet whose body cannot be produced', function()
    assert.is_false(zsnip.expand_snippet({ prefix = 'x', body = function() return nil end }))
  end)

  -- An unregistered table has no `filetype` stamp, so nothing has normalized
  -- it yet -- expand() would otherwise raise on a body the grammar rejects,
  -- rather than reporting it the way every other unusable snippet is.
  it('refuses rather than raises on an unparseable body handed to it directly', function()
    type_line('')
    assert.is_false(zsnip.expand_snippet({ prefix = 'x', body = '${' }))
  end)

  it('renumbers the final tabstop of a body handed to it directly', function()
    type_line('')
    assert.is_true(zsnip.expand_snippet({ prefix = 'x', body = 'a ${0:foo}' }))
    assert.is_true(zsnip.active())
  end)

  -- A body that is only a comment variable can resolve to '' -- here,
  -- $BLOCK_COMMENT_START outside a block comment -- and vim.snippet.expand()
  -- raises on ''. The trigger must stay put rather than being deleted ahead
  -- of a raise.
  it('refuses a trigger whose body resolves to nothing', function()
    local saved = vim.bo.commentstring
    vim.bo.commentstring = '-- %s'
    registry.add('lua', { { prefix = 'req', body = '$BLOCK_COMMENT_START' } })
    type_line('req')

    assert.is_false(zsnip.expand())
    assert.are.equal('req', vim.api.nvim_buf_get_lines(0, 0, -1, false)[1])

    vim.bo.commentstring = saved
  end)
end)

describe('zsnip session wrappers', function()
  it('reports no session when there is none', function()
    assert.is_false(zsnip.active())
    assert.is_false(zsnip.jumpable(1))
    assert.is_false(zsnip.jump(1))
  end)

  it('falls back from expand to jump', function()
    type_line('nothing')
    assert.is_false(zsnip.expand_or_jump())
  end)
end)

describe('the public surface', function()
  it('exposes what the docs promise', function()
    for _, name in ipairs({
      'setup', 'add_snippets', 'filetype_extend', 'get', 'available', 'completion_items',
      'start_lsp_server', 'stop_lsp_server', 'resolve', 'reload', 'match', 'expandable', 'expand',
      'expand_snippet', 'expand_or_jump', 'jump', 'jumpable', 'active', 'stop',
    }) do
      assert.are.equal('function', type(zsnip[name]), name .. ' is missing')
    end
  end)

  it('defaults get() to the current buffer', function()
    registry.add('lua', { { prefix = 'a', body = 'b' } })
    assert.are.same({ 'a' }, helpers.prefixes(zsnip.get()))
  end)

  -- The registry hands out the list it caches, so an introspection call that
  -- returned it directly would let a caller's sort or filter rewrite what
  -- every later lookup sees.
  it('hands out a list the caller can rearrange', function()
    registry.add('lua', { { prefix = 'a', body = 'b' }, { prefix = 'c', body = 'b' } })

    local snippets = zsnip.get('lua')
    table.remove(snippets, 1)
    assert.are.same({ 'a', 'c' }, helpers.prefixes(zsnip.get('lua')))

    local available = zsnip.available()
    table.remove(available.lua, 1)
    assert.are.same({ 'a', 'c' }, helpers.prefixes(zsnip.available().lua))
  end)

  -- The list is a copy; the snippets in it are not, and deliberately so --
  -- expand_snippet() takes an entry from here straight back.
  it('shares the snippets themselves', function()
    registry.add('lua', { { prefix = 'a', body = 'b' } })
    assert.are.equal(zsnip.get('lua')[1], zsnip.get('lua')[1])
  end)

  it('creates :ZSnip on setup', function()
    zsnip.setup()
    assert.is_not_nil(vim.api.nvim_get_commands({})['ZSnip'])

    vim.api.nvim_del_user_command('ZSnip')
  end)

  it('leaves the command out when asked to', function()
    zsnip.setup({ command = false })
    assert.is_nil(vim.api.nvim_get_commands({})['ZSnip'])
  end)

  -- Under a lazy plugin manager the second setup() is the user's and the first
  -- was a dependency's default, so `command = false` has to be able to undo
  -- one that already ran -- not merely decline to create another.
  it('removes a command an earlier setup created', function()
    zsnip.setup()
    assert.is_not_nil(vim.api.nvim_get_commands({})['ZSnip'])

    zsnip.setup({ command = false })
    assert.is_nil(vim.api.nvim_get_commands({})['ZSnip'])
  end)
end)

describe('the public surface delegates', function()
  it('carries a version', function()
    assert.is_string(zsnip.version)
    assert.is_truthy(zsnip.version:match('^%d+%.%d+%.%d+$'))
  end)

  -- These delegate to a module each. A mis-wired delegation -- reload() calling
  -- registry.clear() rather than invalidate(), say -- would leave every
  -- existence check green and silently discard the user's own snippets.
  it('delegates add_snippets and filetype_extend', function()
    zsnip.add_snippets('lua', { { prefix = 'own', body = 'b' } })
    zsnip.add_snippets('all', { { prefix = 'global', body = 'b' } })
    zsnip.filetype_extend('lua', 'python')
    zsnip.add_snippets('python', { { prefix = 'inherited', body = 'b' } })

    local prefixes = helpers.prefixes(zsnip.get('lua'))
    assert.contains(prefixes, 'own')
    assert.contains(prefixes, 'inherited')
    assert.contains(prefixes, 'global')
  end)

  it('delegates completion_items', function()
    zsnip.add_snippets('lua', { { prefix = 'req', body = "require '$1'" } })
    local items = zsnip.completion_items({ filetype = 'lua' })

    assert.are.equal(1, #items)
    assert.are.equal('req', items[1].label)
  end)

  it('delegates resolve', function()
    assert.are.equal(os.date('%Y'), zsnip.resolve('$CURRENT_YEAR'))
  end)

  -- reload() must forget the packs and keep what a config registered.
  it('delegates reload without discarding registered snippets', function()
    local dir = helpers.vscode_pack({ lua = { one = { prefix = 'from_pack', body = 'b' } } })
    helpers.use_rtp(dir)
    require('zsnip.loaders.from_vscode').lazy_load()
    zsnip.add_snippets('lua', { { prefix = 'from_config', body = 'b' } })
    assert.are.equal(2, #zsnip.get('lua'))

    zsnip.reload()

    assert.contains(helpers.prefixes(zsnip.get('lua')), 'from_config')
    assert.contains(helpers.prefixes(zsnip.get('lua')), 'from_pack')
  end)

  it('delegates start_lsp_server and stop_lsp_server', function()
    local lsp = require('zsnip.lsp')
    assert.is_false(lsp.started())

    zsnip.start_lsp_server({ name = 'zsnip_api_test' })
    assert.is_true(lsp.started())

    zsnip.stop_lsp_server()
    assert.is_false(lsp.started())
  end)

  it('delegates stop to the session', function()
    zsnip.add_snippets('lua', { { prefix = 'req', body = "require '${1:mod}'" } })
    type_line('req')
    assert.is_true(zsnip.expand())
    assert.is_true(zsnip.active())

    zsnip.stop()
    assert.is_false(zsnip.active())
  end)
end)

describe('zsnip.setup validation', function()
  ---@return string[]
  local function warnings(opts)
    return helpers.notifications(function()
      zsnip.setup(opts)
    end)
  end

  -- A merged-in typo is a silent no-op that reads exactly like the option not
  -- working.
  it('names an option it does not know', function()
    local said = warnings({ max_item = 50 })
    assert.are.equal(1, #said)
    assert.is_truthy(said[1]:match('unknown option "max_item"'))
  end)

  it('names an option of the wrong type', function()
    local said = warnings({ max_items = 'lots' })
    assert.are.equal(1, #said)
    assert.is_truthy(said[1]:match('max_items should be number, got string'))
  end)

  it('says nothing about a config that is right', function()
    assert.are.same({}, warnings({
      extend = { lua = { 'python' } },
      global_filetype = false,
      max_items = 10,
      documentation = false,
      command = false,
    }))
  end)

  -- One wrong option must not cost the other four.
  it('keeps the rest of a config that has one bad key', function()
    warnings({ max_items = 7, nonsense = true })
    assert.are.equal(7, require('zsnip.config').options.max_items)
  end)

  -- A wrong-typed value used to be warned about and then merged in anyway --
  -- max_items = 'lots' made every completion raise, rather than falling back
  -- to the default the warning implied it would.
  it('falls back to the default rather than applying a wrong-typed value', function()
    warnings({ max_items = 'lots' })
    assert.are.equal(100, require('zsnip.config').options.max_items)
  end)

  -- A fractional or negative max_items used to reach matchfuzzy() as-is and
  -- raise E475 on every completion with a prefix, or reach it as a limit
  -- matchfuzzy silently returns zero items for.
  it('rejects a fractional or negative max_items but keeps 0, 3 and math.huge', function()
    local said = warnings({ max_items = 2.5 })
    assert.are.equal(1, #said)
    assert.is_truthy(said[1]:match('max_items should be a non%-negative whole number or math.huge, got 2.5'))
    assert.are.equal(100, require('zsnip.config').options.max_items)

    for _, value in ipairs({ -1, -math.huge, 2.5 }) do
      local rejected = warnings({ max_items = value })
      assert.are.equal(1, #rejected, ('max_items = %s should warn'):format(value))
      assert.are.equal(100, require('zsnip.config').options.max_items)
    end

    for _, value in ipairs({ 0, 3, math.huge }) do
      assert.are.same({}, warnings({ max_items = value }))
      assert.are.equal(value, require('zsnip.config').options.max_items)
    end
  end)

  it('falls back to the default rather than applying global_filetype = true', function()
    local said = warnings({ global_filetype = true })
    assert.are.equal(1, #said)
    assert.is_truthy(said[1]:match('global_filetype should be string or false, got true'))
    assert.are.equal('all', require('zsnip.config').options.global_filetype)
  end)
end)
