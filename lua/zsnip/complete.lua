---A source for Neovim's own insert-mode completion, through 'complete'.
---
---```lua
---require('zsnip.complete').enable()
---vim.o.autocomplete = true -- optional; CTRL-N works either way
---```
---
---The one wiring that needs no completion engine and no LSP client: since
---Neovim 0.12 'complete' takes a function source, and 'autocomplete' drives
---the same list as you type. Snippets then rank against buffer words in one
---menu, and 'complete' can cap each source separately (`.^5,F...^10`).
---
---It is also the only source that has to expand the snippet itself. The other
---three hand an `lsp.CompletionItem` to something that knows what
---`insertTextFormat = Snippet` means -- vim.lsp.completion, blink or nvim-cmp.
---Nothing owns that on this path, so `enable()` installs a |CompleteDone|
---handler and `word` is only ever what the menu displayed.

local completion = require('zsnip.completion')

local M = {}

---@class zsnip.CompleteOpts : zsnip.SourceOpts

---What goes in 'complete'. `v:lua` resolves the require at call time, so the
---option can be set before this module has loaded. No comma or space in it,
---which is what would otherwise need escaping in an option value.
local SOURCE = [[Fv:lua.require'zsnip.complete'.completefunc]]

local GROUP = 'zsnip.complete'

---@type zsnip.CompleteOpts
local options = {}

---Where the run under the cursor starts, as a 0-based byte column.
---
---The whole non-blank run, not a keyword. What this returns is the range Vim
---replaces on accept, and a third of real triggers mix the two classes:
---`console.log` and `if(` put a symbol after word characters, `<div` and
---`#!/usr/bin/env` put one before. Stopping at the keyword boundary would
---leave the rest of what was typed in front of the expansion -- `console.`
---followed by the body of `console.log`. Triggers never contain a space, so
---the run can never be too short.
---@return integer
local function run_start()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = vim.api.nvim_get_current_line():sub(1, col)
  local start = vim.fn.match(before, [[\S\+$]])
  return start == -1 and col or start
end

---Snippets for what was typed, and how much of it is not theirs.
---
---A trigger can be the whole run (`console.log`, `<div`) or only its tail --
---`req` typed as `(req` is the run, but `(` belongs to the buffer, not the
---snippet. So a run that matches nothing is tried again from its last keyword,
---and the part skipped is kept out of the expansion.
---@param base string
---@return lsp.CompletionItem[], string kept
local function matching(base)
  local function items(prefix)
    return completion.items(vim.tbl_extend('force', options, { prefix = prefix }))
  end

  local matched = items(base)
  if #matched > 0 then
    return matched, ''
  end

  local tail = base:match('()[%w_]+$')
  if not tail or tail == 1 then
    return matched, ''
  end
  return items(base:sub(tail)), base:sub(1, tail - 1)
end

---The 'complete' function source. See |complete-functions|.
---@param findstart 0|1
---@param base string
---@return integer|table
function M.completefunc(findstart, base)
  if findstart == 1 then
    return run_start()
  end

  local matched, kept = matching(base)

  local items = {}
  for _, item in ipairs(matched) do
    items[#items + 1] = {
      -- `word` covers everything Vim replaces, so it carries `kept` back;
      -- `abbr` is what the menu shows, which is the trigger alone.
      word = kept .. item.label,
      abbr = item.label,
      kind = 'Snippet',
      menu = item.detail or '',
      info = item.insertText,
      -- The body travels with the item: by the time it is accepted the menu
      -- that produced it is gone, and CompleteDone gets only this.
      user_data = { zsnip = { body = item.insertText, keep = #kept } },
    }
  end

  -- 'always' keeps the matching here. Without it Vim narrows the list it was
  -- handed as more is typed, by prefix -- which would quietly undo the fuzzy
  -- match that produced it.
  return { words = items, refresh = 'always' }
end

---Turn the accepted item into a session. Runs for every completion, including
---ones from other sources, so the body zsnip attached is the whole test.
local function expand()
  local completed = vim.v.completed_item
  local data = vim.tbl_get(completed or {}, 'user_data', 'zsnip')
  if type(data) ~= 'table' or type(data.body) ~= 'string' then
    return
  end

  -- Vim inserted `word`, which is the trigger plus whatever `keep` bytes of
  -- the run were never the snippet's. The trigger is replaced; the rest stays.
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local start = col - #completed.word + (data.keep or 0)
  if start >= 0 and start < col then
    vim.api.nvim_buf_set_text(0, row - 1, start, row - 1, col, {})
  end
  vim.snippet.expand(data.body)
end

---Add zsnip to 'complete' and expand what gets accepted from it. Idempotent.
---
---Does not touch 'autocomplete': whether the menu opens by itself is the
---user's decision, and CTRL-N reaches this either way.
---@param opts? zsnip.CompleteOpts
function M.enable(opts)
  options = opts or {}

  if not vim.tbl_contains(vim.opt.complete:get(), SOURCE) then
    vim.opt.complete:append(SOURCE)
  end

  vim.api.nvim_create_autocmd('CompleteDone', {
    group = vim.api.nvim_create_augroup(GROUP, { clear = true }),
    callback = expand,
  })
end

---Whether zsnip is in 'complete' for the current buffer.
---@return boolean
function M.enabled()
  return vim.tbl_contains(vim.opt.complete:get(), SOURCE)
end

---Take zsnip back out of 'complete' and stop expanding.
function M.disable()
  vim.opt.complete:remove(SOURCE)
  pcall(vim.api.nvim_del_augroup_by_name, GROUP)
end

return M
