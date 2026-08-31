---Which snippets exist for a filetype, and where they came from.
---
---Nothing is read until a filetype is asked for: scanning every package.json
---on the runtimepath and decoding the files it names is too slow to do at
---startup, and most of it is for languages this session will never open.
---A filetype's answer is then cached until the runtimepath changes.

local body = require('zsnip.body')
local config = require('zsnip.config')
local util = require('zsnip.util')
local vscode_parser = require('zsnip.parsers.vscode')
local snipmate_parser = require('zsnip.parsers.snipmate')

local M = {}

---@param value string|string[]|nil
---@return string[]
local function as_list(value)
  if type(value) == 'table' then
    return value
  elseif value ~= nil then
    return { value }
  end
  return {}
end

---@class zsnip.RegistryState
---@field loaders table<zsnip.LoaderKind, zsnip.Loader>
---@field added table<string, zsnip.Snippet[]>
---@field extend table<string, string[]> Inheritance declared through the API or setup()
---@field inherited table<string, string[]> Inheritance declared by `extends` lines in snipmate files
---@field sources table<string, zsnip.Source[]>? Discovered files per language; nil until scanned
---@field parsed table<string, table<string, zsnip.Snippet[]>> Normalized snippets, per file path then language
---@field cache table<string, zsnip.Snippet[]>
---@field scanned_rtp string?
---@field dropped_parsed table<string, true> definition_key()s of bodies read from disk that |vim.snippet.expand()| would not take
---@field dropped_added integer The same, for snippets registered through the API -- which a rescan does not re-read
---@field options zsnip.ResolvedConfig The options table `cache` was resolved under
local state

---Drop everything derived from the filesystem. Kept separate from clear() so
---`:ZSnip reload` does not throw away snippets added from a user's config.
---
---The one definition of what "derived" means: the two callers below re-derive
---parts of it, and a field that is added here but missed there is a stale
---answer nothing invalidates.
function M.invalidate()
  state.sources = nil
  state.parsed = {}
  state.cache = {}
  state.inherited = {}
  state.scanned_rtp = nil
  state.dropped_parsed = {}
end

---Full reset, including registered loaders and snippets. Used by tests.
function M.clear()
  -- Everything derived is left to invalidate() below rather than listed twice.
  ---@diagnostic disable-next-line: missing-fields
  state = {
    loaders = {},
    added = {},
    extend = {},
    dropped_added = 0,
    options = config.options,
  }
  M.invalidate()
end

M.clear()

