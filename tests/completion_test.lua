local completion = require('zsnip.completion')
local helpers = require('helpers')
local registry = require('zsnip.registry')

local Kind = vim.lsp.protocol.CompletionItemKind
local Format = vim.lsp.protocol.InsertTextFormat

before_each(helpers.reset)
after_each(helpers.cleanup)

---@param items lsp.CompletionItem[]
---@return string[]
local function labels(items)
  return vim.tbl_map(function(item)
    return item.label
  end, items)
end

describe('completion.unmatched', function()
  ---@param run string
  ---@param trigger string
  ---@param head string
  ---@param matched boolean
  local function check(run, trigger, head, matched)
    local actual_head, actual_matched = completion.unmatched(run, trigger)
    assert.are.equal(head, actual_head, ('unmatched(%q, %q) head'):format(run, trigger))
    assert.are.equal(matched, actual_matched, ('unmatched(%q, %q) matched'):format(run, trigger))
  end

  it('reports the buffer prefix a trigger tail does not account for', function()
    check('(fnc', 'function', '(', false)
  end)

  it('reports the buffer prefix and that the tail matched', function()
    check('(req', 'req', '(', true)
  end)

  it('answers empty for a run unrelated to the trigger', function()
    check('x', 'req', '', false)
  end)

  it('still matches a whole run led by a symbol', function()
    check('<div', 'div', '<', true)
  end)

  it('answers empty when the trigger is the whole run', function()
    check('console.l', 'console.log', '', true)
  end)

  it('answers the whole run unmatched when it is unrelated buffer text', function()
    check('foo.', 'console.log', 'foo.', false)
  end)

  -- init.match() refuses to fire a keyword trigger inside a word; unmatched()
  -- has to refuse the same split, or 'xr' offers 'req' as if '(x' had typed it.
  it('will not split a keyword trigger out of the middle of a word', function()
    check('xr', 'req', '', false)
    check('foor', 'req', '', false)
  end)

  it('still splits a keyword trigger after a symbol', function()
    check('(r', 'req', '(', true)
  end)

  it('still splits a symbol trigger out of the middle of a word', function()
    check('foo<d', '<div', 'foo', true)
  end)

  -- A trigger starting with a byte >= 0x80 is still a word trigger --
  -- init.match() uses the same '[%w_\128-\255]' class -- so this must not
  -- split 'xéa' inside the word to pull 'éa' out of it. No legal start
  -- exists at all, so the strip fallback runs, and it has to agree with the
  -- same boundary rule -- ASCII '[%w_]' alone would leave 'é' behind.
  it('treats a trigger starting with a multi-byte character as a word trigger', function()
    check('xéa', 'éa', '', false)
  end)

  -- 'c.log' has no suffix that matches 'console.log' -- the whole run was
  -- the fuzzy match, not a head plus a tail, so there is no head to keep.
  it('answers no head when the whole run fuzzy-matched the trigger', function()
    check('c.log', 'console.log', '', false)
    check('js.str', 'JSON.stringify', '', false)
  end)

  -- '(fnc' does not fuzzy-match 'function' -- the '(' is not one of its
  -- characters -- so the trailing-keyword-stripped head is unchanged.
  it('keeps the stripped head when the run does not fuzzy-match either', function()
    check('(fnc', 'function', '(', false)
  end)

  -- A legal start one bracket short of the whole run can still only
  -- fuzzy-match -- so the bracket is head, not part of the match, unlike the
  -- whole-run case above.
  it('fuzzy-matches a legal start short of the whole run', function()
    check('(c.log', 'console.log', '(', false)
    check('(c.lg', 'console.log', '(', false)
    check('x<dv', '<div', 'x', false)
  end)

  -- 'c.c' fuzzy-matches 'console.clear' whole; the trailing 'c' also
  -- prefix-matches the trigger at a legal boundary, but the whole run is
  -- tried first, so that suffix is never reached.
  it('prefers the whole-run fuzzy match over a shorter legal prefix match', function()
    check('c.c', 'console.clear', '', false)
  end)
end)

describe('completion.one_line', function()
  it('joins a newline-separated description onto one line', function()
    assert.are.equal('a module table. Second line.', completion.one_line('a module table.\nSecond line.'))
  end)

  it('joins a \\r\\n-separated description onto one line', function()
    assert.are.equal('a module table. Second line.', completion.one_line('a module table.\r\nSecond line.'))
  end)

  it('turns a leading newline into a leading space', function()
    assert.are.equal(' a description', completion.one_line('\na description'))
  end)

  it('turns a trailing newline into a trailing space', function()
    assert.are.equal('a description ', completion.one_line('a description\n'))
  end)

  it('leaves a one-line description untouched', function()
    assert.are.equal('a description', completion.one_line('a description'))
  end)

  it('never raises on a non-string description', function()
    assert.are.equal('42', completion.one_line(42))
  end)
end)

