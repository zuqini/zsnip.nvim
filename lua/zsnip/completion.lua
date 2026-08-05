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

---How much of `run` the trigger cannot account for.
---
---A trigger can be the whole run (`console.log`, `<div`) or only its tail:
---`req` typed as `(req` is the run, but the `(` belongs to the buffer. That
---prefix has to survive, so it is reported here and put back by whoever builds
---the replacement. Case-insensitive, because the menu matches that way too --
---`(REQ` still finds `req`, and the `(` is still not the snippet's.
---
---Nothing left over means the run and the trigger are unrelated (`x` against
---`req`); the answer is then '' and the client's own filter drops the item.
---@param run string
---@param trigger string
---@return string
function M.unmatched(run, trigger)
  for start = math.max(1, #run - #trigger + 1), #run do
    local typed = run:sub(start)
    if trigger:sub(1, #typed):lower() == typed:lower() then
      return run:sub(1, start - 1)
    end
  end
  return ''
end

---What `zsnip.blink`, `zsnip.cmp` and `zsnip.lsp` forward, in one place so that
---a new `zsnip.SourceOpts` field does not have to be re-plumbed through all
---three. The uncapped default belongs to them alone, because an engine that
---filters and ranks the response wants the whole filetype. `max_items` is for
---hand-rolled callers and for `zsnip.complete`, which does not come through
---here: it matches for itself, and nothing downstream trims what it returns.
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

---@param opts? zsnip.CompletionOpts
---@return zsnip.Match[] matches
---@return boolean documented Whether the caller asked for bodies and descriptions
function M.matches(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local filetype = opts.filetype or vim.bo[bufnr].filetype
  local limit = opts.limit or config.options.max_items
  local documented = opts.documentation
  if documented == nil then
    documented = config.options.documentation ~= false
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

  local ranked = opts.prefix ~= nil and opts.prefix ~= ''
  if ranked then
    -- matchfuzzy rejects a non-finite limit, and `math.huge` is what every
    -- caller that wants no cap passes. Omitting the argument is not the same
    -- as passing nil, which reaches Vimscript as v:null and raises E1206.
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
    return description .. '\n\n' .. fenced
  end
  return fenced
end

---@param snippet zsnip.Snippet
---@param text string
---@param filetype string
---@return lsp.CompletionItem
local function item(snippet, text, filetype)
  return {
    label = snippet.prefix,
    kind = Kind.Snippet,
    -- The description rides in `documentation`, not `detail`: clients fence
    -- `detail` as code in the buffer's filetype -- vim.lsp.completion
    -- included -- and the description is prose.
    documentation = {
      kind = 'markdown',
      value = M.document(snippet, text, filetype),
    },
    insertText = text,
    insertTextFormat = Format.Snippet,
  }
end

---@param opts? zsnip.CompletionOpts
---@return lsp.CompletionItem[]
function M.items(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local filetype = opts.filetype or vim.bo[bufnr].filetype
  local matched, documented = M.matches(opts)

  -- Without a textEdit the client picks the replaced span itself, and every
  -- client picks the keyword before the cursor -- which cuts `<div` in half
  -- (the item is never offered, because `<div` does not match the prefix
  -- `div`) and misses `#!` entirely (nothing before the cursor is replaced, so
  -- the trigger is left sitting in front of its own expansion).
  local edit = replacement(opts, bufnr)

  local items = {}
  for index, match in ipairs(matched) do
    local entry = item(match.snippet, match.text, filetype)
    if not documented then
      entry.documentation = nil
    end
    if edit then
      -- The part of the run that is not the trigger's is buffer text inside
      -- the replaced span, so it has to be put back -- and put back as text,
      -- not as snippet syntax.
      local keep = M.unmatched(edit.run, match.snippet.prefix)
      -- `insertText` is kept in step with `newText` rather than left as the
      -- bare body: a client reads one or the other, never both, and the two
      -- disagreeing is how the `(` ends up in the buffer twice.
      entry.insertText = body.literal(keep) .. match.text
      entry.textEdit = { range = edit.range, newText = entry.insertText }
      entry.filterText = keep .. match.snippet.prefix
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
