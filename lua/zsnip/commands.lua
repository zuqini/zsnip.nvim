---The `:ZSnip` user command. Created by |zsnip.setup()| unless
---`command = false`.

local M = {}

local SUBCOMMANDS = { 'expand', 'list', 'reload' }

local function expand()
  local zsnip = require('zsnip')
  local filetype = vim.bo.filetype
  local snippets = zsnip.get(filetype)

  if #snippets == 0 then
    vim.notify(('zsnip: no snippets for %s'):format(filetype == '' and '[no filetype]' or filetype),
      vim.log.levels.WARN)
    return
  end

  vim.ui.select(snippets, {
    prompt = ('Snippets (%s)'):format(filetype),
    format_item = function(snippet)
      return snippet.description and ('%s — %s'):format(snippet.prefix, snippet.description)
        or snippet.prefix
    end,
  }, function(choice)
    if choice then
      zsnip.expand_snippet(choice)
    end
  end)
end

---A scratch buffer answering "what does this filetype actually have, and
---which filetype did each entry come from" -- the question inheritance and
---the global bucket make hard to eyeball.
local function list()
  local filetype = vim.bo.filetype
  local snippets = require('zsnip').get(filetype)

  local width = 0
  for _, snippet in ipairs(snippets) do
    width = math.max(width, #snippet.prefix)
  end

  local lines = { ('# %d snippet(s) for %s'):format(#snippets, filetype == '' and '[no filetype]' or filetype), '' }
  for _, snippet in ipairs(snippets) do
    lines[#lines + 1] = ('%-' .. width .. 's  %-12s %s')
      :format(snippet.prefix, snippet.filetype or '', snippet.description or '')
  end

  vim.cmd('new')
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = bufnr })
  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })
  vim.api.nvim_buf_set_name(bufnr, 'zsnip://snippets')
end

local function reload()
  require('zsnip').reload()
  vim.notify('zsnip: snippet sources reloaded')
end

local ACTIONS = { expand = expand, list = list, reload = reload }

function M.create()
  vim.api.nvim_create_user_command('ZSnip', function(args)
    local action = ACTIONS[args.args ~= '' and args.args or 'expand']
    if not action then
      vim.notify(('zsnip: unknown subcommand %q'):format(args.args), vim.log.levels.ERROR)
      return
    end
    action()
  end, {
    nargs = '?',
    desc = 'zsnip: expand, list or reload snippets',
    complete = function(lead)
      return vim.tbl_filter(function(name)
        return vim.startswith(name, lead)
      end, SUBCOMMANDS)
    end,
  })
end

return M
