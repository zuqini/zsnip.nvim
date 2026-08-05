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
---@field complete? boolean Add the source to 'complete' (default true). False when the caller sets the option itself.
---@field expand? fun(body: string) Expands the accepted snippet (default vim.snippet.expand). For a caller whose user chooses the engine somewhere else.
---@field description_style? 'lsp'|'classic' Where the description goes: 'lsp' (default) puts it in the preview above the body, where vim.lsp.completion puts an item's detail; 'classic' keeps it in the menu row.

---What goes in 'complete'. `v:lua` resolves the require at call time, so the
---option can be set before this module has loaded. No comma or space in it,
---which is what would otherwise need escaping in an option value.
local SOURCE = [[Fv:lua.require'zsnip.complete'.completefunc]]

---The same entry carrying a match limit.
local CAPPED = '^' .. vim.pesc(SOURCE) .. '%^%d+$'

local GROUP = 'zsnip.complete'

---@type zsnip.CompleteOpts
local options = {}

---An entry is this source whether or not it carries a `^{count}` cap: the cap
---belongs to the option value, not to the source, so a caller that sets
---'complete' itself is still running zsnip.
---@param entry string
---@return boolean
local function is_source(entry)
  return entry == SOURCE or entry:match(CAPPED) ~= nil
end

---Where the run under the cursor starts, as a 0-based byte column. The rule
---itself lives in `zsnip.completion`, which needs the same answer to anchor a
---`textEdit` for the other three sources.
---@return integer
local function run_start()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  return completion.run_start(vim.api.nvim_get_current_line(), col)
end

---Snippets for what was typed, and how much of it is not theirs.
---
---A trigger can be the whole run (`console.log`, `<div`) or only its tail --
---`req` typed as `(req` is the run, but `(` belongs to the buffer, not the
---snippet. So a run that matches nothing is tried again from its last keyword,
---and the part skipped is kept out of the expansion.
---@param base string
---@return zsnip.Match[], boolean documented, string kept
local function matching(base)
  local function matches(prefix)
    return completion.matches(vim.tbl_extend('force', options, { prefix = prefix }))
  end

  local matched, documented = matches(base)
  if #matched > 0 then
    return matched, documented, ''
  end

  local tail = base:match('()[%w_]+$')
  if not tail or tail == 1 then
    return matched, documented, ''
  end
  matched, documented = matches(base:sub(tail))
  return matched, documented, base:sub(1, tail - 1)
end

---The 'complete' function source. See |complete-functions|.
---@param findstart 0|1
---@param base string
---@return integer|table
function M.completefunc(findstart, base)
  if findstart == 1 then
    return run_start()
  end

  local matched, documented, kept = matching(base)
  local classic = options.description_style == 'classic'

  local items = {}
  for _, match in ipairs(matched) do
    local prefix = match.snippet.prefix
    local description = match.snippet.description
    -- By default the description belongs to the preview, not the menu row: it
    -- is where vim.lsp.completion puts an item's detail, so snippets read the
    -- same whichever of zsnip's sources served them. 'classic' is the menu
    -- row, for a user who wants every description visible without selecting.
    local menu, info
    if classic then
      menu = description or ''
      info = match.text
    else
      info = description and description ~= '' and description .. '\n\n' .. match.text or match.text
    end
    items[#items + 1] = {
      -- `word` covers everything Vim replaces, so it carries `kept` back;
      -- `abbr` is what the menu shows, which is the trigger alone.
      word = kept .. prefix,
      abbr = prefix,
      kind = 'Snippet',
      menu = documented and menu or nil,
      info = documented and info or '',
      -- The body travels with the item: by the time it is accepted the menu
      -- that produced it is gone, and CompleteDone gets only this.
      user_data = { zsnip = { body = match.text, keep = #kept } },
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
  if start < 0 or start >= col then
    -- The range the trigger should have occupied is not in the buffer, so
    -- something moved between the accept and here. Expanding anyway would put
    -- the body next to the trigger rather than over it.
    return
  end
  vim.api.nvim_buf_set_text(0, row - 1, start, row - 1, col, {})
  local expand_body = options.expand or vim.snippet.expand
  expand_body(data.body)
end

---What to put in 'complete' to serve snippets, for a caller that sets the
---option itself instead of letting `enable()` append. Append `^{count}` to cap
---the source; see |'complete'|. Pair it with `enable({ complete = false })`,
---which installs the |CompleteDone| handler without touching the option.
---@return string
function M.source()
  return SOURCE
end

---Add zsnip to 'complete' and expand what gets accepted from it. Idempotent.
---
---Does not touch 'autocomplete': whether the menu opens by itself is the
---user's decision, and CTRL-N reaches this either way.
---@param opts? zsnip.CompleteOpts
function M.enable(opts)
  options = opts or {}

  if options.complete ~= false and not M.enabled() then
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
  for _, entry in ipairs(vim.opt.complete:get()) do
    if is_source(entry) then
      return true
    end
  end
  return false
end

---Take zsnip back out of 'complete' and stop expanding.
function M.disable()
  for _, entry in ipairs(vim.opt.complete:get()) do
    if is_source(entry) then
      vim.opt.complete:remove(entry)
    end
  end
  pcall(vim.api.nvim_del_augroup_by_name, GROUP)
end

return M
