---:checkhealth zsnip — diagnostics for a zsnip setup.
---
---Answers the three questions a broken snippet setup raises: is the engine
---there, did any snippets actually get found, and is anything serving them.
---Discovered automatically by `:checkhealth zsnip` — nothing registers it.

local registry = require('zsnip.registry')

local M = {}

local ISSUES_URL = 'https://github.com/zuqini/zsnip.nvim/issues'

local MINIMAL_CONFIG = table.concat({
  "require('zsnip').setup()",
  "require('zsnip.loaders.from_vscode').lazy_load()",
  "require('zsnip.loaders.from_snipmate').lazy_load()",
}, '\n')

---:checkhealth runs every check from inside its own freshly created,
---filetype-less buffer, so the buffer the user actually had open is the
---alternate one.
---@return integer?
local function came_from()
  local altbuf = vim.fn.bufnr('#')
  return altbuf ~= -1 and vim.api.nvim_buf_is_valid(altbuf) and altbuf or nil
end

local function check_environment()
  vim.health.start('Environment')

  vim.health.info('zsnip ' .. require('zsnip').version)

  if vim.fn.has('nvim-0.13') == 1 then
    vim.health.ok('Neovim ' .. tostring(vim.version()) .. ' (>= 0.13.0 required)')
  else
    vim.health.error('Neovim 0.13.0+ is required (nightly, until 0.13 releases)')
  end

  if type(vim.snippet) == 'table' and type(vim.snippet.expand) == 'function' then
    vim.health.ok('vim.snippet is available')
  else
    vim.health.error('vim.snippet is not available — zsnip is a layer over it')
  end

  if require('zsnip.body').validates then
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
  for _, kind in ipairs(registry.kinds()) do
    local opts = registry.loader(kind)
    if opts then
      enabled[#enabled + 1] = { kind = kind, opts = opts }
    end
  end

  if #enabled == 0 then
    vim.health.warn('No loader registered — zsnip will find nothing on the runtimepath', {
      'Enable the formats you use:',
      MINIMAL_CONFIG,
    })
    return
  end

  for _, loader in ipairs(enabled) do
    vim.health.ok('loader: ' .. loader.kind)
    -- A path that does not exist finds nothing and says nothing, and a typo in
    -- one looks exactly like the loader not working.
    for _, path in ipairs(loader.opts.paths) do
      if vim.fn.isdirectory(path) == 1 then
        vim.health.info(('  path: %s'):format(path))
      else
        vim.health.warn(('  path does not exist: %s'):format(path))
      end
    end
  end
end

local function check_snippets()
  vim.health.start('Snippets')

  local available = registry.available()
  local filetypes, total = 0, 0
  for _, snippets in pairs(available) do
    filetypes = filetypes + 1
    total = total + #snippets
  end

  -- The other half of "my snippet is missing": it was found and then dropped.
  -- Read after available(), which is what forces parse() to fill
  -- dropped_parsed -- read any earlier and every file-derived drop counts as
  -- 0, and a total of 0 gets blamed on the runtimepath instead.
  local dropped = registry.dropped()

  if total == 0 then
    if dropped > 0 then
      vim.health.warn(('%d body/bodies found and dropped, 0 kept'):format(dropped), {
        'vim.snippet.expand() would not take them. Check the bodies themselves,',
        'not the runtimepath.',
      })
    else
      vim.health.warn('No snippets found', {
        'Check that a snippet package is installed and on the runtimepath,',
        'e.g. rafamadriz/friendly-snippets, and that its loader is registered.',
      })
    end
    return
  end

  vim.health.ok(('%d snippet(s) across %d filetype(s)'):format(total, filetypes))

  local altbuf = came_from()
  local filetype = altbuf and vim.bo[altbuf].filetype or ''
  if filetype ~= '' then
    vim.health.info(
      ('filetype of the buffer you came from (%s): %d snippet(s)'):format(filetype, #registry.get(filetype))
    )
  end

  if dropped > 0 then
    vim.health.info(('%d body/bodies dropped — vim.snippet.expand() will not take them'):format(dropped))
  end
end

---A found snippet still has to reach a menu, and the four ways of arranging
---that are mutually exclusive. Which one is running is the other half of "why
---do I see no snippets".
---
---Only two of them can be answered from here: a blink or nvim-cmp source is
---registered inside an engine that need not even be loaded when this runs, so
---their absence is never reported as a fault.
local function check_sources()
  vim.health.start('Completion sources')

  local lsp = require('zsnip.lsp')
  local serving = {}
  if lsp.started() and lsp.running() then
    serving[#serving + 1] = 'the in-process LSP server'
  end
  if require('zsnip.complete').enabled(came_from()) then
    serving[#serving + 1] = "zsnip.complete, through 'complete'"
  end

  if #serving > 1 then
    vim.health.warn('Two sources are serving: ' .. table.concat(serving, ' and '), {
      'Every snippet is offered twice. Pick one.',
    })
    return
  end

  if #serving == 1 then
    vim.health.ok('serving: ' .. serving[1])
    return
  end

  if lsp.started() then
    vim.health.warn('LSP server started, but no client is running', {
      'Either every buffer opened so far was excluded by the `filetypes`',
      'option, or the client was stopped.',
    })
    return
  end

  vim.health.info(table.concat({
    'No source detected. That is correct if you registered a native one',
    '(zsnip.blink or zsnip.cmp) — those live inside a completion engine and',
    'cannot be seen from here. If you registered none of the four, nothing is',
    'serving the snippets. The one that needs no plugin at all:',
    "  require('zsnip.complete').enable()",
  }, '\n'))
end

local function check_bug_report()
  vim.health.start('Reporting a bug')
  vim.health.info(table.concat({
    'Reproduce with a minimal config, then open an issue at',
    ISSUES_URL .. ' including:',
    '  - the minimal config below (edited to trigger the bug)',
    '  - the full :checkhealth zsnip output (it carries both versions)',
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
  check_sources()
  check_bug_report()
end

return M
