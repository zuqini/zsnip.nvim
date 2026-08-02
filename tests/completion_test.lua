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

describe('completion.items', function()
  it('marks items as snippets so the client expands them', function()
    registry.add('lua', { { prefix = 'req', body = "require '${1:mod}'", description = 'require' } })
    local item = completion.items({ filetype = 'lua' })[1]

    assert.are.equal('req', item.label)
    assert.are.equal(Kind.Snippet, item.kind)
    assert.are.equal(Format.Snippet, item.insertTextFormat)
    assert.are.equal("require '${1:mod}'", item.insertText)
    assert.are.equal('require', item.detail)
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

  it('can leave out detail and documentation', function()
    registry.add('lua', { { prefix = 'a', body = 'b', description = 'desc' } })

    local documented = completion.items({ filetype = 'lua' })[1]
    assert.are.equal('```lua\nb\n```', documented.documentation.value)

    local bare = completion.items({ filetype = 'lua', documentation = false })[1]
    assert.is_nil(bare.documentation)
    assert.is_nil(bare.detail)
  end)

  it('takes the filetype from the buffer when none is given', function()
    registry.add('lua', { { prefix = 'a', body = 'b' } })
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].filetype = 'lua'

    assert.are.same({ 'a' }, labels(completion.items({ bufnr = bufnr })))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
