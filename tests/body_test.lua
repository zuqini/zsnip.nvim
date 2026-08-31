local body = require('zsnip.body')
local helpers = require('helpers')

describe('body.resolve', function()
  it('fills in variables Neovim does not know', function()
    assert.are.equal(os.date('%Y'), body.resolve('$CURRENT_YEAR'))
    assert.are.equal(os.date('%Y'), body.resolve('${CURRENT_YEAR}'))
  end)

  it('leaves unknown variables for the engine to handle', function()
    assert.are.equal('$NAME', body.resolve('$NAME'))
    assert.are.equal('$C$', body.resolve('$C$'))
  end)

  -- The grammar reads one variable, CURRENT_YEARabc, not $CURRENT_YEAR
  -- followed by literal text -- a bare $NAME has to read the same way, or an
  -- unknown suffix like this resolves to '2026abc'.
  it('reads a whole word as the variable name, not its uppercase prefix', function()
    assert.are.equal('$CURRENT_YEARabc', body.resolve('$CURRENT_YEARabc'))
    assert.are.equal(os.date('%Y') .. '!', body.resolve('$CURRENT_YEAR!'))
  end)

  it('leaves escaped variables alone', function()
    assert.are.equal('\\${CURRENT_YEAR}', body.resolve('\\${CURRENT_YEAR}'))
  end)

  it('leaves tabstops alone', function()
    assert.are.equal('${1:name}$0', body.resolve('${1:name}$0'))
  end)

  it('produces a well-formed UUID', function()
    assert.is_truthy(body.resolve('$UUID'):match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x+$'))
  end)

  -- A `seen` per variable, and RANDOM left out of it: its six decimal digits
  -- are a space small enough that 32 draws repeat by chance often enough to
  -- flake, so a repeat there is not evidence of anything. The seeded test
  -- below is what guards RANDOM.
  it('does not repeat a UUID or a random hex string', function()
    for _, name in ipairs({ 'UUID', 'RANDOM_HEX' }) do
      local seen = {}
      for _ = 1, 32 do
        local value = body.resolve('$' .. name)
        assert.is_nil(seen[value], name .. ' repeated a value: ' .. value)
        seen[value] = true
      end
    end
  end)

  -- The defect is not repetition *within* a run -- an unseeded math.random
  -- still walks a sequence -- but that it is the same sequence on every start,
  -- forever. Reseeding to a fixed value stages four starts inside one process:
  -- a value derived from math.random is identical across all four, a value
  -- from the CSPRNG is not. Each variable is checked on its own, or one that
  -- still had real entropy would carry the others.
  it('does not repeat across identically seeded starts', function()
    for _, name in ipairs({ 'UUID', 'RANDOM', 'RANDOM_HEX' }) do
      local values = {}
      for _ = 1, 4 do
        math.randomseed(1)
        values[body.resolve('$' .. name)] = true
      end
      assert.is_true(vim.tbl_count(values) > 1, name .. ' is a function of math.randomseed()')
    end
    math.randomseed(os.time())
  end)

  it('keeps RANDOM and RANDOM_HEX in their documented shape', function()
    assert.is_truthy(body.resolve('$RANDOM'):match('^%d%d%d%d%d%d$'))
    assert.is_truthy(body.resolve('$RANDOM_HEX'):match('^%x%x%x%x%x%x$'))
  end)

  -- os.date('%z') gives '+0100'; VSCode's variable is '+01:00'.
  it('colons the timezone offset the way VSCode does', function()
    assert.is_truthy(body.resolve('$CURRENT_TIMEZONE_OFFSET'):match('^[%+%-]%d%d:%d%d$'))
  end)

  it('escapes snippet syntax coming out of a variable', function()
    local _, restore = helpers.stub_clipboard('a $1 }')
    local resolved = body.resolve('$CLIPBOARD')
    restore()

    assert.are.equal('a \\$1 \\}', resolved)
  end)

  -- getreg's list form only splits on '\n', so a Windows copy leaves '\r' at
  -- the end of every line -- the same '^M' bug a raw pack body has, reachable
  -- through a resolved variable instead.
  it('normalizes CRLF line endings out of a clipboard value', function()
    local _, restore = helpers.stub_clipboard('line1\r\nline2\r')
    local resolved = body.resolve('$CLIPBOARD')
    restore()

    assert.are.equal('line1\nline2\n', resolved)
  end)

  -- It is the parity of the backslash run that decides, not its presence: two
  -- is an escaped backslash and the `$` is still syntax, three is an escaped
  -- backslash *and* an escaped `$`.
  it('counts the backslash run before a variable', function()
    local year = os.date('%Y')

    assert.are.equal('\\\\' .. year, body.resolve('\\\\$CURRENT_YEAR'))
    assert.are.equal('\\\\' .. year, body.resolve('\\\\${CURRENT_YEAR}'))

    assert.are.equal('\\\\\\$CURRENT_YEAR', body.resolve('\\\\\\$CURRENT_YEAR'))
    assert.are.equal('\\\\\\${CURRENT_YEAR}', body.resolve('\\\\\\${CURRENT_YEAR}'))
  end)

  it('reads comment markers off the buffer', function()
    local saved = vim.bo.commentstring

    vim.bo.commentstring = '-- %s'
    assert.are.equal('--', body.resolve('$LINE_COMMENT'))
    -- A line-comment buffer has no honest answer for a block comment: ''
    -- rather than leaving it unresolved, which vim.snippet.expand() would
    -- otherwise turn into a tabstop holding the literal variable name.
    assert.are.equal('', body.resolve('$BLOCK_COMMENT_START'))

    vim.bo.commentstring = '/* %s */'
    assert.are.equal('/*', body.resolve('$BLOCK_COMMENT_START'))
    assert.are.equal('*/', body.resolve('$BLOCK_COMMENT_END'))

    -- No 'commentstring' at all is the same "no honest answer" as above.
    vim.bo.commentstring = ''
    assert.are.equal('', body.resolve('$LINE_COMMENT'))

    vim.bo.commentstring = saved
  end)

  it('short-circuits a body with no variables', function()
    assert.are.equal('plain text', body.resolve('plain text'))
  end)
end)

describe('body.batch', function()
  ---@param text string
  ---@return zsnip.Snippet
  local function snippet(text)
    return { prefix = 'x', body = text }
  end

  it('reads an expensive variable once for the whole batch', function()
    local reads, restore = helpers.stub_clipboard()
    local resolve = body.batch()
    for _ = 1, 10 do
      assert.are.equal('pasted', resolve(snippet('$CLIPBOARD')))
    end
    restore()

    assert.are.equal(1, reads.count)
  end)

  it('still reads it per body outside one', function()
    local reads, restore = helpers.stub_clipboard()
    for _ = 1, 10 do
      body.text(snippet('$CLIPBOARD'))
    end
    restore()

    assert.are.equal(10, reads.count)
  end)

  it('leaves a name that resolves to nothing alone, every time', function()
    local resolve = body.batch()
    assert.are.equal('$NOPE', resolve(snippet('$NOPE')))
    assert.are.equal('$NOPE', resolve(snippet('$NOPE')))
  end)

  it('never shares the variables whose point is to differ', function()
    local resolve = body.batch()
    assert.are_not.equal(resolve(snippet('$UUID')), resolve(snippet('$UUID')))
  end)
end)

describe('body.editable_final_tabstop', function()
  it('renumbers a placeholder on the exit point past the last tabstop', function()
    assert.are.equal('${1:a} ${2:b}', body.editable_final_tabstop('${1:a} ${0:b}'))
  end)

  it('counts tabstops written as transforms', function()
    assert.are.equal('${3/x/y/} ${4:b}', body.editable_final_tabstop('${3/x/y/} ${0:b}'))
  end)

  -- ${0|a,b|} is still a placeholder on the exit point, and the choice was
  -- being dropped silently: the '${0:' search that gated the whole function
  -- never matched it.
  it('renumbers a choice on the exit point too', function()
    assert.are.equal('${1:a} ${2|x,y|}', body.editable_final_tabstop('${1:a} ${0|x,y|}'))
  end)

  it('leaves a bare $0 alone', function()
    assert.are.equal('${1:a}$0', body.editable_final_tabstop('${1:a}$0'))
  end)

  it('leaves an escaped one alone -- it is text, not a tabstop', function()
    assert.are.equal('\\${0:a}', body.editable_final_tabstop('\\${0:a}'))
    assert.are.equal('\\${0:a} ${1:b}', body.editable_final_tabstop('\\${0:a} ${0:b}'))
  end)

  -- An escaped *backslash* is not an escaped tabstop: `\\${0:a}` is a literal
  -- backslash followed by a real exit-point placeholder, and packs that emit
  -- literal backslashes (LaTeX, markdown) hit this.
  it('renumbers one behind an escaped backslash', function()
    assert.are.equal('\\\\${1:a}', body.editable_final_tabstop('\\\\${0:a}'))
    -- Three: the backslash is escaped and so is the `$`, so it is text again.
    assert.are.equal('\\\\\\${0:a}', body.editable_final_tabstop('\\\\\\${0:a}'))
  end)
end)

describe('body.accepted', function()
  it('accepts what the grammar parses', function()
    assert.is_true(body.accepted('local ${1:x} = $0'))
  end)

  it('rejects what it does not', function()
    assert.is_false(body.accepted('${1:'))
  end)
end)

describe('body.text', function()
  it('calls a function body', function()
    assert.are.equal('made', body.text({ prefix = 'x', body = function() return 'made' end }))
  end)

  it('drops a function body that raises', function()
    assert.is_nil(body.text({ prefix = 'x', body = function() error('nope') end }))
  end)

  it('drops a function body that returns something unusable', function()
    assert.is_nil(body.text({ prefix = 'x', body = function() return nil end }))
    assert.is_nil(body.text({ prefix = 'x', body = function() return '${1:' end }))
  end)

  it('normalizes and resolves a function body', function()
    local text = body.text({ prefix = 'x', body = function() return '${0:y} $CURRENT_YEAR' end })
    assert.are.equal('${1:y} ' .. os.date('%Y'), text)
  end)

  -- vim.snippet.expand() raises on '' the same way it raises on a body that
  -- was empty to begin with, so a body left with nothing after resolution is
  -- as unusable as one normalize() already rejects at load time.
  it('drops a body that resolves to nothing', function()
    local saved = vim.bo.commentstring
    vim.bo.commentstring = '-- %s'

    assert.is_nil(body.text({ prefix = 'x', body = '$BLOCK_COMMENT_START' }))

    vim.bo.commentstring = saved
  end)
end)

describe('body.accepted against the real vim.snippet.expand', function()
  -- Parsing is not the whole test. vim.snippet.expand() asserts on these two
  -- *after* the grammar has accepted them -- and by then the completion engine
  -- has already deleted the typed word, so the raise takes the word with it.
  it('rejects a body with a second exit point', function()
    assert.is_false(body.accepted('print($0) --[[$0]]'))
    assert.is_false(body.accepted('${0:a} $0'))
  end)

  it('rejects placeholders that disagree about a tabstop', function()
    assert.is_false(body.accepted('${1:foo} ${1:bar}'))
  end)

  it('keeps the shapes that only look like those', function()
    assert.is_true(body.accepted('${1:foo} ${1:foo}'))
    assert.is_true(body.accepted('${1:foo} $1'))
    assert.is_true(body.accepted('print($0)'))
    assert.is_true(body.accepted('${1|a,b|}'))
  end)

  it('still rejects what the grammar cannot parse', function()
    assert.is_false(body.accepted('${'))
  end)

  -- Anything accepted() lets through has to survive the real thing.
  --
  -- No choice body here: expanding one schedules the |complete()| that opens
  -- its menu, and a headless runner is not in insert mode by the time that
  -- fires. The shape is covered above, where it is only parsed.
  it('agrees with vim.snippet.expand', function()
    local bufnr = helpers.typed('lua')
    for _, candidate in ipairs({
      'print($0) --[[$0]]',
      '${1:foo} ${1:bar}',
      '${1:foo} ${1:foo}',
      "require '${1:mod}'",
      '$CURRENT_YEAR',
    }) do
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '' })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local ok = pcall(vim.snippet.expand, body.resolve(candidate))
      vim.snippet.stop()
      assert.are.equal(body.accepted(candidate), ok, candidate)
    end
  end)

  -- well_formed() mirrors two asserts private to vim.snippet.expand() itself,
  -- so it has nothing to check itself against but the real thing. This pins
  -- expand() raising on both shapes: if core ever relaxes either, this test
  -- -- not well_formed() -- is what notices, on nightly, before a body that
  -- would now expand keeps getting dropped.
  it('still expects core to raise on the shapes well_formed() rejects', function()
    local bufnr = helpers.typed('lua')
    for _, candidate in ipairs({ '$0 $0', '${1:a} ${1:b}' }) do
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '' })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local ok = pcall(vim.snippet.expand, candidate)
      vim.snippet.stop()
      assert.is_false(ok, candidate)
      assert.is_false(body.accepted(candidate), candidate)
    end
  end)
