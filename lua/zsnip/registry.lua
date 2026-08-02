---Which snippets exist for a filetype, and where they came from.
---
---Nothing is read until a filetype is asked for: scanning every package.json
---on the runtimepath and decoding the files it names is too slow to do at
---startup, and most of it is for languages this session will never open.
---A filetype's answer is then cached until the runtimepath changes.

local body = require('zsnip.body')
local config = require('zsnip.config')
local util = require('zsnip.util')

local PARSERS = {
  vscode = require('zsnip.parsers.vscode'),
  snipmate = require('zsnip.parsers.snipmate'),
}

local M = {}

---@class zsnip.RegistryState
---@field loaders table<zsnip.LoaderKind, zsnip.LoaderOpts>
---@field added table<string, zsnip.Snippet[]>
---@field extend table<string, string[]> Inheritance declared through the API or setup()
---@field inherited table<string, string[]> Inheritance declared by `extends` lines in snipmate files
---@field sources table<string, zsnip.Source[]>? Discovered files per language; nil until scanned
---@field parsed table<string, table<string, zsnip.Snippet[]>> Normalized snippets, per file path then language
---@field cache table<string, zsnip.Snippet[]>
---@field scanned_rtp string?
---@field options zsnip.Config The options table `cache` was resolved under
local state

---Drop everything derived from the filesystem. Kept separate from clear() so
---`:ZSnip reload` does not throw away snippets added from a user's config.
function M.invalidate()
  state.sources = nil
  state.parsed = {}
  state.cache = {}
  state.inherited = {}
  state.scanned_rtp = nil
end

---Full reset, including registered loaders and snippets. Used by tests.
function M.clear()
  state = {
    loaders = {},
    added = {},
    extend = {},
    inherited = {},
    sources = nil,
    parsed = {},
    cache = {},
    scanned_rtp = nil,
    options = config.options,
  }
end

M.clear()

