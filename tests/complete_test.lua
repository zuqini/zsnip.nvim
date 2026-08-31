local complete = require('zsnip.complete')
local helpers = require('helpers')
local registry = require('zsnip.registry')

---Run `fn` from insert mode -- the only mode `complete()` is legal in --
---then feed `keys` to the menu it opened. A raise inside `fn` is held and
---re-raised after the keys are done: feedkeys() swallows an error raised
---out of an expression-register evaluation, so raising in place would only
---print a traceback and let the test pass.
---@param fn fun()
---@param keys string
local function in_insert(fn, keys)
  local failure
  function _G.zsnip_test_run()
    local ok, err = pcall(fn)
    if not ok then
      failure = err
    end
    return ''
  end
  vim.api.nvim_feedkeys(vim.keycode('i<C-r>=v:lua.zsnip_test_run()<CR>' .. keys .. '<Esc>'), 'x', false)
  _G.zsnip_test_run = nil
  if failure then
    error(failure, 0)
  end
end

---Feed a real `complete()` call and accept it with CTRL-Y, from a blank
---line. Vim fires a real CompleteDone for this, with `v:event.reason ==
---'accept'` -- which is what the handler now requires, and no synthetic
---`nvim_exec_autocmds()` call can fake, since `v:event` is read-only from
---outside the autocommand it belongs to.
---@param item table
local function accept_item(item)
  -- `nvim -l` has no main loop, so a snippet with a non-final tabstop --
  -- core's select_tabstop() queues the keys that turn it into a Select-mode
  -- highlight with feedkeys(..., 'n') -- leaves those keys queued rather than
  -- run. Draining them against our own buffer would run them for real, right
  -- here; a scratch buffer gives them somewhere harmless to land.
  local win = vim.api.nvim_get_current_win()
  local target = vim.api.nvim_win_get_buf(win)
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, scratch)
  vim.api.nvim_feedkeys('', 'x', false)
  vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
  vim.api.nvim_win_set_buf(win, target)
  vim.api.nvim_buf_delete(scratch, { force = true })

  in_insert(function()
    vim.fn.complete(1, { item })
  end, '<C-y>')
end

before_each(helpers.reset)
after_each(function()
  complete.disable()
  helpers.cleanup()
end)

