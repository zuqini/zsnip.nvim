local complete = require('zsnip.complete')
local helpers = require('helpers')
local registry = require('zsnip.registry')

---A real buffer in a real window: 'complete' is buffer-local, the completion
---function reads the line under the cursor, and expansion writes to it.
---@param line? string
---@return integer
local function lua_buffer(line)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.bo[bufnr].filetype = 'lua'
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line or '' })
  vim.api.nvim_win_set_cursor(0, { 1, #(line or '') })
  return bufnr
end

before_each(helpers.reset)
after_each(function()
  complete.disable()
  vim.snippet.stop()
  helpers.cleanup()
end)

describe('the complete source', function()
  it('reports where the trigger under the cursor starts', function()
    lua_buffer('local req')
    assert.are.equal(6, complete.completefunc(1, ''))
  end)

  -- The run is what Vim replaces on accept, and real triggers mix words and
  -- symbols in both directions: stopping at the keyword boundary would leave
  -- `console.` or `<` sitting in front of the expansion.
  it('takes the whole non-blank run, symbols included', function()
    lua_buffer('x = <div')
    assert.are.equal(4, complete.completefunc(1, ''))

    lua_buffer('console.log')
    assert.are.equal(0, complete.completefunc(1, ''))

    lua_buffer('#!')
    assert.are.equal(0, complete.completefunc(1, ''))
  end)

  it('starts at the cursor when there is nothing behind it', function()
    lua_buffer('x = ')
    assert.are.equal(4, complete.completefunc(1, ''))
  end)

  it('answers in complete-items shape, carrying the body', function()
    registry.add('lua', { { prefix = 'req', body = "require '${1:mod}'", description = 'a require' } })
    lua_buffer('req')

    local result = complete.completefunc(0, 'req')
    assert.are.equal('always', result.refresh)
    assert.are.equal(1, #result.words)

    local item = result.words[1]
    assert.are.equal('req', item.word)
    assert.are.equal('Snippet', item.kind)
    assert.are.equal('a require', item.menu)
    assert.are.equal("require '${1:mod}'", item.user_data.zsnip.body)
  end)

  it('matches the base against the filetype', function()
    registry.add('lua', { { prefix = 'req', body = 'b' }, { prefix = 'other', body = 'b' } })
    registry.add('python', { { prefix = 'imp', body = 'b' } })
    lua_buffer('req')

    local words = complete.completefunc(0, 'req').words
    assert.are.equal(1, #words)
    assert.are.equal('req', words[1].word)
  end)

  -- A trigger typed after a bracket is still the trigger; the bracket is the
  -- buffer's and has to survive the expansion.
  it('finds a trigger in the tail of the run, and keeps the rest', function()
    registry.add('lua', { { prefix = 'req', body = "require '$1'" } })
    lua_buffer('(req')

    local item = complete.completefunc(0, '(req').words[1]
    assert.are.equal('(req', item.word)
    assert.are.equal('req', item.abbr)
    assert.are.equal(1, item.user_data.zsnip.keep)
  end)

  it('keeps nothing when the whole run is the trigger', function()
    registry.add('lua', { { prefix = '<div', body = '<div>$0</div>' } })
    lua_buffer('<div')

    local item = complete.completefunc(0, '<div').words[1]
    assert.are.equal('<div', item.word)
    assert.are.equal(0, item.user_data.zsnip.keep)
  end)

  it('resolves variables before the body is handed over', function()
    registry.add('lua', { { prefix = 'year', body = '-- $CURRENT_YEAR' } })
    lua_buffer('year')

    local item = complete.completefunc(0, 'year').words[1]
    assert.are.equal('-- ' .. os.date('%Y'), item.user_data.zsnip.body)
  end)

  it('adds itself to complete once, and takes itself back out', function()
    local before = #vim.opt.complete:get()

    complete.enable()
    complete.enable()
    assert.are.equal(before + 1, #vim.opt.complete:get())
    assert.is_true(vim.o.complete:find('zsnip.complete', 1, true) ~= nil)

    complete.disable()
    assert.are.equal(before, #vim.opt.complete:get())
  end)
end)

describe('the complete source expanding an accepted item', function()
  ---Stand in for what Vim does on accept: the trigger is already in the
  ---buffer, and v:completed_item describes what put it there.
  ---@param word string
  ---@param body string?
  ---@param keep integer?
  local function accept(word, body, keep)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { word })
    vim.api.nvim_win_set_cursor(0, { 1, #word })
    vim.v.completed_item = {
      word = word,
      user_data = body and { zsnip = { body = body, keep = keep or 0 } } or vim.empty_dict(),
    }
    vim.api.nvim_exec_autocmds('CompleteDone', {})
  end

  it('replaces the inserted trigger with the snippet', function()
    lua_buffer()
    complete.enable()
    accept('req', "require 'mod'")

    assert.are.same({ "require 'mod'" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)

  it('starts a session when the body has tabstops', function()
    lua_buffer()
    complete.enable()
    accept('req', "require '${1:mod}'")

    assert.are.same({ "require 'mod'" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.is_true(vim.snippet.active())
  end)

  it('leaves the part of the run that was never the snippet', function()
    lua_buffer()
    complete.enable()
    accept('(req', "require 'mod'", 1)

    assert.are.same({ "(require 'mod'" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)

  -- CompleteDone fires for every source, and most of them are not ours.
  it('leaves an item from another source alone', function()
    lua_buffer()
    complete.enable()
    accept('req', nil)

    assert.are.same({ 'req' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.is_false(vim.snippet.active())
  end)

  it('does nothing once disabled', function()
    lua_buffer()
    complete.enable()
    complete.disable()
    accept('req', "require 'mod'")

    assert.are.same({ 'req' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)
end)
