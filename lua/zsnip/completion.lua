---Snippets as completion candidates.
---
---Two layers. `matches()` is the selection pipeline -- which snippets a
---request gets, in what order, with their bodies resolved -- and knows nothing
---about any protocol. `items()` projects those onto `lsp.CompletionItem[]`,
---which is what |zsnip.completion_items()| and the three LSP-shaped sources
---(`zsnip.lsp`, `zsnip.blink`, `zsnip.cmp`) want. `zsnip.complete` builds its
---own shape from `matches()` and `document()` instead: it is not handing an
---item to anyone, but its preview must read like everyone else's.
---
---Underneath both layers sit the rules every source shares, which is why
---`zsnip.complete` uses `matches()` and those shared rules directly rather
---than through `items()`.
---
---The bodies are already LSP snippet syntax, so `insertTextFormat` is all a
---client needs to expand them -- there is nothing to translate.

local body = require('zsnip.body')
local config = require('zsnip.config')
local registry = require('zsnip.registry')

local Kind = vim.lsp.protocol.CompletionItemKind
local Format = vim.lsp.protocol.InsertTextFormat

local M = {}

---Where the non-blank run under `col` starts, as a 0-based byte column.
---
---The whole run, not a keyword. This is the span a source offers to replace,
---and a third of real triggers mix the two classes: `console.log` and `if(`
---put a symbol after word characters, `<div` and `#!/usr/bin/env` put one
---before. Stopping at the keyword boundary leaves the rest of what was typed
---in front of the expansion. Triggers never contain a space, so the run can
---never be too short.
---@param line string
---@param col integer 0-based byte column
---@return integer
function M.run_start(line, col)
  local start = line:sub(1, col):find('%S+$')
  return start and start - 1 or col
end

local KEYWORD = '[%w_\128-\255]'
M.KEYWORD = KEYWORD