end)

describe('body.normalize', function()
  it('renumbers the final tabstop and keeps the body', function()
    assert.are.equal('a${1:x}', body.normalize('a${0:x}'))
  end)

  it('drops a body expand() would raise on', function()
    assert.is_nil(body.normalize('$0$0'))
    assert.is_nil(body.normalize('${'))
  end)

  -- vim.snippet.expand() splits on '\n' only, so a body carrying a pack's
  -- CRLF (or classic-Mac CR) escapes would otherwise land in the buffer with
  -- a literal '^M' at the end of every line.
  it('turns CRLF line endings into plain newlines', function()
    assert.are.equal('a\nb\nc', body.normalize('a\r\nb\r\nc'))
  end)

  it('turns a lone CR into a newline', function()
    assert.are.equal('a\nb\nc', body.normalize('a\rb\rc'))
  end)

  it('leaves a body with no CR byte-identical', function()
    local text = 'class ${1:Foo}:\n    pass'
    assert.are.equal(text, body.normalize(text))
  end)

  it('leaves a literal backslash-r escape alone', function()
    assert.are.equal('a\\rb', body.normalize('a\\rb'))
  end)

  it('collapses a body that is only CRLF to a single newline', function()
    assert.are.equal('\n', body.normalize('\r\n'))
  end)

  it('still renumbers $0 after collapsing CRLF', function()
    assert.are.equal('a\n${1:x}', body.normalize('a\r\n${0:x}'))
  end)

  it('normalizes a CRLF body the same way vim.snippet.expand() would insert it', function()
    local bufnr = helpers.typed('django')
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '' })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local raw = '\r\nclass ${1:MODEL_NAME}CreateView(CreateView):\r\n    model = '
    local normalized = body.normalize(raw)
    assert.is_not_nil(normalized)
    vim.snippet.expand(body.resolve(normalized))

    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      assert.is_nil(line:find('\r', 1, true), line)
    end
    vim.snippet.stop()
  end)
