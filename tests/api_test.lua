local helpers = require('helpers')
local registry = require('zsnip.registry')
local zsnip = require('zsnip')

---@type integer?
local bufnr = nil
---@type string?
local saved_virtualedit = nil

before_each(function()
  helpers.reset()
  bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].filetype = 'lua'
  vim.api.nvim_set_current_buf(bufnr)
  -- The trigger sits *behind* the cursor, so these tests need the cursor one
  -- past the last character -- where insert mode puts it, and where normal
  -- mode clamps it back from unless 'virtualedit' allows it.
  saved_virtualedit = vim.o.virtualedit
  vim.o.virtualedit = 'onemore'
end)

after_each(function()
  vim.o.virtualedit = saved_virtualedit
  vim.snippet.stop()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
  helpers.cleanup()
end)

---@param line string
local function type_line(line)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
  vim.api.nvim_win_set_cursor(0, { 1, #line })
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
      'start_lsp_server', 'resolve', 'reload', 'match', 'expandable', 'expand', 'expand_snippet',
      'expand_or_jump', 'jump', 'jumpable', 'active', 'stop',
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
end)
