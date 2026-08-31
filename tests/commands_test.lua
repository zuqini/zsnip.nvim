local helpers = require('helpers')
local commands = require('zsnip.commands')
local registry = require('zsnip.registry')

before_each(function()
  helpers.reset()
  commands.create()
end)

after_each(function()
  pcall(vim.api.nvim_del_user_command, 'ZSnip')
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(bufnr):match('zsnip://snippets$') then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end
  helpers.cleanup()
end)

local notifications = helpers.notifications

describe(':ZSnip', function()
  it('filters completions by what has been typed', function()
    assert.are.same({ 'expand', 'list', 'reload' }, vim.fn.getcompletion('ZSnip ', 'cmdline'))
    assert.are.same({ 'reload' }, vim.fn.getcompletion('ZSnip r', 'cmdline'))
    assert.are.same({}, vim.fn.getcompletion('ZSnip zz', 'cmdline'))
  end)

  -- The completion list and the dispatch table are two hand-maintained lists
  -- of the same names, and nothing else would notice them drifting apart.
  it('dispatches every subcommand it offers', function()
    vim.cmd('enew')
    vim.bo.filetype = 'nothing_here'

    for _, name in ipairs(vim.fn.getcompletion('ZSnip ', 'cmdline')) do
      local messages = notifications(function()
        vim.cmd('ZSnip ' .. name)
      end)
      for _, message in ipairs(messages) do
        assert.is_nil(message:match('unknown subcommand'), name .. ' is offered but not dispatched')
      end
    end
  end)

  it('reports an unknown subcommand instead of doing nothing', function()
    local messages = notifications(function()
      vim.cmd('ZSnip nonsense')
    end)
    assert.are.equal(1, #messages)
    assert.is_truthy(messages[1]:match('unknown subcommand'))
  end)

  it('warns rather than opening a picker when the filetype has nothing', function()
    vim.cmd('enew')
    vim.bo.filetype = 'nothing_here'

    local messages = notifications(function()
      vim.cmd('ZSnip expand')
    end)
    assert.are.equal(1, #messages)
    assert.is_truthy(messages[1]:match('no snippets for nothing_here'))
  end)

  it('expands the snippet chosen from the picker', function()
    registry.add('lua', { { prefix = 'req', body = 'local ${1:m} = require' } })
    vim.cmd('enew')
    vim.bo.filetype = 'lua'

    local select = vim.ui.select
    local formatted
    vim.ui.select = function(items, opts, on_choice)
      formatted = opts.format_item(items[1])
      on_choice(items[1])
    end
    vim.cmd('ZSnip expand')
    vim.ui.select = select

    assert.are.equal('req', formatted)
    assert.is_true(vim.snippet.active())
    assert.are.equal('local m = require', vim.api.nvim_get_current_line())
  end)

  -- Before the description was flattened, nvim_buf_set_lines raised on a
  -- multi-line one, and it raised *after* nvim_buf_set_name -- leaving a
  -- same-named buffer with buftype == '' that the reuse guard never
  -- recognised, so E95 followed forever after.
  it('lists twice in a row, even across a run with a multi-line description', function()
    registry.add('lua', { { prefix = 'req', body = 'b', description = 'a\nb' } })
    vim.cmd('enew')
    vim.bo.filetype = 'lua'

    assert.has_no.errors(function()
      vim.cmd('ZSnip list')
    end)
    assert.has_no.errors(function()
      vim.cmd('ZSnip list')
    end)

    local named = vim.tbl_filter(function(bufnr)
      return vim.api.nvim_buf_get_name(bufnr):match('zsnip://snippets$') ~= nil
    end, vim.api.nvim_list_bufs())
    assert.are.equal(1, #named)
  end)

  it('lists what the filetype has, with where each entry came from', function()
    registry.add('lua', { { prefix = 'req', body = 'b', description = 'a require' } })
    registry.add('all', { { prefix = 'todo', body = 'b' } })
    vim.cmd('enew')
    vim.bo.filetype = 'lua'

    vim.cmd('ZSnip list')
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

    assert.is_truthy(vim.api.nvim_buf_get_name(0):match('zsnip://snippets$'))
    assert.is_truthy(lines[1]:match('2 snippet%(s%) for lua'))
    assert.is_truthy(lines[3]:match('^req%s+lua%s+a require'))
    assert.is_truthy(lines[4]:match('^todo%s+all'))
    assert.is_false(vim.bo.modifiable)
    assert.are.equal('nofile', vim.bo.buftype)
  end)

  -- `bufhidden = wipe` only reclaims the name once the buffer is hidden, so
  -- running it twice with the first still on screen used to raise E95 -- after
  -- the new window and its contents already existed.
  it('can be listed twice with the first list still open', function()
    registry.add('lua', { { prefix = 'req', body = 'b' } })
    vim.cmd('enew')
    vim.bo.filetype = 'lua'

    vim.cmd('ZSnip list')
    vim.cmd('wincmd p')
    assert.has_no.errors(function()
      vim.cmd('ZSnip list')
    end)

    local named = vim.tbl_filter(function(bufnr)
      return vim.api.nvim_buf_get_name(bufnr):match('zsnip://snippets$') ~= nil
    end, vim.api.nvim_list_bufs())
    assert.are.equal(1, #named)
  end)

  it('defaults to expand with no argument', function()
    vim.cmd('enew')
    vim.bo.filetype = 'nothing_here'

    local messages = notifications(function()
      vim.cmd('ZSnip')
    end)
    assert.is_truthy(messages[1]:match('no snippets'))
  end)

  it('reloads what was read from disk and keeps what was added', function()
    local dir = helpers.snipmate_pack({ lua = 'snippet fromdisk\n\tbody' })
    helpers.use_rtp(dir)
    require('zsnip.loaders.from_snipmate').lazy_load()
    registry.add('lua', { { prefix = 'added', body = 'b' } })
    vim.cmd('enew')
    vim.bo.filetype = 'lua'

    assert.are.same({ 'added', 'fromdisk' }, helpers.prefixes(registry.get('lua')))
    vim.fn.delete(dir .. '/snippets/lua.snippets')

    local messages = notifications(function()
      vim.cmd('ZSnip reload')
    end)

    assert.is_truthy(messages[1]:match('reloaded'))
    assert.are.same({ 'added' }, helpers.prefixes(registry.get('lua')))
  end)
end)