---Bodies are normalized once, on the way in, so that the per-keystroke path
---only resolves variables. A body the grammar cannot parse is dropped here
---rather than at accept time, where the completion engine has already deleted
---the typed word and the raised error takes the word with it.
---@param snippets zsnip.Snippet[]
---@param filetype string
---@return zsnip.Snippet[] normalized
---@return zsnip.Snippet[] dropped Snippets whose (unparsed) body vim.snippet.expand() would not take
local function normalize(snippets, filetype)
  local normalized, dropped = {}, {}
  for _, snippet in ipairs(snippets) do
    local raw = snippet.body
    if type(snippet.prefix) == 'string' and snippet.prefix ~= '' then
      if type(raw) == 'function' then
        -- A function body is normalized when it produces one; there is
        -- nothing to check here yet. See `body.text()`.
        normalized[#normalized + 1] = vim.tbl_extend('force', snippet, { filetype = filetype })
      elseif type(raw) == 'string' then
        local text = body.normalize(raw)
        if text then
          normalized[#normalized + 1] =
            vim.tbl_extend('force', snippet, { body = text, filetype = filetype })
        else
          -- Handed back rather than reported: this runs from inside a
          -- completion request, where a message per malformed body in someone
          -- else's pack would be unusable. `:checkhealth zsnip` reads dropped().
          dropped[#dropped + 1] = snippet
        end
      end
    end
  end
  return normalized, dropped
end

---@param opts zsnip.Loader
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

---What a pack calls the bucket that means "every filetype": vscode has no
---name of its own for it and spells it out as the language `all`, in a
---manifest's `language` list or a `.code-snippets` entry's `scope`;
---snipmate's convention is a file named `_`, which honza/vim-snippets ships
---one of. Both are filed under `global_filetype` instead, or dropped when
---the bucket is disabled.
---@type table<zsnip.LoaderKind, string?>
local EVERYWHERE = { vscode = 'all', snipmate = '_' }

---@param kind zsnip.LoaderKind
---@param language string A pack's own spelling of a filetype
---@return string|false
local function global_alias(kind, language)
  if language == EVERYWHERE[kind] then
    return config.options.global_filetype
  end
  return language
end

---Snippet files sitting loose in a directory, the way VSCode keeps a user's
---own: `<language>.json` named after the filetype it serves, and
---`*.code-snippets` whose snippets name their languages individually. Only
---looked for under a configured `paths` -- a plugin on the runtimepath
---declares what it contributes in a package.json, and globbing every plugin's
---directory for stray JSON would find a great deal that is not a snippet.
---@param sources table<string, zsnip.Source[]>
---@param opts zsnip.Loader
---@param dir string
---@param claimed table<string, true> Paths a package.json already spoke for
local function scan_standalone(sources, opts, dir, claimed)
  ---@param language string
  ---@param path string
  ---@param filter? string The pack's own spelling of the language to hand
  --- the parser, when this record's language came from the file's own
  --- `scope` -- see zsnip.Source.scope. A `<language>.json` file's language
  --- is its filename, not a scope, and passes nothing.
  local function keep(language, path, filter)
    local bucket = global_alias('vscode', language)
    if bucket and wanted(opts, bucket) then
      record(sources, bucket, { kind = 'vscode', path = path, scope = filter })
    end
  end

  for _, file in ipairs(util.files(dir, '.json', 1)) do
    if file.base ~= 'package' and not claimed[file.path] then
      keep(file.base, file.path)
    end
  end

  for _, file in ipairs(util.files(dir, '.code-snippets', 1)) do
    local path = file.path
    if not claimed[path] then
      local languages, unscoped = vscode_parser.scopes(path)
      for _, language in ipairs(languages) do
        keep(language, path, language)
      end
      -- An unscoped snippet applies to every language, which is what the
      -- global bucket already means here.
      local global = config.options.global_filetype
      if unscoped and global then
        keep(global, path, EVERYWHERE.vscode)
      end
    end
  end
end

---@param sources table<string, zsnip.Source[]>
---@param opts zsnip.Loader
local function scan_vscode(sources, opts)
  local manifests = vim.api.nvim_get_runtime_file('package.json', true)
  for _, path in ipairs(opts.paths) do
    manifests[#manifests + 1] = path .. '/package.json'
  end

  local claimed = {}
  for _, manifest in ipairs(manifests) do
    for _, entry in ipairs(vscode_parser.contributions(manifest)) do
      claimed[entry.path] = true
      local language = global_alias('vscode', entry.language)
      if language and wanted(opts, language) then
        record(sources, language, { kind = 'vscode', path = entry.path })
      end
    end
  end

  for _, dir in ipairs(opts.paths) do
    scan_standalone(sources, opts, dir, claimed)
  end
end

---snipmate names its files after the filetype, either directly or as a
---directory of them.
---@param sources table<string, zsnip.Source[]>
---@param opts zsnip.Loader
local function scan_snipmate(sources, opts)
  ---@type { path: string, language: string }[]
  local found = {}
  local function collect(paths, modifier)
    for _, path in ipairs(paths) do
      found[#found + 1] = { path = vim.fs.normalize(path), language = vim.fn.fnamemodify(path, modifier) }
    end
  end

  collect(vim.api.nvim_get_runtime_file('snippets/*.snippets', true), ':t:r')
  collect(vim.api.nvim_get_runtime_file('snippets/*/*.snippets', true), ':h:t')
  for _, dir in ipairs(opts.paths) do
    -- A directory of them is named after the filetype it serves; a loose file
    -- is named after it directly.
    for _, file in ipairs(util.files(dir, '.snippets', 2)) do
      found[#found + 1] = { path = file.path, language = file.parent or file.base }
    end
  end

  for _, file in ipairs(found) do
    local language = global_alias('snipmate', file.language)
    if language and wanted(opts, language) then
      record(sources, language, { kind = 'snipmate', path = file.path })
    end
  end
end

-- Order is load-bearing: it is the order ensure_scanned() below scans in, and
-- health.lua reports loaders in the same order.
local FORMATS = {
  { kind = 'vscode', parser = vscode_parser, scan = scan_vscode },
  { kind = 'snipmate', parser = snipmate_parser, scan = scan_snipmate },
}

local by_kind = {}
for _, format in ipairs(FORMATS) do
  by_kind[format.kind] = format
end

---Every loader kind zsnip knows how to scan, in the order ensure_scanned()
---below scans them. `health.lua` iterates this rather than naming the two
---again.
---@return zsnip.LoaderKind[]
function M.kinds()
  local kinds = {}
  for i, format in ipairs(FORMATS) do
    kinds[i] = format.kind
  end
  return kinds
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
  for _, format in ipairs(FORMATS) do
    if state.loaders[format.kind] then
      format.scan(sources, state.loaders[format.kind])
    end
  end

  M.invalidate()
  state.sources = sources
  state.scanned_rtp = rtp
end

---`extend` and `global_filetype` are resolved into the per-filetype cache, so
---a setup() that lands after the first lookup -- the ordinary case under a
---lazy plugin manager -- has to drop what was resolved under the old options.
---setup() replaces the options table rather than editing it, so identity is
---the whole test, and config stays unaware of who reads it.
local function ensure_current()
  if state.options ~= config.options then
    state.options = config.options
    -- Discovery reads `global_filetype` too, to decide which bucket an
    -- unscoped `.code-snippets` entry belongs to, so what was found under the
    -- old options has to go with what was resolved from it -- which is
    -- everything invalidate() drops.
    M.invalidate()
  end
end

---Identity of a definition a file yields, not of the (file, bucket) pair
---that asked for it: a manifest naming `["markdown", "all"]`, a `scope:
---"lua, all"` entry, or an unscoped entry in a mixed `.code-snippets` reaches
---parse() once per bucket but is one definition. get() serves it once per
---filetype and dropped() counts it once on that key. `add()`-registered
---snippets have no source and are served as registered -- a caller adding
---the same body twice asked for it.
---@param source zsnip.Source
---@param snippet zsnip.Snippet
---@return string
local function definition_key(source, snippet)
  return source.path .. '\0' .. snippet.prefix .. '\0' .. tostring(snippet.body)
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

  -- source.scope carries the pack's own spelling of the language, recorded
  -- only when it came from this file's own `scope`: a `.code-snippets` file,
  -- which is one file serving several, then hands back only what is in
  -- scope for this one. A manifest- or filename-derived source has no
  -- `scope` and must not filter by it -- see docs/api.md. snipmate has no
  -- `scope` and ignores the parameter either way.
  local snippets, extends = by_kind[source.kind].parser.parse(source.path, source.scope)

  if #extends > 0 then
    state.inherited[language] = vim.list_extend(state.inherited[language] or {}, extends)
  end

  local normalized, dropped = normalize(snippets, language)
  for _, snippet in ipairs(dropped) do
    state.dropped_parsed[definition_key(source, snippet)] = true
  end
  per_language[language] = normalized
  return normalized
end

---`filetype` itself, then its dot-separated components. The exact name is
---not one of its own components -- `yaml.ansible` splits into `yaml` and
---`ansible` -- so it has to be listed outright, and it comes first.
---@param filetype string
---@return string[]
function M.components(filetype)
  local list = { filetype }
  if filetype:find('.', 1, true) then
    vim.list_extend(list, vim.split(filetype, '.', { plain = true }))
  end
  return list
end

---@param filetype string
---@return string[]
local function parents(filetype)
  local list = {}
  vim.list_extend(list, as_list(config.options.extend[filetype]))
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

---Fold a possibly-scalar `include`/`exclude` into what a loader already has.
---Nil stays nil rather than passing through as_list(): a nil `include` means
---no filter, but as_list(nil) is `{}`, which would mean "reject everything".
---@param current string[]|nil
---@param addition string|string[]|nil
---@return string[]|nil
local function merge_filter(current, addition)
  if addition == nil then
    return current
  end
  return accumulate(current, as_list(addition))
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

  -- Normalized before the dedupe accumulate() does: `~/x` and its expansion
  -- are the same path, but not the same string, and :checkhealth would
  -- otherwise list both.
  local paths = vim.tbl_map(vim.fs.normalize, as_list(opts.paths))

  state.loaders[kind] = {
    -- Both sides are always a list, never nil, so accumulate() cannot really
    -- hand back nil here; the `or {}` is only to satisfy that its signature
    -- says it might.
    paths = accumulate(as_list(current.paths), paths) or {},
    include = merge_filter(current.include, opts.include),
    exclude = merge_filter(current.exclude, opts.exclude),
  }
  M.invalidate()
end

---The options a loader was registered with, or nil if it never was. The paths
---are the answer to "why does it find nothing", so this hands back what was
---given rather than just whether anything was.
---@param kind zsnip.LoaderKind
---@return zsnip.Loader?
function M.loader(kind)
  return state.loaders[kind]
end

---How many bodies were dropped for being ones |vim.snippet.expand()| would
---not take. The file-derived half resets whenever what was read from disk
---does; what came through |zsnip.add_snippets()| lasts until clear().
---@return integer
function M.dropped()
  return vim.tbl_count(state.dropped_parsed) + state.dropped_added
end

---@param filetype string
---@param snippets zsnip.Snippet[]
function M.add(filetype, snippets)
  local normalized, dropped = normalize(snippets, filetype)
  state.added[filetype] = state.added[filetype] or {}
  vim.list_extend(state.added[filetype], normalized)
  -- Not part of what invalidate() drops: a rescan does not re-read these, so
  -- resetting the count with the parsed one would lose it.
  state.dropped_added = state.dropped_added + #dropped
  state.cache = {}
end

---@param filetype string
---@param inherits string|string[]
function M.extend(filetype, inherits)
  state.extend[filetype] = state.extend[filetype] or {}
  vim.list_extend(state.extend[filetype], as_list(inherits))
  state.cache = {}
end

---Every snippet available to a filetype: its own, then the ones it inherits
---(depth first, in the order the parents were declared), then -- for a dotted
---filetype like `javascript.glimmer` -- each dot-separated component on its
---own, then the global bucket. Snippets registered through
---|zsnip.add_snippets()| come before file-loaded ones for the same filetype,
---so a config can shadow a pack.
---@param filetype string
---@return zsnip.Snippet[]
function M.get(filetype)
  ensure_current()
  ensure_scanned()
  if state.cache[filetype] then
    return state.cache[filetype]
  end

  local snippets, visited, seen_path, seen_definition = {}, {}, {}, {}

  local function collect(language)
    if visited[language] then
      return
    end
    visited[language] = true

    vim.list_extend(snippets, state.added[language] or {})
    for _, source in ipairs(state.sources[language] or {}) do
      -- Per path *and* language, matching `parse()`: one `.code-snippets`
      -- file serves several, and each visit hands back only what is in scope
      -- for the language asked about. Keyed on the path alone, a typescript
      -- buffer that inherits javascript sees the file once -- as typescript --
      -- and the javascript snippets in it are silently gone.
      --
      -- The key leaves out `source.scope`, so where one path was recorded
      -- twice under one bucket the first record decides which entries the
      -- file serves and the second is never parsed. Only `all` is aliased
      -- onto a bucket, so reaching that needs a `.code-snippets` holding
      -- both an `all` entry and one scoped to the literal name a user
      -- renamed `global_filetype` to -- a pack written for one user's
      -- config, which the scope rules decline to serve either way.
      local visit = source.path .. '\0' .. language
      if not seen_path[visit] then
        seen_path[visit] = true
        for _, snippet in ipairs(parse(source, language)) do
          -- First occurrence wins; collection order is own bucket -> parents
          -- -> global, so the stamp a caller sees is the nearest bucket that
          -- actually serves this definition (see definition_key()).
          local key = definition_key(source, snippet)
          if not seen_definition[key] then
            seen_definition[key] = true
            snippets[#snippets + 1] = snippet
          end
        end
      end
    end

    for _, parent in ipairs(parents(language)) do
      collect(parent)
    end
  end

  -- Neovim assigns dotted filetypes itself for some (javascript.glimmer,
  -- typescript.glimmer) and users set others (yaml.ansible). `visited`
  -- already keeps an explicit add('yaml.ansible', ...) from being collected
  -- twice.
  for _, component in ipairs(M.components(filetype)) do
    collect(component)
  end
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