---Bodies are normalized once, on the way in, so that the per-keystroke path
---only resolves variables. A body the grammar cannot parse is dropped here
---rather than at accept time, where the completion engine has already deleted
---the typed word and the raised error takes the word with it.
---@param snippets zsnip.Snippet[]
---@param filetype string
---@return zsnip.Snippet[]
local function normalize(snippets, filetype)
  local normalized = {}
  for _, snippet in ipairs(snippets) do
    local raw = snippet.body
    if type(snippet.prefix) == 'string' and snippet.prefix ~= '' then
      if type(raw) == 'function' then
        normalized[#normalized + 1] = vim.tbl_extend('force', snippet, { filetype = filetype })
      elseif type(raw) == 'string' then
        local text = body.editable_final_tabstop(raw)
        if body.expandable(text) then
          normalized[#normalized + 1] =
            vim.tbl_extend('force', snippet, { body = text, filetype = filetype })
        end
      end
    end
  end
  return normalized
end

---@param opts zsnip.LoaderOpts
---@param language string
---@return boolean
local function wanted(opts, language)
  if opts.include and not vim.tbl_contains(opts.include, language) then
    return false
  end
  if opts.exclude and vim.tbl_contains(opts.exclude, language) then
    return false
  end
  return true
end

---@param sources table<string, zsnip.Source[]>
---@param language string
---@param source zsnip.Source
local function record(sources, language, source)
  sources[language] = sources[language] or {}
  table.insert(sources[language], source)
end

---@param sources table<string, zsnip.Source[]>
---@param opts zsnip.LoaderOpts
local function scan_vscode(sources, opts)
  local manifests = vim.api.nvim_get_runtime_file('package.json', true)
  for _, path in ipairs(util.list(opts.paths)) do
    manifests[#manifests + 1] = vim.fs.normalize(path) .. '/package.json'
  end

  for _, manifest in ipairs(manifests) do
    for _, entry in ipairs(PARSERS.vscode.contributions(manifest)) do
      if wanted(opts, entry.language) then
        record(sources, entry.language, { kind = 'vscode', path = entry.path })
      end
    end
  end
end

---snipmate names its files after the filetype, either directly or as a
---directory of them.
---@param sources table<string, zsnip.Source[]>
---@param opts zsnip.LoaderOpts
local function scan_snipmate(sources, opts)
  ---@type { path: string, language: string }[]
  local files = {}
  local function collect(paths, modifier)
    for _, path in ipairs(paths) do
      files[#files + 1] = { path = vim.fs.normalize(path), language = vim.fn.fnamemodify(path, modifier) }
    end
  end

  collect(vim.api.nvim_get_runtime_file('snippets/*.snippets', true), ':t:r')
  collect(vim.api.nvim_get_runtime_file('snippets/*/*.snippets', true), ':h:t')
  for _, dir in ipairs(util.list(opts.paths)) do
    collect(vim.fn.glob(dir .. '/*.snippets', true, true), ':t:r')
    collect(vim.fn.glob(dir .. '/*/*.snippets', true, true), ':h:t')
  end

  for _, file in ipairs(files) do
    if wanted(opts, file.language) then
      record(sources, file.language, { kind = 'snipmate', path = file.path })
    end
  end
end

---The runtimepath is re-read on every lookup rather than watched: a plugin
---loaded on a filetype -- pkl-neovim, say -- joins the runtimepath after we
---may already have cached an answer for that very filetype, and OptionSet
---does not fire for 'runtimepath', so there is nothing to hook. Reading and
---comparing the option costs ~0.1us.
local function ensure_scanned()
  local rtp = vim.o.runtimepath
  if state.sources and state.scanned_rtp == rtp then
    return
  end

  local sources = {}
  if state.loaders.vscode then
    scan_vscode(sources, state.loaders.vscode)
  end
  if state.loaders.snipmate then
    scan_snipmate(sources, state.loaders.snipmate)
  end

  state.sources = sources
  state.scanned_rtp = rtp
  state.parsed = {}
  state.cache = {}
  state.inherited = {}
end

---`extend` and `global_filetype` are resolved into the per-filetype cache, so
---a setup() that lands after the first lookup -- the ordinary case under a
---lazy plugin manager -- has to drop what was resolved under the old options.
---setup() replaces the options table rather than editing it, so identity is
---the whole test, and config stays unaware of who reads it.
local function ensure_current()
  if state.options ~= config.options then
    state.options = config.options
    state.cache = {}
  end
end

---Cached per path **and** language, not per path alone: normalize() stamps the
---language onto every snippet, and one VSCode file routinely covers several --
---friendly-snippets' `global.json` serves six. Keyed on the path alone,
---whichever filetype was opened first stamps its name onto all of them.
---
---The file itself is re-read for each of those languages rather than cached
---too: only ~1 file in 8 serves more than one, so holding every raw decode for
---the session costs far more memory than the handful of re-reads it saves.
---@param source zsnip.Source
---@param language string
---@return zsnip.Snippet[]
local function parse(source, language)
  local per_language = state.parsed[source.path]
  if not per_language then
    per_language = {}
    state.parsed[source.path] = per_language
  elseif per_language[language] then
    return per_language[language]
  end

  local snippets, extends
  if source.kind == 'snipmate' then
    snippets, extends = PARSERS.snipmate.parse(source.path)
  else
    snippets, extends = PARSERS.vscode.parse(source.path), {}
  end

  if #extends > 0 then
    state.inherited[language] = vim.list_extend(state.inherited[language] or {}, extends)
  end

  per_language[language] = normalize(snippets, language)
  return per_language[language]
end

---@param filetype string
---@return string[]
local function parents(filetype)
  local list = {}
  vim.list_extend(list, util.list(config.options.extend and config.options.extend[filetype]))
  vim.list_extend(list, state.extend[filetype] or {})
  -- Read after the files for this filetype have been parsed: an `extends`
  -- line only becomes known once the file carrying it has been read.
  vim.list_extend(list, state.inherited[filetype] or {})
  return list
end

---Every filter accumulates, so a second call adds to the first rather than
---replacing it. Nil stays nil: a call that names no `include` is not a claim
---that every language should now be included.
---@param current string[]?
---@param addition string[]?
---@return string[]?
local function accumulate(current, addition)
  if not current or not addition then
    return current or addition
  end
  local merged, seen = {}, {}
  for _, list in ipairs({ current, addition }) do
    for _, language in ipairs(list) do
      if not seen[language] then
        seen[language] = true
        merged[#merged + 1] = language
      end
    end
  end
  return merged
end

---Turn on a loader. Called by `zsnip.loaders.from_*`; repeated calls merge,
---so a second `lazy_load { paths = ... }` adds to the first rather than
---replacing it -- including its `include` and `exclude`, which would
---otherwise make the languages named by the first call silently vanish.
---@param kind zsnip.LoaderKind
---@param opts? zsnip.LoaderOpts
function M.enable(kind, opts)
  opts = opts or {}
  local current = state.loaders[kind] or {}
  local paths = util.list(current.paths)
  vim.list_extend(paths, util.list(opts.paths))

  state.loaders[kind] = {
    paths = paths,
    include = accumulate(current.include, opts.include),
    exclude = accumulate(current.exclude, opts.exclude),
  }
  M.invalidate()
end

---@param kind zsnip.LoaderKind
---@return boolean
function M.enabled(kind)
  return state.loaders[kind] ~= nil
end

---@param filetype string
---@param snippets zsnip.Snippet[]
function M.add(filetype, snippets)
  state.added[filetype] = state.added[filetype] or {}
  vim.list_extend(state.added[filetype], normalize(snippets, filetype))
  state.cache = {}
end

---@param filetype string
---@param inherits string|string[]
function M.extend(filetype, inherits)
  state.extend[filetype] = state.extend[filetype] or {}
  vim.list_extend(state.extend[filetype], util.list(inherits))
  state.cache = {}
end

---Every snippet available to a filetype: its own, then the ones it inherits
---(depth first, in the order the parents were declared), then the global
---bucket. Snippets registered through |zsnip.add_snippets()| come before
---file-loaded ones for the same filetype, so a config can shadow a pack.
---@param filetype string
---@return zsnip.Snippet[]
function M.get(filetype)
  ensure_current()
  ensure_scanned()
  if state.cache[filetype] then
    return state.cache[filetype]
  end

  local snippets, visited, seen_path = {}, {}, {}

  local function collect(language)
    if visited[language] then
      return
    end
    visited[language] = true

    vim.list_extend(snippets, state.added[language] or {})
    for _, source in ipairs(state.sources[language] or {}) do
      if not seen_path[source.path] then
        seen_path[source.path] = true
        vim.list_extend(snippets, parse(source, language))
      end
    end

    for _, parent in ipairs(parents(language)) do
      collect(parent)
    end
  end

  collect(filetype)
  local global = config.options.global_filetype
  if global then
    collect(global)
  end

  state.cache[filetype] = snippets
  return snippets
end

---Every filetype zsnip knows snippets for, mapped to them. Parses everything
---discovered, so it is an introspection call, not a hot path.
---@return table<string, zsnip.Snippet[]>
function M.available()
  ensure_current()
  ensure_scanned()

  local filetypes = {}
  for language in pairs(state.sources) do
    filetypes[language] = true
  end
  for language in pairs(state.added) do
    filetypes[language] = true
  end

  local available = {}
  for language in pairs(filetypes) do
    available[language] = M.get(language)
  end
  return available
end

return M
