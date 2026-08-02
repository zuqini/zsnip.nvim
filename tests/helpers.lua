---Shared test scaffolding: throwaway snippet packages on a throwaway
---runtimepath, plus the `assert.contains` assertion.

local luassert = require('luassert')
local say = require('say')

local M = {}

-- `assert.contains(tbl, value)` — a list-membership assertion luassert has no
-- built-in for. Registered as a real luassert assertion (rather than a bare
-- helper that raises via error()) so a failed containment check is classified
-- by busted as a 'failure', not an 'error', like every other assertion.
local function table_contains(_, arguments)
  local tbl = arguments[1]
  if type(tbl) ~= 'table' then
    return false
  end
  for _, v in ipairs(tbl) do
    if v == arguments[2] then
      return true
    end
  end
  return false
end

say:set('assertion.contains.positive', 'Expected table to contain value.\nTable:\n%s\nValue:\n%s')
say:set('assertion.contains.negative', 'Expected table to not contain value.\nTable:\n%s\nValue:\n%s')
luassert:register('assertion', 'contains', table_contains,
  'assertion.contains.positive', 'assertion.contains.negative')

---@type string[]
local tempdirs = {}
---@type string?
local saved_rtp = nil

---@return string
function M.tempdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  tempdirs[#tempdirs + 1] = dir
  return dir
end

---@param path string
---@param contents string
function M.write(path, contents)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(vim.split(contents, '\n'), path)
end

---A VSCode snippet package: a package.json contributing `files`, keyed by
---language, to the file that carries them.
---@param files table<string, table<string, table>> language -> snippet definitions
---@return string dir
function M.vscode_pack(files)
  local dir = M.tempdir()
  local contributes = {}
  for language, definitions in pairs(files) do
    local name = ('snippets/%s.json'):format(language)
    M.write(dir .. '/' .. name, vim.json.encode(definitions))
    contributes[#contributes + 1] = { language = language, path = './' .. name }
  end
  M.write(dir .. '/package.json', vim.json.encode({ contributes = { snippets = contributes } }))
  return dir
end

---A VSCode package contributing one file to several languages at once, the
---shape friendly-snippets uses for its shared packs (`global.json` covers six).
---@param languages string[]
---@param definitions table<string, table>
---@return string dir
function M.vscode_shared_pack(languages, definitions)
  local dir = M.tempdir()
  M.write(dir .. '/snippets/shared.json', vim.json.encode(definitions))
  M.write(
    dir .. '/package.json',
    vim.json.encode({
      contributes = { snippets = { { language = languages, path = './snippets/shared.json' } } },
    })
  )
  return dir
end

---A package whose snippet file is valid JSON but holds values a pack is not
---supposed to hold. Written as raw text: vim.json.encode cannot produce a
---null inside an array.
---@param language string
---@param json string
---@return string dir
function M.vscode_raw_pack(language, json)
  local dir = M.tempdir()
  local name = ('snippets/%s.json'):format(language)
  M.write(dir .. '/' .. name, json)
  M.write(
    dir .. '/package.json',
    vim.json.encode({
      contributes = { snippets = { { language = language, path = './' .. name } } },
    })
  )
  return dir
end

---A snipmate directory: `snippets/<filetype>.snippets` per entry.
---@param files table<string, string> filetype -> file contents
---@return string dir
function M.snipmate_pack(files)
  local dir = M.tempdir()
  for filetype, contents in pairs(files) do
    M.write(('%s/snippets/%s.snippets'):format(dir, filetype), contents)
  end
  return dir
end

---Put directories at the front of the runtimepath for the rest of the test.
---Repeated calls stack, so a test can stage a plugin joining the runtimepath
---after the first lookup.
---@param ... string
function M.use_rtp(...)
  saved_rtp = saved_rtp or vim.o.runtimepath
  vim.o.runtimepath = table.concat({ ... }, ',') .. ',' .. vim.o.runtimepath
end

---Fresh registry and config; call from before_each.
function M.reset()
  require('zsnip.registry').clear()
  require('zsnip.config').reset()
end

---Stop the in-process server and forget it was ever started.
---
---Waiting for the client to actually go is the point: vim.lsp.start() reuses a
---client by name, so a still-stopping one from an earlier test is handed back
---to the next and never attaches to anything.
function M.stop_lsp()
  for _, client in ipairs(vim.lsp.get_clients()) do
    if vim.startswith(client.name, 'zsnip') then
      client:stop(true)
    end
  end
  vim.wait(2000, function()
    return #vim.lsp.get_clients() == 0
  end)
  pcall(vim.api.nvim_del_augroup_by_name, 'zsnip.lsp')
end

---Undo runtimepath changes and delete every temp directory; call from
---after_each so a failing assertion cannot leak state into the next test.
function M.cleanup()
  if saved_rtp then
    vim.o.runtimepath = saved_rtp
    saved_rtp = nil
  end
  for _, dir in ipairs(tempdirs) do
    vim.fn.delete(dir, 'rf')
  end
  tempdirs = {}
  M.reset()
end

---@param snippets zsnip.Snippet[]
---@return string[]
function M.prefixes(snippets)
  return vim.tbl_map(function(snippet)
    return snippet.prefix
  end, snippets)
end

---@param snippets zsnip.Snippet[]
---@param prefix string
---@return zsnip.Snippet?
function M.find(snippets, prefix)
  for _, snippet in ipairs(snippets) do
    if snippet.prefix == prefix then
      return snippet
    end
  end
  return nil
end

return M
