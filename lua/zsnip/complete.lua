---A source for Neovim's own insert-mode completion, through 'complete'.
---
---```lua
---require('zsnip.complete').enable()
---vim.o.autocomplete = true -- optional; CTRL-N works either way
---```
---
---The one wiring that needs no completion engine and no LSP client:
---'complete' takes a function source, and 'autocomplete' drives the same
---list as you type. Snippets then rank against buffer words in one menu, and
---'complete' can cap each source separately (`.^5,F...^10`).
---
---It is also the only source that has to expand the snippet itself. The other
---three hand an `lsp.CompletionItem` to something that knows what
---`insertTextFormat = Snippet` means -- vim.lsp.completion, blink or nvim-cmp.
---Nothing owns that on this path, so `enable()` installs two handlers -- a
---|CompleteDone| expander, which only ever runs on `reason == 'accept'` (the
---menu can also close on a discarded or cancelled selection, for which `word`
---is still whatever the menu last displayed), and a |CompleteChanged| stylist
---for the preview.

local completion = require('zsnip.completion')

local M = {}

---@class zsnip.CompleteOpts : zsnip.SourceOpts
---@field complete? boolean Add the source to 'complete' (default true). False when the caller sets the option itself.
---@field expand? fun(body: string) Expands the accepted snippet (default vim.snippet.expand). For a caller whose user chooses the engine somewhere else.
---@field description_style? 'lsp'|'classic' 'lsp' (default) renders the preview the way vim.lsp.completion would -- description above the highlighted body, menu row bare; 'classic' keeps the description in the menu row and the preview a plain body.

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

---Whether some 'complete' value already carries the source, however it got
---there.
---@param complete string
---@return boolean
local function has_source(complete)
  for _, entry in ipairs(vim.split(complete, ',', { plain = true, trimempty = true })) do
    if is_source(entry) then
      return true
    end
  end
  return false
end

---`complete` with the source appended, unless it is already there.
---@param complete string
---@return string
local function with_source(complete)
  if has_source(complete) then
    return complete
  end
  return complete == '' and SOURCE or complete .. ',' .. SOURCE
end

