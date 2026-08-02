---Snippets as LSP completion items.
---
---The bodies are already LSP snippet syntax, so `insertTextFormat` is all a
---client needs to expand them -- there is nothing to translate. Used by
---|zsnip.completion_items()| and by the in-process server in `zsnip.lsp`.

local body = require('zsnip.body')
local config = require('zsnip.config')
local registry = require('zsnip.registry')

local Kind = vim.lsp.protocol.CompletionItemKind
local Format = vim.lsp.protocol.InsertTextFormat

local M = {}

---@param snippet zsnip.Snippet
---@param text string
---@param filetype string
---@return lsp.CompletionItem
local function item(snippet, text, filetype)
  return {
    label = snippet.prefix,
    kind = Kind.Snippet,
    detail = snippet.description,
    documentation = {
      kind = 'markdown',
      value = ('```%s\n%s\n```'):format(filetype, text),
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

  if opts.prefix and opts.prefix ~= '' then
    triggers = vim.fn.matchfuzzy(triggers, opts.prefix, { limit = limit })
  end

  local items = {}
  for _, trigger in ipairs(triggers) do
    if #items >= limit then
      break
    end
    local snippet = by_prefix[trigger]
    local text = body.text(snippet)
    if text then
      local entry = item(snippet, text, filetype)
      if not documented then
        entry.detail, entry.documentation = nil, nil
      end
      -- Matches are already in relevance order; sortText keeps a client from
      -- re-sorting them alphabetically.
      entry.sortText = ('%04d'):format(#items)
      items[#items + 1] = entry
    end
  end
  return items
end

return M
