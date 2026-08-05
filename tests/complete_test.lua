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

-- Both helpers put the cursor after the last character, which is where it sits
-- in insert mode -- the only mode this source and its CompleteDone handler ever
-- run in. Normal mode clamps that column back one, which shortens the run under
-- test and leaves the expansion computing a start one byte short of the trigger.
local virtualedit
before_each(function()
  helpers.reset()
  virtualedit = vim.o.virtualedit
  vim.o.virtualedit = 'onemore'
end)
after_each(function()
  vim.o.virtualedit = virtualedit
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
    assert.is_nil(item.menu)
    assert.are.equal("a require\n\n```lua\nrequire '${1:mod}'\n```", item.info)
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

  it('names the entry that goes in complete', function()
    complete.enable()

    assert.contains(vim.opt.complete:get(), complete.source())
  end)

  -- A cap belongs to the option value, not to the source. A config that sets
  -- 'complete' itself writes `...completefunc^10`, and enable() has to read
  -- that as already-there rather than appending a second, uncapped copy --
  -- which offers every snippet twice.
  it('recognises its entry through a match limit', function()
    local before = #vim.opt.complete:get()
    vim.opt.complete:append(complete.source() .. '^10')

    assert.is_true(complete.enabled())

    complete.enable()
    assert.are.equal(before + 1, #vim.opt.complete:get())

    complete.disable()
    assert.are.equal(before, #vim.opt.complete:get())
    assert.is_false(complete.enabled())
  end)

  it('leaves complete alone when the caller owns it', function()
    local before = vim.o.complete

    complete.enable({ complete = false })

    assert.are.equal(before, vim.o.complete)
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

  -- The handler is the half a caller that owns 'complete' still needs.
  it('expands for a caller that put the source in complete itself', function()
    lua_buffer()
    complete.enable({ complete = false })
    accept('req', "require 'mod'")

    assert.are.same({ "require 'mod'" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)

  -- A caller whose user chose a different engine passes it in; the trigger
  -- is already deleted by the time it runs.
  it('expands through the expand a caller handed enable()', function()
    local expanded
    lua_buffer()
    complete.enable({
      complete = false,
      expand = function(body)
        expanded = body
      end,
    })
    accept('req', "require '${1:mod}'")

    assert.are.equal("require '${1:mod}'", expanded)
    assert.are.same({ '' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.is_false(vim.snippet.active())
  end)
end)

describe('the complete source and its options', function()
  -- The docs promise the same `documentation` as the other three sources.
  -- `info` is the preview window, and it used to carry the body regardless.
  it('strips the body and description when documentation is off', function()
    registry.add('lua', { { prefix = 'req', body = 'b', description = 'a require' } })
    lua_buffer('req')
    complete.enable({ documentation = false, complete = false })

    local item = complete.completefunc(0, 'req').words[1]
    assert.is_nil(item.info)
    -- Still expandable: the body travels in user_data, not in the preview.
    assert.are.equal('b', item.user_data.zsnip.body)
  end)

  it('carries them when it is on', function()
    registry.add('lua', { { prefix = 'req', body = 'b', description = 'a require' } })
    lua_buffer('req')
    complete.enable({ complete = false })

    local item = complete.completefunc(0, 'req').words[1]
    assert.are.equal('a require\n\n```lua\nb\n```', item.info)
    assert.is_nil(item.menu)
  end)

  it('installs the preview stylist next to the expander', function()
    complete.enable()

    local autocmds = vim.api.nvim_get_autocmds({ group = 'zsnip.complete' })
    local events = vim.tbl_map(function(autocmd)
      return autocmd.event
    end, autocmds)
    table.sort(events)
    assert.are.same({ 'CompleteChanged', 'CompleteDone' }, events)

    complete.disable()
    assert.has_error(function()
      vim.api.nvim_get_autocmds({ group = 'zsnip.complete' })
    end)
  end)

  -- The float and its buffer are reused by every item in one menu, so the
  -- markdown styling a snippet needs must come back off before a plain item
  -- from another source shows in the same preview.
  it('styles a snippet preview and takes the styling back off a plain item', function()
    lua_buffer()
    complete.enable({ complete = false })

    local completeopt = vim.o.completeopt
    vim.o.completeopt = 'menuone,noselect,popup'

    -- Registered after enable(), so it observes the preview as stylize() left it.
    local observed = {}
    local watcher = vim.api.nvim_create_autocmd('CompleteChanged', {
      callback = function()
        local info = vim.fn.complete_info({ 'selected', 'preview_winid', 'preview_bufnr' })
        if info.preview_winid then
          observed[#observed + 1] = {
            conceal = vim.api.nvim_get_option_value('conceallevel', { win = info.preview_winid }),
            markdown = vim.treesitter.highlighter.active[info.preview_bufnr] ~= nil,
          }
        end
      end,
    })

    function _G.zsnip_test_complete()
      vim.fn.complete(1, {
        { word = 'snip', info = 'desc\n\n```lua\nbody\n```', user_data = { zsnip = { body = 'b', keep = 0 } } },
        { word = 'plain', info = 'plain text from another source' },
      })
      return ''
    end
    vim.api.nvim_feedkeys(
      vim.keycode('i<C-r>=v:lua.zsnip_test_complete()<CR><C-n><C-n><C-e><Esc>'),
      'x',
      false
    )

    vim.api.nvim_del_autocmd(watcher)
    _G.zsnip_test_complete = nil
    vim.o.completeopt = completeopt

    assert.are.equal(2, #observed)
    assert.are.same({ conceal = 2, markdown = true }, observed[1])
    assert.are.same({ conceal = 0, markdown = false }, observed[2])
  end)

  it('keeps the description in the menu row under description_style = classic', function()
    registry.add('lua', { { prefix = 'req', body = 'b', description = 'a require' } })
    lua_buffer('req')
    complete.enable({ complete = false, description_style = 'classic' })

    local item = complete.completefunc(0, 'req').words[1]
    assert.are.equal('a require', item.menu)
    assert.are.equal('b', item.info)
  end)

  it('strips the classic menu row when documentation is off too', function()
    registry.add('lua', { { prefix = 'req', body = 'b', description = 'a require' } })
    lua_buffer('req')
    complete.enable({ complete = false, description_style = 'classic', documentation = false })

    local item = complete.completefunc(0, 'req').words[1]
    assert.is_nil(item.menu)
    assert.is_nil(item.info)
  end)

  it('caps at max_items like the docs say', function()
    local snippets = {}
    for index = 1, 150 do
      snippets[index] = { prefix = ('p%03d'):format(index), body = 'b' }
    end
    registry.add('lua', snippets)
    lua_buffer('p')
    complete.enable({ complete = false })

    assert.are.equal(100, #complete.completefunc(0, 'p').words)
  end)
end)

describe('the complete source refusing to expand', function()
  -- The guard exists because the range may not be in the buffer any more. When
  -- it fires, expanding anyway puts the body *next to* the trigger rather than
  -- over it -- so the buffer ends up with both.
  it('leaves the buffer alone when the trigger is not where it should be', function()
    lua_buffer('req')
    complete.enable()

    -- `word` longer than the line: the computed start is negative.
    vim.api.nvim_win_set_cursor(0, { 1, 3 })
    vim.v.completed_item = {
      word = 'a much longer word than the line',
      user_data = { zsnip = { body = "require 'mod'", keep = 0 } },
    }
    vim.api.nvim_exec_autocmds('CompleteDone', {})

    assert.are.same({ 'req' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.is_false(vim.snippet.active())
  end)
end)
