---End-to-end coverage for the four ways a snippet reaches a menu.
---
---The unit specs check that each source builds the right items. These check
---that accepting one of those items puts the right text in the buffer -- which
---is a different question, and the one every bug in this area has been about.
---
---Two of the four are driven as real keystrokes in a child Neovim (see
---`tests/child.lua`); the other two are engines that are not installed, so
---their halves of the contract are exercised directly.

local child = require('child')
local completion = require('zsnip.completion')
local helpers = require('helpers')
local registry = require('zsnip.registry')

before_each(helpers.reset)
after_each(function()
  vim.snippet.stop()
  helpers.cleanup()
end)

---The triggers every source is checked against. Between them they cover the
---three shapes a trigger takes relative to the run it is typed in: the whole
---run (`req`), a run that starts with symbols (`<div`, `#!`), and a tail of
---one (`req` inside `(req`).
local SNIPPETS = {
  { prefix = 'req', body = "require '${1:mod}'" },
  { prefix = '<div', body = '<div>$0</div>' },
  { prefix = '#!', body = '#!/usr/bin/env bash' },
}

local EXPANDED = {
  ['req'] = { "require 'mod'" },
  ['<div'] = { '<div></div>' },
  ['#!'] = { '#!/usr/bin/env bash' },
  ['(req'] = { "(require 'mod'" },
}

---@param items lsp.CompletionItem[]
---@param label string
---@return lsp.CompletionItem?
local function labelled(items, label)
  for _, item in ipairs(items) do
    if item.label == label then
      return item
    end
  end
  return nil
end

describe('a snippet reaching the buffer', function()
  ---Every source ends in the same place: a client applies the item's textEdit
  ---and expands the body. What differs is only how the item got there.
  ---@param source fun(bufnr: integer): lsp.CompletionItem[]
  local function accepts(source)
    return function(typed, trigger)
      registry.add('lua', SNIPPETS)
      local bufnr = helpers.typed('lua', typed)
      local item = labelled(source(bufnr), trigger)
      assert.is_not_nil(item, ('no item labelled %q'):format(trigger))
      return helpers.accept(item)
    end
  end

  ---@param name string
  ---@param source fun(bufnr: integer): lsp.CompletionItem[]
  local function shared_contract(name, source)
    local accept = accepts(source)

    describe(name, function()
      it('expands a trigger that is the whole run', function()
        assert.are.same(EXPANDED['req'], accept('req', 'req'))
      end)

      -- The client picks the replaced span from the item, and every client
      -- that picks it for itself picks the keyword -- which starts after the
      -- `<`, so the trigger is cut in half and never offered at all.
      it('expands a trigger that starts with a symbol', function()
        assert.are.same(EXPANDED['<div'], accept('<div', '<div'))
      end)

      it('expands a trigger that is all symbols', function()
        assert.are.same(EXPANDED['#!'], accept('#!', '#!'))
      end)

      -- The `(` is the buffer's, not the snippet's, and it sits inside the
      -- span being replaced -- so it has to be put back.
      it('keeps the part of the run that was never the trigger', function()
        assert.are.same(EXPANDED['(req'], accept('(req', 'req'))
      end)

      it('anchors every item in a response to the same span', function()
        registry.add('lua', SNIPPETS)
        local bufnr = helpers.typed('lua', '<div')
        local starts = {}
        for _, item in ipairs(source(bufnr)) do
          assert.is_not_nil(item.textEdit)
          starts[item.textEdit.range.start.character] = true
        end
        -- vim.lsp.completion filters every item against the *lowest* start it
        -- is given, so a response that disagrees with itself drops items.
        assert.are.equal(1, vim.tbl_count(starts))
      end)
    end)
  end

  shared_contract('through the blink.cmp source', function(bufnr)
    local response
    require('zsnip.blink').new():get_completions({ bufnr = bufnr }, function(result)
      response = result
    end)
    return response.items
  end)

  shared_contract('through the nvim-cmp source', function(bufnr)
    local items
    require('zsnip.cmp').new():complete({ context = { bufnr = bufnr } }, function(result)
      items = result
    end)
    return items
  end)

  shared_contract('through the in-process LSP server', function(bufnr)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line()
    local result, answered = nil, false
    local client = require('zsnip.lsp').server({})({ on_exit = function() end })
    client.request('textDocument/completion', {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      position = {
        line = cursor[1] - 1,
        character = vim.str_utfindex(line, 'utf-16', cursor[2], false),
      },
    }, function(_, response)
      result, answered = response, true
    end)
    assert.is_true(vim.wait(2000, function()
      return answered
    end))
    return result.items
  end)
end)

