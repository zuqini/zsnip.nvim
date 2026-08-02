---:checkhealth zsnip — diagnostics for a zsnip setup.
---
---Answers the two questions a broken snippet setup raises: is the engine
---there, and did any snippets actually get found. Discovered automatically by
---`:checkhealth zsnip` — nothing registers it.

local registry = require('zsnip.registry')

local M = {}

local ISSUES_URL = 'https://github.com/zuqini/ZSnip.nvim/issues'

local MINIMAL_CONFIG = table.concat({
  "require('zsnip').setup()",
  "require('zsnip.loaders.from_vscode').lazy_load()",
  "require('zsnip.loaders.from_snipmate').lazy_load()",
}, '\n')

local function check_environment()
  vim.health.start('Environment')

  if vim.fn.has('nvim-0.11') == 1 then
    vim.health.ok('Neovim ' .. tostring(vim.version()) .. ' (>= 0.11.0 required)')
  else
    vim.health.error('Neovim 0.11.0+ is required')
  end

  if type(vim.snippet) == 'table' and type(vim.snippet.expand) == 'function' then
    vim.health.ok('vim.snippet is available')
  else
    vim.health.error('vim.snippet is not available — zsnip is a layer over it')
  end

  if pcall(require, 'vim.lsp._snippet_grammar') then
    vim.health.ok('snippet grammar is available (unparseable bodies are dropped on load)')
  else
    vim.health.warn('vim.lsp._snippet_grammar is missing — bodies cannot be validated on load', {
      'A malformed body will raise from vim.snippet.expand() at accept time instead.',
    })
  end
end

local function check_loaders()
  vim.health.start('Loaders')

  local enabled = {}
  for _, kind in ipairs({ 'vscode', 'snipmate' }) do
    if registry.enabled(kind) then
      enabled[#enabled + 1] = kind
    end
  end

  if #enabled == 0 then
    vim.health.warn('No loader registered — zsnip will find nothing on the runtimepath', {
      'Enable the formats you use:',
      MINIMAL_CONFIG,
    })
    return
  end
  vim.health.ok('loaders: ' .. table.concat(enabled, ', '))
end

local function check_snippets()
  vim.health.start('Snippets')

  local available = registry.available()
  local filetypes, total = 0, 0
  for _, snippets in pairs(available) do
    filetypes = filetypes + 1
    total = total + #snippets
  end

  if total == 0 then
    vim.health.warn('No snippets found', {
      'Check that a snippet package is installed and on the runtimepath,',
      'e.g. rafamadriz/friendly-snippets, and that its loader is registered.',
    })
    return
  end

  vim.health.ok(('%d snippet(s) across %d filetype(s)'):format(total, filetypes))

  local filetype = vim.bo.filetype
  if filetype ~= '' then
    vim.health.info(('current filetype (%s): %d snippet(s)'):format(filetype, #registry.get(filetype)))
  end
end

local function check_bug_report()
  vim.health.start('Reporting a bug')
  vim.health.info(table.concat({
    'Reproduce with a minimal config, then open an issue at',
    ISSUES_URL .. ' including:',
    '  - the minimal config below (edited to trigger the bug)',
    '  - the full :checkhealth zsnip output',
    '  - your Neovim version (nvim --version)',
    '',
    'Minimal config — save as repro.lua, run with: nvim -u repro.lua',
    '',
    MINIMAL_CONFIG,
  }, '\n'))
end

---Entry point for `:checkhealth zsnip`.
function M.check()
  check_environment()
  check_loaders()
  check_snippets()
  check_bug_report()
end

return M
