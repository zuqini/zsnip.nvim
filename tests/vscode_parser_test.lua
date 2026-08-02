local helpers = require('helpers')
local vscode = require('zsnip.parsers.vscode')

after_each(helpers.cleanup)

---@param definitions table
---@return string path
local function snippet_file(definitions)
  local path = helpers.tempdir() .. '/snippets.json'
  helpers.write(path, vim.json.encode(definitions))
  return path
end

describe('vscode.parse', function()
  it('reads prefix, body and description', function()
    local snippets = vscode.parse(snippet_file({
      ['A function'] = { prefix = 'fn', body = 'function $1() end', description = 'a function' },
    }))

    assert.are.equal(1, #snippets)
    assert.are.equal('fn', snippets[1].prefix)
    assert.are.equal('function $1() end', snippets[1].body)
    assert.are.equal('a function', snippets[1].description)
  end)

  it('joins a body given as lines', function()
    local snippets = vscode.parse(snippet_file({ a = { prefix = 'a', body = { 'one', 'two' } } }))
    assert.are.equal('one\ntwo', snippets[1].body)
  end)

  it('expands a prefix list into one snippet per trigger', function()
    local snippets = vscode.parse(snippet_file({ a = { prefix = { 'x', 'y' }, body = 'b' } }))
    assert.are.same({ 'x', 'y' }, helpers.prefixes(snippets))
  end)

  it('falls back to the definition name when there is no prefix', function()
    local snippets = vscode.parse(snippet_file({ named = { body = 'b' } }))
    assert.are.same({ 'named' }, helpers.prefixes(snippets))
  end)

  it('survives entries of the wrong shape', function()
    local snippets = vscode.parse(snippet_file({
      good = { prefix = 'good', body = 'b' },
      bodyless = { prefix = 'x' },
      scalar = 'not a table',
    }))
    assert.are.same({ 'good' }, helpers.prefixes(snippets))
  end)

  it('returns nothing for a file that is not there or not JSON', function()
    assert.are.same({}, vscode.parse('/nowhere/at/all.json'))

    local path = helpers.tempdir() .. '/broken.json'
    helpers.write(path, '{ not json')
    assert.are.same({}, vscode.parse(path))
  end)

  it('orders triggers so the same pack yields the same menu', function()
    local snippets = vscode.parse(snippet_file({
      z = { prefix = 'z', body = 'b' },
      a = { prefix = 'a', body = 'b' },
      m = { prefix = 'm', body = 'b' },
    }))
    assert.are.same({ 'a', 'm', 'z' }, helpers.prefixes(snippets))
  end)
end)

describe('vscode.contributions', function()
  ---@param manifest table
  ---@return string path
  local function package_json(manifest)
    local path = helpers.tempdir() .. '/package.json'
    helpers.write(path, vim.json.encode(manifest))
    return path
  end

  it('resolves declared paths against the manifest directory', function()
    local path = package_json({
      contributes = { snippets = { { language = 'lua', path = './snippets/lua.json' } } },
    })
    local entries = vscode.contributions(path)

    assert.are.equal(1, #entries)
    assert.are.equal('lua', entries[1].language)
    assert.are.equal(vim.fs.normalize(vim.fs.dirname(path) .. '/snippets/lua.json'), entries[1].path)
  end)

  it('expands an entry covering several languages', function()
    local entries = vscode.contributions(package_json({
      contributes = { snippets = { { language = { 'javascript', 'typescript' }, path = 'x.json' } } },
    }))
    assert.are.same({ 'javascript', 'typescript' }, vim.tbl_map(function(entry)
      return entry.language
    end, entries))
  end)

  it('ignores every plugin package.json that is not a snippet pack', function()
    assert.are.same({}, vscode.contributions(package_json({ name = 'some-plugin' })))
    assert.are.same({}, vscode.contributions(package_json({ contributes = { snippets = 'x' } })))
    assert.are.same({}, vscode.contributions(package_json({ contributes = { snippets = { { path = 1 } } } })))
    assert.are.same({}, vscode.contributions('/nowhere/package.json'))
  end)
end)
