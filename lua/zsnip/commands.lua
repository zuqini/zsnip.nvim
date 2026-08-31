---The `:ZSnip` user command. Created by |zsnip.setup()| unless
---`command = false`.

local M = {}

local SUBCOMMANDS = { 'expand', 'list', 'reload' }

---@param filetype string
---@return string
local function label(filetype)
  return filetype == '' and '[no filetype]' or filetype
end

local function expand()
  local zsnip = require('zsnip')
  local completion = require('zsnip.completion')
  local filetype = vim.bo.filetype
  local snippets = zsnip.get(filetype)

  if #snippets == 0 then
    vim.notify(('zsnip: no snippets for %s'):format(label(filetype)), vim.log.levels.WARN)
    return
  end

  vim.ui.select(snippets, {
    prompt = ('Snippets (%s)'):format(filetype),
    format_item = function(snippet)
      return snippet.description and ('%s — %s'):format(snippet.prefix, completion.one_line(snippet.description))
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
  local completion = require('zsnip.completion')
  local filetype = vim.bo.filetype
  local snippets = require('zsnip').get(filetype)

  local width = 0
  for _, snippet in ipairs(snippets) do
    width = math.max(width, #snippet.prefix)
  end

  local lines = { ('# %d snippet(s) for %s'):format(#snippets, label(filetype)), '' }
  for _, snippet in ipairs(snippets) do
    local description = snippet.description and completion.one_line(snippet.description) or ''
    lines[#lines + 1] = ('%-' .. width .. 's  %-12s %s'):format(snippet.prefix, snippet.filetype or '', description)
  end

  -- `bufhidden = wipe` only reclaims the name once the buffer is hidden, so a
  -- second :ZSnip list with the first still on screen would raise E95 out of
  -- nvim_buf_set_name -- after the window and its contents already exist.
  local previous = vim.fn.bufnr('^zsnip://snippets$')
  if previous ~= -1 and vim.bo[previous].buftype == 'nofile' then
    vim.api.nvim_buf_delete(previous, { force = true })
  end

  vim.cmd('new')
  local bufnr = vim.api.nvim_get_current_buf()
  -- Set before naming or writing the buffer, so a failed set_lines -- an
  -- unforeseen newline surviving one_line() -- still leaves a buffer the
  -- guard above recognises and cleans up on the next :ZSnip list, rather
  -- than a same-named orphan with buftype == '' that E95s forever after.
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = bufnr })
  vim.api.nvim_buf_set_name(bufnr, 'zsnip://snippets')
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })
end

local function reload()
  require('zsnip').reload()
  vim.notify('zsnip: snippet sources reloaded')
end

local ACTIONS = { expand = expand, list = list, reload = reload }

---Remove `:ZSnip` if it is there. `setup { command = false }` has to be able
---to undo a `setup()` that ran before it -- under a lazy plugin manager the
---second call is the user's and the first was a dependency's default.
function M.remove()
  pcall(vim.api.nvim_del_user_command, 'ZSnip')
end

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