end)

describe('body.resolve on the delimited forms', function()
  -- Neovim knows neither form for a variable it does not have: an unknown name
  -- becomes a tabstop holding its own *name*, and the author's default is
  -- discarded on the way. So `${CURRENT_YEAR:2024}` used to insert the string
  -- CURRENT_YEAR -- worse than having written nothing.
  it('fills in a variable that carries a default', function()
    assert.are.equal(os.date('%Y'), body.resolve('${CURRENT_YEAR:2024}'))
  end)

  -- Neovim implements no variable transforms at all -- ${TM_FILENAME/…/…/}
  -- already inserts the whole filename -- so a resolved one behaves the same.
  it('fills in a variable that carries a transform', function()
    assert.are.equal(os.date('%Y'), body.resolve('${CURRENT_YEAR/x/y/}'))
  end)

  it('finds the closing brace past braces of its own', function()
    assert.are.equal(os.date('%Y') .. '!', body.resolve('${CURRENT_YEAR:a{b}c}!'))
  end)

  it('leaves alone what is not ours to fill in', function()
    assert.are.equal('${NOPE:x}', body.resolve('${NOPE:x}'))
    assert.are.equal('${TM_FILENAME:x}', body.resolve('${TM_FILENAME:x}'))
    assert.are.equal('\\${CURRENT_YEAR:2024}', body.resolve('\\${CURRENT_YEAR:2024}'))
    assert.are.equal('${CURRENT_YEAR:oops', body.resolve('${CURRENT_YEAR:oops'))
  end)

  it('leaves the plain forms working', function()
    assert.are.equal(os.date('%Y'), body.resolve('$CURRENT_YEAR'))
    assert.are.equal(os.date('%Y'), body.resolve('${CURRENT_YEAR}'))
  end)
end)
