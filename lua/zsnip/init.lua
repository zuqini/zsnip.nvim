---zsnip.nvim -- snippet collections for Neovim's built-in snippet engine.
---
---Neovim ships |vim.snippet|, which expands an LSP snippet body and runs the
---session. What it does not ship is everything around that: finding the
---snippet packages on your runtimepath, reading the two formats they come in,
---deciding which ones a filetype gets, and handing them to a completion menu.
---zsnip is that layer and nothing more -- there is no second snippet engine
---here, and no format of its own to convert to.
---
---```lua
---require('zsnip').setup()
---require('zsnip.loaders.from_vscode').lazy_load()
---require('zsnip.loaders.from_snipmate').lazy_load()
---require('zsnip').start_lsp_server()
---```

local body = require('zsnip.body')
local config = require('zsnip.config')
local registry = require('zsnip.registry')

local M = {}

---Optional: every default works without it. It configures filetype
---inheritance and completion behaviour, and creates the `:ZSnip` command.
---@param opts? zsnip.Config
function M.setup(opts)
  config.setup(opts)
  if config.options.command ~= false then
    require('zsnip.commands').create()
  end
end

---Register snippets from Lua. A `body` may be a function returning one, which
---is called each time the snippet is used -- enough for a body that depends on
---the buffer or the moment, though not for anything reacting to what is typed
---into a tabstop (|vim.snippet| owns the session, and it has no hook for that).
---
---```lua
---require('zsnip').add_snippets('lua', {
---  { prefix = 'req', body = "local ${1:mod} = require '$1'" },
---  { prefix = 'stamp', body = function() return os.date('%Y-%m-%d') end },
---})
---```
---@param filetype string Use the configured `global_filetype` ('all') for every filetype
---@param snippets zsnip.Snippet[]
function M.add_snippets(filetype, snippets)
  registry.add(filetype, snippets)
end

---Give `filetype` everything registered for `inherits` as well.
---@param filetype string
---@param inherits string|string[]
function M.filetype_extend(filetype, inherits)
  registry.extend(filetype, inherits)
end

---The registry hands out the list it caches. Callers of a public
---introspection call sort and filter what they are given, so they get a copy
---of the list -- the snippets in it are still shared, and deliberately: an
---entry from here is what |zsnip.expand_snippet()| expects back.
---@param snippets zsnip.Snippet[]
---@return zsnip.Snippet[]
local function copy(snippets)
  return vim.list_extend({}, snippets)
end

---Every snippet available to a filetype, in shadowing order.
---@param filetype? string Defaults to the current buffer's
---@return zsnip.Snippet[]
function M.get(filetype)
  return copy(registry.get(filetype or vim.bo.filetype))
end

---Every filetype zsnip knows snippets for, mapped to them.
---@return table<string, zsnip.Snippet[]>
function M.available()
  local available = {}
  for filetype, snippets in pairs(registry.available()) do
    available[filetype] = copy(snippets)
  end
  return available
end

---Snippets as LSP completion items, for a hand-rolled completion source.
---@param opts? zsnip.CompletionOpts
---@return lsp.CompletionItem[]
function M.completion_items(opts)
  return require('zsnip.completion').items(opts)
end

---Serve the snippets over an in-process language server, so that any
---completion engine that speaks LSP -- blink.cmp, nvim-cmp,
---|vim.lsp.completion()| -- offers them without a per-engine source.
---@param opts? zsnip.LspOpts
function M.start_lsp_server(opts)
  require('zsnip.lsp').start(opts)
end

---Resolve the snippet variables Neovim does not know (CURRENT_YEAR, UUID,
---CLIPBOARD, ...) in an arbitrary body.
---@param snippet_body string
---@return string
function M.resolve(snippet_body)
  return body.resolve(snippet_body)
end

---Forget everything read from disk; the next lookup rescans. Snippets added
---through |zsnip.add_snippets()| survive.
function M.reload()
  registry.invalidate()
end

---The snippet whose trigger ends at the cursor, longest trigger first. A
---trigger that starts with a keyword character has to start a word, so `x`
---does not fire in the middle of `max`.
---@return zsnip.Snippet?
function M.match()
  local before = vim.api.nvim_get_current_line():sub(1, vim.api.nvim_win_get_cursor(0)[2])

  local matched = nil
  for _, snippet in ipairs(registry.get(vim.bo.filetype)) do
    if vim.endswith(before, snippet.prefix) and (not matched or #snippet.prefix > #matched.prefix) then
      local preceding = before:sub(#before - #snippet.prefix, #before - #snippet.prefix)
      if not (snippet.prefix:match('^[%w_]') and preceding:match('[%w_]')) then
        matched = snippet
      end
    end
  end
  return matched
end

---@return boolean
function M.expandable()
  return M.match() ~= nil
end

---Replace the trigger before the cursor with its snippet.
---@return boolean expanded
function M.expand()
  local snippet = M.match()
  if not snippet then
    return false
  end

  local text = body.text(snippet)
  if not text then
    return false
  end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  vim.api.nvim_buf_set_text(0, row - 1, col - #snippet.prefix, row - 1, col, {})
  vim.snippet.expand(text)
  return true
end

---Expand a snippet at the cursor, trigger or not.
---@param snippet zsnip.Snippet
---@return boolean expanded
function M.expand_snippet(snippet)
  local text = body.text(snippet)
  if not text then
    return false
  end
  vim.snippet.expand(text)
  return true
end

---@param direction -1|1
---@return boolean
function M.jumpable(direction)
  return vim.snippet.active({ direction = direction })
end

---@param direction -1|1
---@return boolean jumped
function M.jump(direction)
  if not M.jumpable(direction) then
    return false
  end
  vim.snippet.jump(direction)
  return true
end

---The one binding most configs want: expand what is under the cursor,
---otherwise move to the next tabstop.
---
---```lua
---vim.keymap.set({ 'i', 's' }, '<C-k>', function() require('zsnip').expand_or_jump() end)
---```
---@return boolean handled
function M.expand_or_jump()
  return M.expand() or M.jump(1)
end

---@param filter? vim.snippet.ActiveFilter
---@return boolean
function M.active(filter)
  return vim.snippet.active(filter)
end

---End the active session.
function M.stop()
  vim.snippet.stop()
end

return M