describe('the complete source', function()
  it('reports where the trigger under the cursor starts', function()
    helpers.typed('lua', 'local req')
    assert.are.equal(6, complete.completefunc(1, ''))
  end)

  -- The run is what Vim replaces on accept, and real triggers mix words and
  -- symbols in both directions: stopping at the keyword boundary would leave
  -- `console.` or `<` sitting in front of the expansion.
  it('takes the whole non-blank run, symbols included', function()
    helpers.typed('lua', 'x = <div')
    assert.are.equal(4, complete.completefunc(1, ''))

    helpers.typed('lua', 'console.log')
    assert.are.equal(0, complete.completefunc(1, ''))

    helpers.typed('lua', '#!')
    assert.are.equal(0, complete.completefunc(1, ''))
  end)

  it('starts at the cursor when there is nothing behind it', function()
    helpers.typed('lua', 'x = ')
    assert.are.equal(4, complete.completefunc(1, ''))
  end)

  it('answers in complete-items shape, carrying the body', function()
    registry.add('lua', { { prefix = 'req', body = "require '${1:mod}'", description = 'a require' } })
    helpers.typed('lua', 'req')

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

  -- An empty base is unranked, so matching() hands back the whole filetype;
  -- under 'autocomplete' that would pop a menu after every space typed.
  it('answers nothing for an empty base under autocomplete', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    helpers.typed('lua', 'x ')
    helpers.set_option('autocomplete', true)

    assert.are.same({}, complete.completefunc(0, '').words)
  end)

  it('still lists everything for an empty base without autocomplete', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    helpers.typed('lua', 'x ')
    helpers.set_option('autocomplete', false)

    assert.are.equal(1, #complete.completefunc(0, '').words)
  end)

  it('matches the base against the filetype', function()
    registry.add('lua', { { prefix = 'req', body = 'b' }, { prefix = 'other', body = 'b' } })
    registry.add('python', { { prefix = 'imp', body = 'b' } })
    helpers.typed('lua', 'req')

    local words = complete.completefunc(0, 'req').words
    assert.are.equal(1, #words)
    assert.are.equal('req', words[1].word)
  end)

  -- A trigger typed after a bracket is still the trigger; the bracket is the
  -- buffer's and has to survive the expansion.
  it('finds a trigger in the tail of the run, and keeps the rest', function()
    registry.add('lua', { { prefix = 'req', body = "require '$1'" } })
    helpers.typed('lua', '(req')

    local item = complete.completefunc(0, '(req').words[1]
    assert.are.equal('(req', item.word)
    assert.are.equal('req', item.abbr)
    assert.are.equal(1, item.user_data.zsnip.keep)
  end)

  -- A run that fails to match whole (matching()'s own coarse split) can still
  -- be won by a trigger buried in it: matching() only had to find the
  -- snippet, and unmatched() -- the same rule the LSP-shaped sources use --
  -- is what decides how much of the run is actually the trigger's.
  it('finds a trigger buried in the run, kept apart from a fuzzy match', function()
    registry.add('lua', { { prefix = 'console.log', body = 'console.log($1)' } })
    helpers.typed('lua', 'x.console.log')

    local item = complete.completefunc(0, 'x.console.log').words[1]
    assert.are.equal('x.console.log', item.word)
    assert.are.equal(2, item.user_data.zsnip.keep)
  end)

  it('keeps nothing when the whole run is the trigger', function()
    registry.add('lua', { { prefix = '<div', body = '<div>$0</div>' } })
    helpers.typed('lua', '<div')

    local item = complete.completefunc(0, '<div').words[1]
    assert.are.equal('<div', item.word)
    assert.are.equal(0, item.user_data.zsnip.keep)
  end)

  -- matching()'s whole-base matchfuzzy accepts 'c.log' for 'console.log'
  -- outright -- the run was the match, not a head plus a tail matchfuzzy
  -- happened to accept, so unmatched() must not put the 'c.' back a second
  -- time.
  it('keeps nothing when the whole run fuzzy-matched the trigger', function()
    registry.add('lua', { { prefix = 'console.log', body = 'console.log($1)' } })
    helpers.typed('lua', 'c.log')

    local item = complete.completefunc(0, 'c.log').words[1]
    assert.are.equal('console.log', item.word)
    assert.are.equal(0, item.user_data.zsnip.keep)
  end)

  -- '(c.log' is one bracket short of the whole-run fuzzy match above -- the
  -- '(' does not fuzzy-match, so matching() falls back to its tail retry,
  -- and unmatched() has to find the legal fuzzy-matching start ('c.log')
  -- rather than doubling the head the way the pinned bug did.
  it('finds a fuzzy match a legal start short of the whole run', function()
    registry.add('lua', { { prefix = 'console.log', body = 'console.log($1)' } })
    helpers.typed('lua', '(c.log')

    local item = complete.completefunc(0, '(c.log').words[1]
    assert.are.equal('(console.log', item.word)
    assert.are.equal(1, item.user_data.zsnip.keep)
  end)

  -- 'c.c' fuzzy-matches 'console.clear' whole, the same shape as 'c.log'
  -- above; the trailing 'c' also prefix-matches the trigger at a legal
  -- boundary, but the whole-run match must win so no head is kept.
  it('prefers the whole-run fuzzy match over a shorter legal prefix match', function()
    registry.add('lua', { { prefix = 'console.clear', body = 'console.clear()' } })
    helpers.typed('lua', 'c.c')

    local item = complete.completefunc(0, 'c.c').words[1]
    assert.are.equal('console.clear', item.word)
    assert.are.equal(0, item.user_data.zsnip.keep)
  end)

  it('resolves variables before the body is handed over', function()
    registry.add('lua', { { prefix = 'year', body = '-- $CURRENT_YEAR' } })
    helpers.typed('lua', 'year')

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

  -- The usual wiring is InsertEnter lazy-loading enable() from inside one
  -- buffer; every other buffer already open has its own local 'complete' by
  -- then and never sees a change to the global default.
  it('reaches every loaded buffer, not just the current one', function()
    local current = vim.api.nvim_get_current_buf()
    local other = vim.api.nvim_create_buf(false, true)

    complete.enable()

    assert.is_true(vim.go.complete:find(complete.source(), 1, true) ~= nil)
    assert.is_true(vim.bo[current].complete:find(complete.source(), 1, true) ~= nil)
    assert.is_true(vim.bo[other].complete:find(complete.source(), 1, true) ~= nil)

    complete.disable()

    assert.is_nil(vim.go.complete:find(complete.source(), 1, true))
    assert.is_nil(vim.bo[current].complete:find(complete.source(), 1, true))
    assert.is_nil(vim.bo[other].complete:find(complete.source(), 1, true))

    vim.api.nvim_buf_delete(other, { force = true })
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
  ---Accept `word` from a blank buffer, the way Vim would leave it after
  ---replacing the run under the cursor with a completion.
  ---@param word string
  ---@param body string?
  ---@param keep integer?
  local function accept(word, body, keep)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '' })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    accept_item({
      word = word,
      user_data = body and { zsnip = { body = body, keep = keep or 0 } } or vim.empty_dict(),
    })
  end

  it('replaces the inserted trigger with the snippet', function()
    helpers.typed('lua')
    complete.enable()
    accept('req', "require 'mod'")

    assert.are.same({ "require 'mod'" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)

  it('starts a session when the body has tabstops', function()
    helpers.typed('lua')
    complete.enable()
    accept('req', "require '${1:mod}'")

    assert.are.same({ "require 'mod'" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.is_true(vim.snippet.active())
  end)

  it('leaves the part of the run that was never the snippet', function()
    helpers.typed('lua')
    complete.enable()
    accept('(req', "require 'mod'", 1)

    assert.are.same({ "(require 'mod'" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)

  -- CompleteDone fires for every source, and most of them are not ours.
  it('leaves an item from another source alone', function()
    helpers.typed('lua')
    complete.enable()
    accept('req', nil)

    assert.are.same({ 'req' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.is_false(vim.snippet.active())
  end)

  it('does nothing once disabled', function()
    helpers.typed('lua')
    complete.enable()
    complete.disable()
    accept('req', "require 'mod'")

    assert.are.same({ 'req' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)

  -- The handler is the half a caller that owns 'complete' still needs.
  it('expands for a caller that put the source in complete itself', function()
    helpers.typed('lua')
    complete.enable({ complete = false })
    accept('req', "require 'mod'")

    assert.are.same({ "require 'mod'" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)

  -- A caller whose user chose a different engine passes it in; the trigger
  -- is already deleted by the time it runs.
  it('expands through the expand a caller handed enable()', function()
    local expanded
    helpers.typed('lua')
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
    helpers.typed('lua', 'req')
    complete.enable({ documentation = false, complete = false })

    local item = complete.completefunc(0, 'req').words[1]
    assert.is_nil(item.info)
    -- Still expandable: the body travels in user_data, not in the preview.
    assert.are.equal('b', item.user_data.zsnip.body)
  end)

  -- completefunc is still reachable directly after disable() -- the half a
  -- caller that owns 'complete' itself keeps calling -- and it should not go
  -- on answering with options that were only ever passed to enable().
  it('drops its options once disabled', function()
    registry.add('lua', { { prefix = 'req', body = 'b', description = 'a require' } })
    helpers.typed('lua', 'req')
    complete.enable({ documentation = false, complete = false })
    complete.disable()

    local item = complete.completefunc(0, 'req').words[1]
    assert.is_not_nil(item.info)
  end)

  -- zsnip.CompleteOpts is zsnip.SourceOpts plus complete()'s own fields, and
  -- only some of the former are documented for the completion layer itself
  -- (bufnr, filetype, position are not). Handing the whole table over would
  -- let one of those silently steer matching away from the real buffer.
  it('does not leak the rest of CompleteOpts into matching', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    registry.add('python', { { prefix = 'req', body = 'p' } })
    local other = vim.api.nvim_create_buf(false, true)
    vim.bo[other].filetype = 'python'
    helpers.typed('lua', 'req')
    complete.enable({ complete = false, bufnr = other })

    local item = complete.completefunc(0, 'req').words[1]
    assert.are.equal('b', item.user_data.zsnip.body)

    vim.api.nvim_buf_delete(other, { force = true })
  end)

  it('carries them when it is on', function()
    registry.add('lua', { { prefix = 'req', body = 'b', description = 'a require' } })
    helpers.typed('lua', 'req')
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
    helpers.typed('lua')
    complete.enable({ complete = false })

    helpers.set_option('completeopt', 'menuone,noselect,popup')

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

    in_insert(function()
      vim.fn.complete(1, {
        { word = 'snip', info = 'desc\n\n```lua\nbody\n```', user_data = { zsnip = { body = 'b', keep = 0 } } },
        { word = 'plain', info = 'plain text from another source' },
      })
    end, '<C-n><C-n><C-e>')

    vim.api.nvim_del_autocmd(watcher)

    assert.are.equal(2, #observed)
    assert.are.same({ conceal = 2, markdown = true }, observed[1])
    assert.are.same({ conceal = 0, markdown = false }, observed[2])
  end)

  -- `if` and `#if` both replace the run `[#if` in full, so both items carry
  -- word `[#if`: without `dup = 1`, Vim's own complete() silently drops the
  -- second one rather than showing two entries with the same word.
  it('offers two triggers that replace the same run as two items', function()
    registry.add('c', {
      { prefix = 'if', body = 'b1' },
      { prefix = '#if', body = 'b2' },
    })
    helpers.typed('c', '[#if')
    complete.enable({ complete = false })

    local start = complete.completefunc(1, '')
    local base = vim.api.nvim_get_current_line():sub(start + 1)
    local words = complete.completefunc(0, base).words

    local items
    in_insert(function()
      vim.fn.complete(start + 1, words)
      items = vim.fn.complete_info({ 'items' }).items
    end, '')

    local abbrs = vim.tbl_map(function(item)
      return item.abbr
    end, items)
    table.sort(abbrs)
    assert.are.same({ '#if', 'if' }, abbrs)
  end)

  it('keeps the description in the menu row under description_style = classic', function()
    registry.add('lua', { { prefix = 'req', body = 'b', description = 'a require' } })
    helpers.typed('lua', 'req')
    complete.enable({ complete = false, description_style = 'classic' })

    local item = complete.completefunc(0, 'req').words[1]
    assert.are.equal('a require', item.menu)
    assert.are.equal('b', item.info)
  end)

  it('flattens a two-line description in the classic menu row', function()
    registry.add('lua', { { prefix = 'req', body = 'b', description = 'a module table.\nSecond line.' } })
    helpers.typed('lua', 'req')
    complete.enable({ complete = false, description_style = 'classic' })

    local item = complete.completefunc(0, 'req').words[1]
    assert.is_nil(item.menu:find('\n', 1, true))
    assert.are.equal('a module table. Second line.', item.menu)
  end)

  it('strips the classic menu row when documentation is off too', function()
    registry.add('lua', { { prefix = 'req', body = 'b', description = 'a require' } })
    helpers.typed('lua', 'req')
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
    helpers.typed('lua', 'p')
    complete.enable({ complete = false })

    assert.are.equal(100, #complete.completefunc(0, 'p').words)
  end)
end)

describe('the complete source refusing to expand', function()
  -- The guard exists because the range may not be in the buffer any more --
  -- another CompleteDone handler moving the cursor before zsnip's own runs,
  -- say. When it fires, expanding anyway puts the body *next to* the trigger
  -- rather than over it -- so the buffer ends up with both.
  it('leaves the buffer alone when the trigger is not where it should be', function()
    helpers.typed('lua')

    -- Registered before enable(), so it runs first and moves the cursor out
    -- from under zsnip's own handler.
    local saboteur = vim.api.nvim_create_autocmd('CompleteDone', {
      callback = function()
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
      end,
    })
    complete.enable()

    accept_item({
      word = "require 'mod'",
      user_data = { zsnip = { body = "require 'mod'", keep = 0 } },
    })
    vim.api.nvim_del_autocmd(saboteur)

    assert.are.same({ "require 'mod'" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.is_false(vim.snippet.active())
  end)
end)
