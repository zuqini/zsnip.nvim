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

  -- Two definitions sharing a prefix used to order by pairs()'s iteration
  -- order, which is unstable across starts -- and decides which one
  -- matches() prefers.
  it('breaks a tie on prefix using the definition name', function()
    local snippets = vscode.parse(snippet_file({
      zzz = { prefix = 'dup', body = 'z' },
      aaa = { prefix = 'dup', body = 'a' },
    }))
    assert.are.same({ 'a', 'z' }, vim.tbl_map(function(snippet)
      return snippet.body
    end, snippets))
  end)

  -- Same contract as snipmate.parse(): (path, language?) -> snippets, extends.
  -- VSCode packs have no inheritance directive of their own.
  it('returns an empty extends list', function()
    local _, extends = vscode.parse(snippet_file({ a = { prefix = 'a', body = 'b' } }))
    assert.are.same({}, extends)
  end)

  it('drops a scope that excludes the language asked about', function()
    local path = snippet_file({ a = { scope = 'lua', prefix = 'a', body = 'b' } })
    assert.are.same({}, vscode.parse(path, 'python'))
    assert.are.same({ 'a' }, helpers.prefixes(vscode.parse(path, 'lua')))
  end)

  -- The parser is a pure scope matcher: `all` is not a language it treats
  -- specially. registry.lua is the one that knows a pack spells "every
  -- filetype" as the literal language `all` and asks for it by that name.
  it('treats a scope naming all like any other language name', function()
    local path = snippet_file({ a = { scope = 'all', prefix = 'a', body = 'b' } })
    assert.are.same({ 'a' }, helpers.prefixes(vscode.parse(path, 'all')))
    assert.are.same({}, vscode.parse(path, 'lua'))
  end)

  it('keeps a scope naming a language and all together only when one of those is asked for', function()
    local path = snippet_file({ a = { scope = 'lua, all', prefix = 'a', body = 'b' } })
    assert.are.same({ 'a' }, helpers.prefixes(vscode.parse(path, 'lua')))
    assert.are.same({ 'a' }, helpers.prefixes(vscode.parse(path, 'all')))
    assert.are.same({}, vscode.parse(path, 'python'))
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

  -- The JSON is well-formed; the values in it are not. table.concat raises on
  -- a decoded null, a nested object or a boolean, and nothing upstream catches
  -- it -- so one bad entry would take down every snippet for that filetype,
  -- from inside whatever asked for them.
  it('drops junk inside a body array instead of raising', function()
    local dir = helpers.vscode_raw_pack(
      'lua',
      [[{
        "good":   { "prefix": "good",   "body": ["a", "b"] },
        "null":   { "prefix": "null",   "body": ["a", null, "b"] },
        "nested": { "prefix": "nested", "body": ["a", { "k": 1 }] },
        "bool":   { "prefix": "bool",   "body": ["a", true] },
        "number": { "prefix": "number", "body": ["a", 2] },
        "desc":   { "prefix": "desc",   "body": "x", "description": [null] }
      }]]
    )
    local snippets = vscode.parse(dir .. '/snippets/lua.json')
    local bodies = {}
    for _, snippet in ipairs(snippets) do
      bodies[snippet.prefix] = snippet.body
    end

    assert.are.equal('a\nb', bodies.good)
    assert.are.equal('a\nb', bodies['null'])
    assert.are.equal('a', bodies.nested)
    assert.are.equal('a', bodies.bool)
    assert.are.equal('a\n2', bodies.number)
    assert.are.equal('x', bodies.desc)
  end)

  it('ignores every plugin package.json that is not a snippet pack', function()
    assert.are.same({}, vscode.contributions(package_json({ name = 'some-plugin' })))
    assert.are.same({}, vscode.contributions(package_json({ contributes = { snippets = 'x' } })))
    assert.are.same({}, vscode.contributions(package_json({ contributes = { snippets = { { path = 1 } } } })))
    assert.are.same({}, vscode.contributions('/nowhere/package.json'))
  end)
end)

describe('the VSCode parser on files as VSCode writes them', function()
  ---@param json string
  ---@return string path
  local function raw_file(json)
    local path = helpers.tempdir() .. '/snippets.json'
    helpers.write(path, json)
    return path
  end

  -- VSCode *generates* every user snippet file with this comment block, and
  -- most people leave it. vim.json.decode refuses the file outright, so
  -- pointing `paths` at ~/.config/Code/User/snippets used to read nothing --
  -- and say nothing about why.
  it('reads a file with line comments', function()
    local snippets = vscode.parse(raw_file([[
{
  // Place your snippets for lua here. Each snippet is defined under
  // a snippet name and has a "prefix" and a "body".
  "Print": { "prefix": "log", "body": "print($1)" }
}]]))

    assert.are.equal(1, #snippets)
    assert.are.equal('log', snippets[1].prefix)
  end)

  it('reads a file with block comments and a trailing comma', function()
    local snippets = vscode.parse(raw_file([[
{
  /* a header
     over two lines */
  "Print": { "prefix": "log", "body": "print($1)" },
}]]))

    assert.are.equal(1, #snippets)
    assert.are.equal('log', snippets[1].prefix)
  end)

  -- A body is far more likely to hold `//` than the file is to hold a comment.
  it('leaves a comment marker inside a string alone', function()
    local snippets = vscode.parse(raw_file([[
{
  // real comment
  "Url": { "prefix": "url", "body": "https://example.com/*$1*/" },
}]]))

    assert.are.equal(1, #snippets)
    assert.are.equal('https://example.com/*$1*/', snippets[1].body)
  end)

  it('still refuses a file that is not JSON at all', function()
    assert.are.same({}, vscode.parse(raw_file('this is not json')))
  end)

  -- The comma-before-bracket rewrite used to run over the whole file,
  -- including string contents -- so a body written as `{ $1, }` decoded with
  -- its trailing comma silently gone.
  it('leaves a trailing comma inside a body string untouched', function()
    local snippets = vscode.parse(raw_file([[
{
  // Place your snippets for lua here.
  "Loop": { "prefix": "loop", "body": "local t = { $1, }" },
}]]))

    assert.are.equal(1, #snippets)
    assert.are.equal('local t = { $1, }', snippets[1].body)
  end)
end)