---`complete` with every entry that is the source taken back out.
---@param complete string
---@return string
local function without_source(complete)
  local kept = {}
  for _, entry in ipairs(vim.split(complete, ',', { plain = true, trimempty = true })) do
    if not is_source(entry) then
      kept[#kept + 1] = entry
    end
  end
  return table.concat(kept, ',')
end

---Every buffer 'complete' can meaningfully be set on: unloaded buffers have
---no local option instance to write to, and a fresh one inherits the global
---value `enable()`/`disable()` already touched.
---@return integer[]
local function loaded_buffers()
  return vim.tbl_filter(vim.api.nvim_buf_is_loaded, vim.api.nvim_list_bufs())
end

---Apply `transform` to the global 'complete' value and to every loaded
---buffer's own -- the two places `enable()`/`disable()` have to agree, so a
---buffer already open when `enable()` runs is not left behind by a change to
---only the default.
---@param transform fun(complete: string): string
local function rewrite_complete(transform)
  local function apply(scope)
    local current = vim.api.nvim_get_option_value('complete', scope)
    vim.api.nvim_set_option_value('complete', transform(current), scope)
  end
  apply({ scope = 'global' })
  for _, bufnr in ipairs(loaded_buffers()) do
    apply({ buf = bufnr })
  end
end

---Snippets for what was typed.
---
---A trigger can be the whole run (`console.log`, `<div`) or only its tail --
---`req` typed as `(req` is the run, but `(` belongs to the buffer, not the
---snippet. `matchfuzzy` has no notion of that boundary, so a base that
---matches nothing is tried again from its last keyword. What each matched
---item actually keeps of the run is per-item work, done in completefunc()
---below with `completion.unmatched()` -- the same rule the LSP-shaped
---sources use, which tries every suffix rather than only this one split.
---@param base string
---@return zsnip.Match[], boolean documented
local function matching(base)
  local function matches(prefix)
    -- `source_opts()` is the one field list the other three sources share;
    -- this source comes through it too and then puts its own fields -- the
    -- `max_items` cap and the prefix to match against -- back on top.
    local forwarded = completion.source_opts(options)
    forwarded.limit = options.limit
    forwarded.prefix = prefix
    return completion.matches(forwarded)
  end

  local matched, documented = matches(base)
  if #matched > 0 then
    return matched, documented
  end

  local tail = base:match('()' .. completion.KEYWORD .. '+$')
  if not tail or tail == 1 then
    return matched, documented
  end
  return matches(base:sub(tail))
end

---The 'complete' function source. See |complete-functions|.
---@param findstart 0|1
---@param base string
---@return integer|table
function M.completefunc(findstart, base)
  if findstart == 1 then
    local col = vim.api.nvim_win_get_cursor(0)[2]
    return completion.run_start(vim.api.nvim_get_current_line(), col)
  end

  -- An empty base is unranked, so matching() would hand back the whole
  -- filetype: fine for a manual CTRL-N, which is how Vim's own '.' source
  -- behaves too, but under 'autocomplete' that pops the menu after every
  -- space. Vim's own source shows nothing there for an empty base either.
  if base == '' and vim.o.autocomplete then
    return { words = {} }
  end

  local matched, documented = matching(base)
  local classic = options.description_style == 'classic'

  local items = {}
  for _, match in ipairs(matched) do
    local prefix = match.snippet.prefix
    -- Per item, not per response: matching() only had to find the snippet,
    -- but what the accepted trigger actually replaces is the same question
    -- the LSP-shaped sources answer with unmatched() against their textEdit.
    local head = completion.unmatched(base, prefix)
    -- By default the description belongs to the preview, not the menu row,
    -- and the preview carries what vim.lsp.completion would render: the same
    -- `document()` text the LSP-shaped sources put in `documentation`, styled
    -- by the CompleteChanged handler below. 'classic' is the menu row and a
    -- plain body, for a user who wants every description visible without
    -- selecting.
    local menu, info
    if documented then
      if classic then
        menu = match.snippet.description and completion.one_line(match.snippet.description) or ''
        info = match.text
      else
        info = completion.document(match.snippet, match.text, vim.bo.filetype)
      end
    end
    items[#items + 1] = {
      -- `word` covers everything Vim replaces, so it carries `head` back;
      -- `abbr` is what the menu shows, which is the trigger alone.
      word = head .. prefix,
      abbr = prefix,
      kind = 'Snippet',
      menu = menu,
      info = info,
      -- Two different triggers can replace the same run text (`if` and `#if`
      -- on `[#if` both produce word `[#if`). by_prefix already guarantees one
      -- item per trigger, so nothing here is a true duplicate; this only
      -- stops Vim from silently dropping the second item.
      dup = 1,
      -- The body travels with the item: by the time it is accepted the menu
      -- that produced it is gone, and CompleteDone gets only this.
      user_data = { zsnip = { body = match.text, keep = #head } },
    }
  end

  -- 'always' keeps the matching here. Without it Vim narrows the list it was
  -- handed as more is typed, by prefix -- which would quietly undo the fuzzy
  -- match that produced it.
  return { words = items, refresh = 'always' }
end

---Turn the accepted item into a session. Runs for every way the menu closes,
---including ones from other sources, so the body zsnip attached is the whole
---test -- and only `reason == 'accept'` means the item actually was. `discard`
---still carries `v:completed_item` for whatever was last navigated onto, and
---Vim processes the key that closed the menu (`(`, `<CR>`, `<Esc>`...) after
---this handler runs, so expanding on anything but accept races the typed key
---into a session that was never asked for.
local function expand()
  if vim.v.event.reason ~= 'accept' then
    return
  end
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

---The preview buffer stylize() marked up, until selection leaves zsnip's items.
---@type integer?
local styled

---Vim draws an F-source's `info` as plain text, and core's markdown styling
---is gated on `user_data.nvim.lsp` -- its own items. So zsnip does for its
---items exactly what |vim.lsp.completion| does for core's: treesitter
---markdown over the preview float, fences concealed, height fitted to what
---conceal left visible.
---
---And one thing core does not: the float and its buffer are reused by every
---item in one menu, so on the way out -- selection moving off a snippet --
---the styling is taken back off, or a plain buffer word shown after a
---snippet would inherit conceal and markdown highlights. Core's own items
---are left to core, which restyles them on its own schedule (some of it
---debounced) and must not be raced.
local function stylize()
  local completed = vim.v.event.completed_item or {}
  local mine = options.description_style ~= 'classic'
    and vim.tbl_get(completed, 'user_data', 'zsnip') ~= nil
  if not mine and styled == nil then
    return
  end

  -- 'selected' is load-bearing: complete_info() leaves the preview fields
  -- unset unless it is asked for alongside them.
  local preview = vim.fn.complete_info({ 'selected', 'preview_winid', 'preview_bufnr' })
  local winid, bufnr = preview.preview_winid, preview.preview_bufnr
  if not (winid and bufnr and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end

  if mine then
    vim.api.nvim_set_option_value('conceallevel', 2, { win = winid })
    pcall(vim.treesitter.start, bufnr, 'markdown')
    styled = bufnr
  elseif styled ~= bufnr then
    -- A fresh session brought a fresh preview; the styled one died with the last.
    styled = nil
    return
  elseif vim.tbl_get(completed, 'user_data', 'nvim', 'lsp') ~= nil then
    return
  else
    vim.api.nvim_set_option_value('conceallevel', 0, { win = winid })
    pcall(vim.treesitter.stop, bufnr)
    styled = nil
  end
  vim.api.nvim_win_resize(winid, -1, vim.api.nvim_win_text_height(winid, {}).all)
end

---What to put in 'complete' to serve snippets, for a caller that sets the
---option itself instead of letting `enable()` append. Append `^{count}` to cap
---the source; see |'complete'|. Pair it with `enable({ complete = false })`,
---which installs the handlers without touching the option.
---@return string
function M.source()
  return SOURCE
end

---Add zsnip to 'complete' and expand what gets accepted from it. Idempotent.
---
---'complete' is buffer-local, with no global fallback to inherit from later:
---every buffer holds a copy taken when it was created, so a change to the
---global default reaches only buffers opened after it. Appending just there,
---as `vim.opt.complete:append()` does, misses every buffer already open when
---`enable()` runs -- the common case, since the usual wiring is lazy-loading
---this on `InsertEnter`. So this touches both, everywhere the source is
---missing.
---
---Does not touch 'autocomplete': whether the menu opens by itself is the
---user's decision, and CTRL-N reaches this either way.
---@param opts? zsnip.CompleteOpts
function M.enable(opts)
  options = opts or {}

  if options.complete ~= false then
    rewrite_complete(with_source)
  end

  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })
  vim.api.nvim_create_autocmd('CompleteDone', { group = group, callback = expand })
  vim.api.nvim_create_autocmd('CompleteChanged', { group = group, callback = stylize })
end

---Whether zsnip is in 'complete' for `bufnr` -- which is what 'complete'
---itself is scoped to; a sibling buffer can disagree.
---@param bufnr? integer Defaults to the current buffer
---@return boolean
function M.enabled(bufnr)
  return has_source(vim.api.nvim_get_option_value('complete', { buf = bufnr or 0 }))
end

---Take zsnip back out of 'complete', in the same places `enable()` puts it,
---and stop expanding.
function M.disable()
  rewrite_complete(without_source)
  pcall(vim.api.nvim_del_augroup_by_name, GROUP)
  options = {}
end

return M
