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

    local report = check()
    assert.is_true(mentions(report.ok, 'loader: vscode'))
    assert.is_true(mentions(report.ok, 'loader: snipmate'))
  end)

  it('warns when nothing was found', function()
    require('zsnip.loaders.from_vscode').lazy_load({ paths = helpers.tempdir() })
    assert.is_true(mentions(check().warn, 'No snippets found'))
  end)

  it('names dropped bodies instead of blaming the runtimepath when everything added was rejected', function()
    registry.add('lua', { { prefix = 'tr', body = '${1/(.*)/$1/}' } })
    local report = check()
    assert.is_true(mentions(report.warn, '1 body/bodies found and dropped'))
    assert.is_false(mentions(report.warn, 'No snippets found'))
  end)

  -- The registry.add() case above bumps dropped_added at add time, with no
  -- ordering dependency on available(). This is the path that actually
  -- regressed: dropped_parsed is only filled inside parse(), which
  -- available() is what forces.
  it('names dropped bodies for a pack discovered through the runtimepath too', function()
    local dir = helpers.vscode_pack({ lua = { tr = { prefix = 'tr', body = '${1/(.*)/$1/}' } } })
    helpers.use_rtp(dir)
    require('zsnip.loaders.from_vscode').lazy_load()

    local report = check()
    assert.is_true(mentions(report.warn, '1 body/bodies found and dropped'))
    assert.is_false(mentions(report.warn, 'No snippets found'))
  end)

  it('counts what was found', function()
    registry.add('lua', { { prefix = 'a', body = 'b' }, { prefix = 'c', body = 'b' } })
    assert.is_true(mentions(check().ok, '2 snippet%(s%) across 1 filetype%(s%)'))
  end)

  -- :checkhealth runs every check from inside its own freshly created,
  -- filetype-less buffer, so vim.bo.filetype is always '' by the time
  -- health.check() runs -- the alternate buffer is the one the user actually
  -- had open before running :checkhealth.
  it('reports the filetype of the buffer the user came from, not the scratch one checkhealth runs in', function()
    registry.add('lua', { { prefix = 'a', body = 'b' } })
    local origin = vim.api.nvim_create_buf(false, true)
    vim.bo[origin].filetype = 'lua'
    vim.api.nvim_set_current_buf(origin)

    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(scratch)
    assert.are.equal('', vim.bo[scratch].filetype)

    assert.is_true(mentions(check().info, 'buffer you came from %(lua%): 1 snippet%(s%)'))

    vim.api.nvim_buf_delete(scratch, { force = true })
    vim.api.nvim_buf_delete(origin, { force = true })
  end)

  -- Which of the four mutually exclusive delivery paths is running is the
  -- other half of "why do I see no snippets", and nothing else reports it.
  it('says whether the LSP server is serving them', function()
    assert.is_true(mentions(check().info, 'No source detected'))

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].filetype = 'lua'
    helpers.start_lsp()
    assert.is_true(mentions(check().ok, 'serving: the in%-process LSP server'))

    helpers.stop_lsp()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('sees the complete source too', function()
    require('zsnip.complete').enable()
    assert.is_true(mentions(check().ok, "serving: zsnip%.complete"))

    require('zsnip.complete').disable()
  end)

  -- The docs say to pick one; nothing checked that you had.
  it('warns when two sources are serving at once', function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].filetype = 'lua'
    helpers.start_lsp()
    require('zsnip.complete').enable()

    assert.is_true(mentions(check().warn, 'Two sources are serving'))

    require('zsnip.complete').disable()
    helpers.stop_lsp()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  -- Registered is not the same as serving: `started()` stays true across a
  -- :LspStop, so reporting it as "the menus can see the snippets" would be a
  -- clean bill of health for a server that is gone.
  it('does not call a stopped server healthy', function()
    -- A buffer with a filetype for the server to attach to: without one there
    -- is no client to stop, and the test would be measuring nothing.
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].filetype = 'lua'
    helpers.start_lsp()
    helpers.stop_lsp_clients()

    assert.is_true(mentions(check().warn, 'no client is running'))
    helpers.stop_lsp()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
