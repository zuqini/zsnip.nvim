---VSCode snippet packages: a `package.json` naming which languages each
---snippet file covers, and JSON files of `name -> { prefix, body }`.
---rafamadriz/friendly-snippets and everything shaped like it.

local util = require('zsnip.util')

local M = {}

---Snippet files declared by one `package.json`.
---
---Every plugin's `package.json` is read, not just snippet packs, so nothing
---about the shape can be assumed: `"snippets": "x"` would raise out of
---ipairs() and take the caller with it.
---@param manifest string Path to a package.json
---@return { path: string, language: string }[]
function M.contributions(manifest)
  local root = vim.fs.dirname(manifest)
  local declared = vim.tbl_get(util.read_json(manifest) or {}, 'contributes', 'snippets')

  local entries = {}
  for _, entry in ipairs(vim.islist(declared) and declared or {}) do
    if type(entry) == 'table' and type(entry.path) == 'string' then
      local languages = type(entry.language) == 'table' and entry.language or { entry.language }
      for _, language in ipairs(languages) do
        if type(language) == 'string' then
          entries[#entries + 1] = {
            path = vim.fs.normalize(root .. '/' .. entry.path),
            language = language,
          }
        end
      end
    end
  end
  return entries
end

---@param path string
---@return zsnip.Snippet[]
function M.parse(path)
  local snippets = {}
  for name, def in pairs(util.read_json(path) or {}) do
    -- Every value is someone else's JSON: a non-table entry would raise from
    -- inside whatever asked for this filetype's snippets.
    if type(def) == 'table' then
      local body = util.joined(def.body)
      -- A prefix list means several triggers expand the same body.
      local prefixes = type(def.prefix) == 'table' and def.prefix or { def.prefix or name }
      if body then
        for _, prefix in ipairs(prefixes) do
          if type(prefix) == 'string' then
            snippets[#snippets + 1] = {
              prefix = prefix,
              body = body,
              description = util.joined(def.description),
            }
          end
        end
      end
    end
  end

  -- pairs() over a JSON object has no order of its own; sort so the same pack
  -- produces the same menu on every start.
  table.sort(snippets, function(a, b)
    return a.prefix < b.prefix
  end)
  return snippets
end

return M