describe('completion.items', function()
  it('marks items as snippets so the client expands them', function()
    registry.add('lua', { { prefix = 'req', body = "require '${1:mod}'", description = 'require' } })
    local item = completion.items({ filetype = 'lua' })[1]

    assert.are.equal('req', item.label)
    assert.are.equal(Kind.Snippet, item.kind)
    assert.are.equal(Format.Snippet, item.insertTextFormat)
    assert.are.equal("require '${1:mod}'", item.insertText)
    -- Prose stays out of `detail`: clients fence detail as code.
    assert.is_nil(item.detail)
    assert.are.equal("require\n\n```lua\nrequire '${1:mod}'\n```", item.documentation.value)
  end)

  it('resolves variables into the inserted text', function()
    registry.add('lua', { { prefix = 'year', body = '$CURRENT_YEAR' } })
    assert.are.equal(os.date('%Y'), completion.items({ filetype = 'lua' })[1].insertText)
  end)

  it('calls a function body', function()
    registry.add('lua', { { prefix = 'made', body = function() return 'produced' end } })
    assert.are.equal('produced', completion.items({ filetype = 'lua' })[1].insertText)
  end)

  it('drops a snippet whose function body fails', function()
    registry.add('lua', {
      { prefix = 'ok', body = 'fine' },
      { prefix = 'broken', body = function() error('nope') end },
    })
    assert.are.same({ 'ok' }, labels(completion.items({ filetype = 'lua' })))
  end)

  -- $BLOCK_COMMENT_START resolves to '' outside a block comment, and
  -- vim.snippet.expand() raises on an insertText of ''.
  it('drops a snippet whose body resolves to nothing', function()
    local saved = vim.bo.commentstring
    vim.bo.commentstring = '-- %s'
    registry.add('lua', {
      { prefix = 'ok', body = 'fine' },
      { prefix = 'empty', body = '$BLOCK_COMMENT_START' },
    })

    assert.are.same({ 'ok' }, labels(completion.items({ filetype = 'lua' })))

    vim.bo.commentstring = saved
  end)

  it('keeps only the first snippet for a trigger', function()
    registry.add('lua', { { prefix = 'a', body = 'first' } })
    registry.add('lua', { { prefix = 'a', body = 'second' } })

    local items = completion.items({ filetype = 'lua' })
    assert.are.equal(1, #items)
    assert.are.equal('first', items[1].insertText)
  end)

  it('fuzzy-matches a prefix and keeps the match order', function()
    registry.add('lua', {
      { prefix = 'function', body = 'b' },
      { prefix = 'fn', body = 'b' },
      { prefix = 'unrelated', body = 'b' },
    })

    local matched = labels(completion.items({ filetype = 'lua', prefix = 'fn' }))
    assert.contains(matched, 'fn')
    assert.contains(matched, 'function')
    assert.is_falsy(vim.tbl_contains(matched, 'unrelated'))
  end)

  it('orders items with sortText when it ranked them itself', function()
    registry.add('lua', { { prefix = 'fn', body = 'b' }, { prefix = 'function', body = 'b' } })
    local items = completion.items({ filetype = 'lua', prefix = 'fn' })
    assert.are.equal('000000', items[1].sortText)
    assert.are.equal('000001', items[2].sortText)
  end)

  it('leaves sortText unset when it did no ranking, so the client can rank', function()
    registry.add('lua', { { prefix = 'a', body = 'b' }, { prefix = 'c', body = 'b' } })
    for _, item in ipairs(completion.items({ filetype = 'lua' })) do
      assert.is_nil(item.sortText)
    end
  end)

  -- math.huge is what every built-in source passes for "no cap", and
  -- matchfuzzy rejects a non-finite limit outright.
  it('fuzzy-matches under an uncapped limit', function()
    registry.add('lua', { { prefix = 'fn', body = 'b' }, { prefix = 'other', body = 'b' } })
    local items = completion.items({ filetype = 'lua', prefix = 'fn', limit = math.huge })
    assert.are.same({ 'fn' }, labels(items))
  end)

  -- Resolving is per-body work; the values are not. $CLIPBOARD is a round trip
  -- to the clipboard provider, and one per snippet lands on the UI thread.
  it('resolves an expensive variable once for the whole response', function()
    local snippets = {}
    for index = 1, 10 do
      snippets[index] = { prefix = ('p%02d'):format(index), body = '$CLIPBOARD' }
    end
    registry.add('lua', snippets)

    local reads, restore = helpers.stub_clipboard()
    local items = completion.items({ filetype = 'lua' })
    restore()

    assert.are.equal(10, #items)
    assert.are.equal('pasted', items[1].insertText)
    assert.are.equal(1, reads.count)
  end)

  it('caps the number of items', function()
    local snippets = {}
    for index = 1, 20 do
      snippets[index] = { prefix = ('p%02d'):format(index), body = 'b' }
    end
    registry.add('lua', snippets)

    assert.are.equal(5, #completion.items({ filetype = 'lua', limit = 5 }))
    require('zsnip.config').setup({ max_items = 3 })
    assert.are.equal(3, #completion.items({ filetype = 'lua' }))
  end)

  -- A fractional or negative limit used to reach matchfuzzy() as-is: E475 for
  -- the fractional one, and a silent zero-item response for the negative one.
  -- config.validate() warns about both in setup(), but a caller can still
  -- pass either straight to completion.items() as opts.limit.
  it('floors a fractional limit rather than raising', function()
    registry.add('lua', { { prefix = 'r1', body = 'b' }, { prefix = 'r2', body = 'b' }, { prefix = 'r3', body = 'b' } })

    local items = completion.items({ filetype = 'lua', prefix = 'r', limit = 2.5 })
    assert.is_true(#items <= 2)
  end)

  it('clamps a negative limit to zero items rather than raising', function()
    registry.add('lua', { { prefix = 'r1', body = 'b' } })

    assert.are.equal(0, #completion.items({ filetype = 'lua', prefix = 'r', limit = -1 }))
  end)

  it('applies a filter before the limit is spent', function()
    registry.add('lua', {
      { prefix = 'taken', body = 'b' },
      { prefix = 'mine', body = 'b' },
      { prefix = 'also', body = 'b' },
    })

    local items = completion.items({
      filetype = 'lua',
      limit = 2,
      filter = function(snippet)
        return snippet.prefix ~= 'taken'
      end,
    })
    assert.are.same({ 'mine', 'also' }, labels(items))
  end)

  it('outgrows a fence the body already contains', function()
    registry.add('markdown', { { prefix = 'code', body = '```js\nx\n```' } })

    local item = completion.items({ filetype = 'markdown' })[1]
    assert.are.equal('````markdown\n```js\nx\n```\n````', item.documentation.value)
  end)

  it('can leave out the documentation', function()
    registry.add('lua', { { prefix = 'a', body = 'b', description = 'desc' } })

    local documented = completion.items({ filetype = 'lua' })[1]
    assert.are.equal('desc\n\n```lua\nb\n```', documented.documentation.value)

    local bare = completion.items({ filetype = 'lua', documentation = false })[1]
    assert.is_nil(bare.documentation)
  end)

  it('takes the filetype from the buffer when none is given', function()
    registry.add('lua', { { prefix = 'a', body = 'b' } })
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].filetype = 'lua'

    assert.are.same({ 'a' }, labels(completion.items({ bufnr = bufnr })))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  -- The conventional bufnr for "the current buffer" -- a hand-rolled source
  -- passing it should not lose the textEdit cursor_in() only anchors for a
  -- bufnr it can recognise as the one it has a cursor in.
  it('anchors a textEdit for the conventional bufnr = 0', function()
    registry.add('lua', { { prefix = 'a', body = 'b' } })
    helpers.typed('lua', 'a')

    assert.is_not_nil(completion.items({ bufnr = 0 })[1].textEdit)
  end)

  -- '(fnc' has no suffix that matches 'function' -- unmatched() only splits
  -- at a keyword boundary, and 'fnc' is not one -- so the '(' is not the
  -- trigger's to claim in filterText, only to put back in newText once a
  -- client (a fuzzy one, matching 'fnc' against 'function' itself) keeps it.
  it('leaves the buffer prefix out of filterText when the run never matched', function()
    registry.add('lua', { { prefix = 'function', body = 'function()' } })
    local bufnr = helpers.typed('lua', '(fnc')

    local item = completion.items({ filetype = 'lua', bufnr = bufnr })[1]
    assert.are.equal('function', item.filterText)
    assert.are.equal('(function()', item.textEdit.newText)

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  -- A bare buffer prefix with nothing of the trigger typed at all: neither a
  -- prefix-filtering client nor a fuzzy one should be offered every snippet
  -- because it saw its own delimiter sitting in filterText.
  it('drops the head from filterText entirely for an unrelated run', function()
    registry.add('lua', { { prefix = 'function', body = 'function()' } })
    local bufnr = helpers.typed('lua', '(')

    local item = completion.items({ filetype = 'lua', bufnr = bufnr })[1]
    assert.are.equal('function', item.filterText)
    assert.is_true(vim.startswith(item.textEdit.newText, '('))

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  -- 'c.log' fuzzy-matched 'console.log' whole -- the '.' is not buffer text
  -- left over from a delimiter, it is part of the match itself, so newText
  -- must not put a 'c.' back in front of it (vim.lsp.completion builds its
  -- prefix from the textEdit start under 'completeopt+=fuzzy', so this is the
  -- run it compares against filterText too).
  it('keeps no head at all when the whole run fuzzy-matched the trigger', function()
    registry.add('javascript', { { prefix = 'console.log', body = 'console.log($1)' } })
    local bufnr = helpers.typed('javascript', 'c.log')

    local item = completion.items({ filetype = 'javascript', bufnr = bufnr })[1]
    assert.are.equal('console.log', item.filterText)
    assert.are.equal('console.log($1)', item.textEdit.newText)

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