---Byte where the part of `run` the trigger accounts for begins -- longest
---first -- and whether it starts the trigger outright (`(req` against `req`)
---or only fuzzy-matches it (`c.log` against `console.log`); nil when no
---legal start does either. Case-insensitive, because the menu matches that
---way too. A keyword trigger has to start a word, the rule `init.match()`
---applies to expansion, so a split inside one is skipped.
---@param run string
---@param trigger string
---@return integer? start
---@return boolean matched
local function trigger_start(run, trigger)
  local word_trigger = trigger:match('^' .. KEYWORD) ~= nil
  for start = math.max(1, #run - #trigger + 1), #run do
    -- A byte >= 0x80 is always part of a multi-byte character, never a
    -- boundary -- see the same caveat on `init.match()`.
    local before = run:sub(start - 1, start - 1)
    if not (word_trigger and before:match(KEYWORD)) then
      local typed = run:sub(start)
      if trigger:sub(1, #typed):lower() == typed:lower() then
        return start, true
      end
      -- A Vimscript call, so only at a legal start the cheap test rejected.
      if #vim.fn.matchfuzzy({ trigger }, typed) > 0 then
        return start, false
      end
    end
  end
  return nil, false
end

---How much of `run` a trigger's replacement has to put back, and whether some
---legal start of `run` actually matched the trigger.
---
---Three cases. A suffix of `run` starts the trigger (`req` typed as `(req`):
---the rest is `head`, `matched` true. A legal suffix only fuzzy-matches it
---instead (`c.log` against `console.log`, consumed whole -- `head` is ''):
---`matched` false. Otherwise the run's trailing keyword is what got typed and
---the rest is `head` (`x` against `req` answers ''), `matched` false. `head`
---always goes back into `insertText`/`newText`; `matched` is why it only goes
---into `filterText` when it really was the trigger's -- see `items()`.
---@param run string
---@param trigger string
---@return string head
---@return boolean matched
function M.unmatched(run, trigger)
  local start, matched = trigger_start(run, trigger)
  if start then
    return run:sub(1, start - 1), matched
  end
  return run:match('^(.-)' .. KEYWORD .. '*$'), false
end

---What `zsnip.blink`, `zsnip.cmp`, `zsnip.lsp` and `zsnip.complete` forward,
---in one place so that a new `zsnip.SourceOpts` field does not have to be
---re-plumbed through all four. The uncapped default belongs to the three
---LSP-shaped ones alone, because an engine that filters and ranks the
---response wants the whole filetype; `zsnip.complete` comes through here too,
---then puts its own `limit` -- capped by `max_items` unless the caller set one
---itself -- back on top, since it matches for itself and nothing downstream
---trims what it returns.
---@param opts zsnip.SourceOpts
---@param bufnr? integer
---@param position? lsp.Position
---@return zsnip.CompletionOpts
function M.source_opts(opts, bufnr, position)
  return {
    bufnr = bufnr,
    position = position,
    limit = opts.limit or math.huge,
    documentation = opts.documentation,
    filter = opts.filter,
  }
end

---`opts.bufnr` resolved the way `nvim_buf_*` calls treat it: nil and the
---conventional 0 both mean the current buffer, so a hand-rolled source
---passing 0 does not lose the `textEdit` anchor `cursor_in()` needs a real
---bufnr for.
---@param opts zsnip.CompletionOpts
---@return integer bufnr
---@return string filetype
local function resolve_buffer(opts)
  local bufnr = opts.bufnr
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  return bufnr, opts.filetype or vim.bo[bufnr].filetype
end

---@param opts? zsnip.CompletionOpts
---@return zsnip.Match[] matches
---@return boolean documented Whether the caller asked for bodies and descriptions
function M.matches(opts)
  opts = opts or {}
  local _, filetype = resolve_buffer(opts)
  local limit = opts.limit or config.options.max_items
  local documented = opts.documentation
  if documented == nil then
    documented = config.options.documentation
  end

  -- First prefix wins: the registry orders a filetype's own snippets ahead of
  -- inherited and global ones, so shadowing follows that order. Filtering
  -- happens here rather than on the result so that `limit` is spent on
  -- snippets the caller will actually keep.
  local by_prefix, triggers = {}, {}
  for _, snippet in ipairs(registry.get(filetype)) do
    local keep = not by_prefix[snippet.prefix] and (not opts.filter or opts.filter(snippet))
    if keep then
      by_prefix[snippet.prefix] = snippet
      triggers[#triggers + 1] = snippet.prefix
    end
  end

  -- matchfuzzy rejects a fractional or non-finite limit, and a negative one
  -- is nonsense; math.huge, the spelling every uncapped caller passes, is
  -- already its own floor and survives this untouched.
  limit = math.max(0, math.floor(limit))

  local ranked = opts.prefix ~= nil and opts.prefix ~= ''
  if ranked then
    -- `math.huge` is what every caller that wants no cap passes. Omitting
    -- the argument is not the same as passing nil, which reaches Vimscript
    -- as v:null and raises E1206.
    if limit == math.huge then
      triggers = vim.fn.matchfuzzy(triggers, opts.prefix)
    else
      triggers = vim.fn.matchfuzzy(triggers, opts.prefix, { limit = limit })
    end
  end

  -- Resolving a body is per-item work; the values in it are not. One resolver
  -- for the whole response shares them across the items -- see `body.batch()`.
  local resolve = body.batch()

  local matched = {}
  for _, trigger in ipairs(triggers) do
    if #matched >= limit then
      break
    end
    local snippet = by_prefix[trigger]
    local text = resolve(snippet)
    if text then
      matched[#matched + 1] = { snippet = snippet, text = text, ranked = ranked }
    end
  end
  return matched, documented
end

---The line and cursor a request came from, or nil when there is no buffer
---position to anchor a `textEdit` to.
---
---An explicit `position` is the LSP one, in UTF-16 units. Without it the
---cursor is used, which is where blink.cmp and nvim-cmp complete from -- but
---only in the buffer we are actually in, since a request for some other
---buffer has no cursor of its own to speak of.
---@param opts zsnip.CompletionOpts
---@param bufnr integer
---@return { row: integer, line: string, col: integer }? at 0-based row, 0-based byte col
local function cursor_in(opts, bufnr)
  local row, col
  if opts.position then
    row = opts.position.line
  elseif bufnr == vim.api.nvim_get_current_buf() then
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
    if not ok then
      return nil
    end
    row, col = cursor[1] - 1, cursor[2]
  else
    return nil
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then
    return nil
  end
  if not col then
    -- str_byteindex is the only thing that knows what a UTF-16 character was;
    -- a position past the end of the line is a client racing an edit.
    local ok, byte = pcall(vim.str_byteindex, line, 'utf-16', opts.position.character, false)
    col = ok and byte or #line
  end
  return { row = row, line = line, col = math.min(col, #line) }
end

---The span a response replaces, and the text already sitting in it.
---
---One span for every item in the response, not one per item:
---|vim.lsp.completion| filters the whole list against the *lowest* start it is
---given, so a response that disagrees with itself drops the items that asked
---for more.
---@param opts zsnip.CompletionOpts
---@param bufnr integer
---@return { range: lsp.Range, run: string }?
local function replacement(opts, bufnr)
  local at = cursor_in(opts, bufnr)
  if not at then
    return nil
  end

  local start_col = M.run_start(at.line, at.col)
  local function character(col)
    local ok, index = pcall(vim.str_utfindex, at.line, 'utf-16', col, false)
    return ok and index or col
  end
  return {
    range = {
      start = { line = at.row, character = character(start_col) },
      ['end'] = { line = at.row, character = character(at.col) },
    },
    run = at.line:sub(start_col + 1, at.col),
  }
end

---A description may contain a newline, whatever produced it -- a vscode
---array-form description joined with `\n`, or a body handed to
---`add_snippets()` straight from a user's config. A one-line row -- a
---completion menu row, `:ZSnip list`'s buffer, its picker's row -- must not.
---Never raises: a description that is not even a string (a config typo) is
---stringified first, the same tolerance a bare `%s` format used to give it.
---@param description unknown
---@return string
function M.one_line(description)
  local flattened = tostring(description):gsub('%s*\n%s*', ' ')
  return flattened
end

---The one preview text every route shows: the description, then the body
---fenced for the filetype. `zsnip.complete` renders the same string, so a
---snippet reads byte-identically whichever source served it.
---@param snippet zsnip.Snippet
---@param text string
---@param filetype string
---@return string
function M.document(snippet, text, filetype)
  -- A body can carry fences of its own (markdown snippet packs do), and a
  -- ``` inside would close ours early: the fence has to outgrow the longest
  -- backtick run in the body.
  local ticks = 3
  for run in text:gmatch('`+') do
    if #run >= ticks then
      ticks = #run + 1
    end
  end
  local fence = ('`'):rep(ticks)
  local fenced = ('%s%s\n%s\n%s'):format(fence, filetype, text, fence)
  local description = snippet.description
  if description and description ~= '' then
    -- A non-string description (a config typo, or a malformed pack entry)
    -- must not raise out of a completion response the way a bare `..` would.
    return tostring(description) .. '\n\n' .. fenced
  end
  return fenced
end

---@param snippet zsnip.Snippet
---@param text string
---@param filetype string
---@param documented boolean
---@return lsp.CompletionItem
local function item(snippet, text, filetype, documented)
  local entry = {
    label = snippet.prefix,
    kind = Kind.Snippet,
    insertText = text,
    insertTextFormat = Format.Snippet,
  }
  if documented then
    -- The description rides in `documentation`, not `detail`: clients fence
    -- `detail` as code in the buffer's filetype -- vim.lsp.completion
    -- included -- and the description is prose.
    entry.documentation = {
      kind = 'markdown',
      value = M.document(snippet, text, filetype),
    }
  end
  return entry
end

---@param opts? zsnip.CompletionOpts
---@return lsp.CompletionItem[]
function M.items(opts)
  opts = opts or {}
  local bufnr, filetype = resolve_buffer(opts)
  local matched, documented = M.matches(opts)

  -- Without a textEdit the client picks the replaced span itself, and every
  -- client picks the keyword before the cursor -- which cuts `<div` in half
  -- (the item is never offered, because `<div` does not match the prefix
  -- `div`) and misses `#!` entirely (nothing before the cursor is replaced, so
  -- the trigger is left sitting in front of its own expansion).
  local edit = replacement(opts, bufnr)

  local items = {}
  for index, match in ipairs(matched) do
    local entry = item(match.snippet, match.text, filetype, documented)
    if edit then
      -- The part of the run that is not the trigger's is buffer text inside
      -- the replaced span, so it has to be put back -- and put back as text,
      -- not as snippet syntax -- whether or not it was ever the trigger's.
      local keep, tail_matched = M.unmatched(edit.run, match.snippet.prefix)
      -- `insertText` is kept in step with `newText` rather than left as the
      -- bare body: a client reads one or the other, never both, and the two
      -- disagreeing is how the `(` ends up in the buffer twice.
      entry.insertText = body.literal(keep) .. match.text
      entry.textEdit = { range = edit.range, newText = entry.insertText }
      -- `keep` only belongs in filterText when it came from the trigger's own
      -- run: for an unrelated run (bare `(`) leaving it out is what keeps a
      -- client that filters by prefix alone from offering every snippet.
      entry.filterText = tail_matched and (keep .. match.snippet.prefix) or match.snippet.prefix
    end
    -- Only when zsnip did the ranking. Unranked, the order is the order the
    -- packs happened to be read in, and pinning the client to that is what
    -- stops it applying the ranking it is better at than we are.
    if match.ranked then
      entry.sortText = ('%06d'):format(index - 1)
    end
    items[#items + 1] = entry
  end
  return items
end

return M
