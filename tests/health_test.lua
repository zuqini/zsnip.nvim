local helpers = require('helpers')
local health = require('zsnip.health')
local registry = require('zsnip.registry')

before_each(helpers.reset)
after_each(helpers.cleanup)

---Run :checkhealth's entry point against a recording stub, so a rename in the
---registry or a change in the vim.health API surfaces here rather than in a
---user's health output.
---@return table<string, string[]> by_level
local function check()
  local real = vim.health
  local collected = { start = {}, ok = {}, warn = {}, error = {}, info = {} }
  local stub = {}
  for level in pairs(collected) do
    stub[level] = function(message, extra)
      collected[level][#collected[level] + 1] = tostring(message)
      if extra then
        for _, line in ipairs(extra) do
          collected[level][#collected[level] + 1] = tostring(line)
        end
      end
    end
  end

  ---@diagnostic disable-next-line: assign-type-mismatch
  vim.health = stub
  local ok, err = pcall(health.check)
  vim.health = real
  assert(ok, err)

  return collected
end

---@param messages string[]
---@param pattern string
---@return boolean
local function mentions(messages, pattern)
  for _, message in ipairs(messages) do
    if message:match(pattern) then
      return true
    end
  end
  return false
end

describe(':checkhealth zsnip', function()
  it('runs every section', function()
    local report = check()
    assert.are.same(
      { 'Environment', 'Loaders', 'Snippets', 'Completion sources', 'Reporting a bug' },
      report.start
    )
  end)

  it('confirms the environment it needs', function()
    local report = check()
    assert.is_true(mentions(report.ok, 'vim%.snippet is available'))
    assert.are.same({}, report.error)
  end)

  it('warns when no loader is registered', function()
    local report = check()
    assert.is_true(mentions(report.warn, 'No loader registered'))
  end)

  it('names the loaders that are', function()
    require('zsnip.loaders.from_vscode').lazy_load()
    require('zsnip.loaders.from_snipmate').lazy_load()

    assert.is_true(mentions(check().ok, 'loaders: vscode, snipmate'))
  end)

  it('warns when nothing was found', function()
    require('zsnip.loaders.from_vscode').lazy_load({ paths = helpers.tempdir() })
    assert.is_true(mentions(check().warn, 'No snippets found'))
  end)

  it('counts what was found', function()
    registry.add('lua', { { prefix = 'a', body = 'b' }, { prefix = 'c', body = 'b' } })
    assert.is_true(mentions(check().ok, '2 snippet%(s%) across 1 filetype%(s%)'))
  end)

  -- Which of the three mutually exclusive delivery paths is running is the
  -- other half of "why do I see no snippets", and nothing else reports it.
  it('says whether the LSP server is serving them', function()
    assert.is_true(mentions(check().info, 'LSP server not started'))

    require('zsnip.lsp').start()
    assert.is_true(mentions(check().ok, 'LSP server started'))

    helpers.stop_lsp()
  end)
end)
