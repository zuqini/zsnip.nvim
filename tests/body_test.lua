local body = require('zsnip.body')

describe('body.resolve', function()
  it('fills in variables Neovim does not know', function()
    assert.are.equal(os.date('%Y'), body.resolve('$CURRENT_YEAR'))
    assert.are.equal(os.date('%Y'), body.resolve('${CURRENT_YEAR}'))
  end)

  it('leaves unknown variables for the engine to handle', function()
    assert.are.equal('$NAME', body.resolve('$NAME'))
    assert.are.equal('$C$', body.resolve('$C$'))
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

  -- Neither Neovim nor LuaJIT seeds math.random, so a generator built on it
  -- hands out the same "random" value on every start, forever. These are the
  -- three variables for which that is the whole point.
  it('does not repeat a UUID or a random number', function()
    local seen = {}
    for _ = 1, 32 do
      for _, name in ipairs({ 'UUID', 'RANDOM', 'RANDOM_HEX' }) do
        local value = body.resolve('$' .. name)
        assert.is_nil(seen[value], name .. ' repeated a value: ' .. value)
        seen[value] = true
      end
    end
  end)

  it('keeps RANDOM and RANDOM_HEX in their documented shape', function()
    assert.is_truthy(body.resolve('$RANDOM'):match('^%d%d%d%d%d%d$'))
    assert.is_truthy(body.resolve('$RANDOM_HEX'):match('^%x%x%x%x%x%x$'))
  end)

  it('escapes snippet syntax coming out of a variable', function()
    -- The register is stubbed rather than written to: a headless CI runner has
    -- no clipboard provider, so '+' reads back empty there.
    local getreg = vim.fn.getreg
    vim.fn.getreg = function()
      return { 'a $1 }' }
    end
    local resolved = body.resolve('$CLIPBOARD')
    vim.fn.getreg = getreg

    assert.are.equal('a \\$1 \\}', resolved)
  end)

  it('reads comment markers off the buffer', function()
    local saved = vim.bo.commentstring

    vim.bo.commentstring = '-- %s'
    assert.are.equal('--', body.resolve('$LINE_COMMENT'))
    -- A line-comment buffer has no honest answer for a block comment.
    assert.are.equal('$BLOCK_COMMENT_START', body.resolve('$BLOCK_COMMENT_START'))

    vim.bo.commentstring = '/* %s */'
    assert.are.equal('/*', body.resolve('$BLOCK_COMMENT_START'))
    assert.are.equal('*/', body.resolve('$BLOCK_COMMENT_END'))

    vim.bo.commentstring = saved
  end)

  it('short-circuits a body with no variables', function()
    assert.are.equal('plain text', body.resolve('plain text'))
  end)
end)

describe('body.resolve with a shared cache', function()
  ---@return integer reads, function restore
  local function counting_clipboard()
    local getreg = vim.fn.getreg
    local reads = { count = 0 }
    vim.fn.getreg = function()
      reads.count = reads.count + 1
      return { 'pasted' }
    end
    return reads, function()
      vim.fn.getreg = getreg
    end
  end

  it('reads an expensive variable once for the whole batch', function()
    local reads, restore = counting_clipboard()
    local cache = {}
    for _ = 1, 10 do
      assert.are.equal('pasted', body.resolve('$CLIPBOARD', cache))
    end
    restore()

    assert.are.equal(1, reads.count)
  end)

  it('still reads it per body without one', function()
    local reads, restore = counting_clipboard()
    for _ = 1, 10 do
      body.resolve('$CLIPBOARD')
    end
    restore()

    assert.are.equal(10, reads.count)
  end)

  it('caches a name that resolves to nothing', function()
    local cache = {}
    assert.are.equal('$NOPE', body.resolve('$NOPE', cache))
    assert.are.equal(false, cache.NOPE)
  end)

  it('never caches the variables whose point is to differ', function()
    local cache = {}
    assert.are_not.equal(body.resolve('$UUID', cache), body.resolve('$UUID', cache))
    assert.is_nil(cache.UUID)
  end)
end)

describe('body.editable_final_tabstop', function()
  it('renumbers a placeholder on the exit point past the last tabstop', function()
    assert.are.equal('${1:a} ${2:b}', body.editable_final_tabstop('${1:a} ${0:b}'))
  end)

  it('counts tabstops written as transforms', function()
    assert.are.equal('${3/x/y/} ${4:b}', body.editable_final_tabstop('${3/x/y/} ${0:b}'))
  end)

  it('leaves a bare $0 alone', function()
    assert.are.equal('${1:a}$0', body.editable_final_tabstop('${1:a}$0'))
  end)

  it('leaves an escaped one alone -- it is text, not a tabstop', function()
    assert.are.equal('\\${0:a}', body.editable_final_tabstop('\\${0:a}'))
    assert.are.equal('\\${0:a} ${1:b}', body.editable_final_tabstop('\\${0:a} ${0:b}'))
  end)
end)

describe('body.expandable', function()
  it('accepts what the grammar parses', function()
    assert.is_true(body.expandable('local ${1:x} = $0'))
  end)

  it('rejects what it does not', function()
    assert.is_false(body.expandable('${1:'))
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
end)