describe('the completion contract clients rely on', function()
  it('offers a symbol trigger through vim.lsp.completion', function()
    registry.add('lua', SNIPPETS)
    local bufnr = helpers.typed('lua', '<div')
    local items = completion.items({ bufnr = bufnr })

    -- The client-side half: this is the function that decides which items
    -- survive and what word each one inserts. Without a textEdit it filters
    -- `<div` against the keyword `div` and drops it.
    local matches, boundary = vim.lsp.completion._convert_results(
      '<div',
      0,
      4,
      1,
      vim.fn.match('<div', '\\k*$'),
      nil,
      { items = items },
      'utf-8'
    )

    assert.are.equal(0, boundary)
    assert.contains(
      vim.tbl_map(function(match)
        return match.word
      end, matches),
      '<div'
    )
  end)

  it('sends nothing a client would have to guess at', function()
    registry.add('lua', SNIPPETS)
    local items = completion.items({ bufnr = helpers.typed('lua', 'req') })

    for _, item in ipairs(items) do
      assert.are.equal(vim.lsp.protocol.InsertTextFormat.Snippet, item.insertTextFormat)
      assert.are.equal(item.insertText, item.textEdit.newText)
      assert.is_string(item.filterText)
    end
  end)
end)

describe('driving a real Neovim', function()
  local ROOT = vim.fn.getcwd()

  ---@param fragment string
  ---@return table
  local function run(fragment)
    local results, log = child.run(fragment, ROOT, helpers.tempdir())
    assert.is_true(next(results) ~= nil, 'child produced nothing:\n' .. log)
    return results
  end

  local SETUP = ([[
    require('zsnip').setup()
    require('zsnip').add_snippets('lua', %s)
    vim.o.completeopt = 'menuone,noselect'
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    vim.cmd('edit ' .. dir .. '/f.lua')
    vim.bo.filetype = 'lua'
  ]]):format(vim.inspect(SNIPPETS))

  -- The path that needs no LSP client and no completion engine: 'complete'
  -- with a function source, and a CompleteDone handler that expands what was
  -- accepted. Nothing else owns the expansion on this path.
  it("serves and expands through builtin 'complete'", function()
    local results = run(SETUP .. [[
      require('zsnip.complete').enable()
      each({ 'req', '<div', '#!', '(req' }, '<C-n>', done)
    ]])

    for _, typed in ipairs({ 'req', '<div', '#!', '(req' }) do
      assert.is_not_nil(results[typed], typed .. ' was never driven')
      assert.are.same(EXPANDED[typed], results[typed].lines, 'typed ' .. typed)
    end
  end)

  -- The path this was broken on: the server used to answer inline, which put
  -- vim.fn.complete() back inside the textlock that 'omnifunc' returning -2
  -- exists to escape. Every trigger died with E565 and no menu appeared.
  it('serves and expands through vim.lsp.completion', function()
    local results = run(SETUP .. [[
      require('zsnip').start_lsp_server({ completion = { autotrigger = false } })
      vim.defer_fn(function()
        emit('clients', #vim.lsp.get_clients({ name = 'zsnip' }))
        each({ 'req', '<div', '#!', '(req' }, '<C-x><C-o>', done)
      end, 500)
    ]])

    assert.are.equal(1, results.clients)
    for _, typed in ipairs({ 'req', '<div', '#!', '(req' }) do
      assert.is_not_nil(results[typed], typed .. ' was never driven')
      assert.are.same(EXPANDED[typed], results[typed].lines, 'typed ' .. typed)
    end
  end)

  it('leaves no error behind on the omnifunc path', function()
    local results = run(SETUP .. [[
      require('zsnip').start_lsp_server({ completion = { autotrigger = false } })
      vim.defer_fn(function()
        each({ 'req' }, '<C-x><C-o>', function()
          emit('errors', vim.v.errmsg)
          done()
        end)
      end, 500)
    ]])

    assert.are.equal('', results.errors)
  end)
end)
