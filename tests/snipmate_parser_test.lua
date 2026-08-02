local helpers = require('helpers')
local snipmate = require('zsnip.parsers.snipmate')

after_each(helpers.cleanup)

---@param contents string
---@return string path
local function snippets_file(contents)
  local path = helpers.tempdir() .. '/lua.snippets'
  helpers.write(path, contents)
  return path
end

describe('snipmate.parse', function()
  it('reads a trigger, its description and its body', function()
    local snippets = snipmate.parse(snippets_file(table.concat({
      '# a comment',
      'snippet div A div element',
      '\t<div>',
      '\t\t$1',
      '\t</div>',
    }, '\n')))

    assert.are.equal(1, #snippets)
    assert.are.equal('div', snippets[1].prefix)
    assert.are.equal('A div element', snippets[1].description)
    assert.are.equal('<div>\n\t$1\n</div>', snippets[1].body)
  end)

  it('measures indentation against the first body line', function()
    local snippets = snipmate.parse(snippets_file(table.concat({
      'snippet spaced',
      '  first',
      '    nested',
    }, '\n')))
    assert.are.equal('first\n  nested', snippets[1].body)
  end)

  it('keeps blank lines inside a body and drops the ones between entries', function()
    local snippets = snipmate.parse(snippets_file(table.concat({
      'snippet one',
      '\ta',
      '',
      '\tb',
      '',
      'snippet two',
      '\tc',
      '',
    }, '\n')))

    assert.are.equal('a\n\nb', snippets[1].body)
    assert.are.equal('c', snippets[2].body)
  end)

  it('unescapes the quotes snipmate escapes and nothing else', function()
    local snippets = snipmate.parse(snippets_file(table.concat({
      'snippet thr',
      '\tthrow \\"$1\\" `x` \\d+ \\\\path',
    }, '\n')))
    assert.are.equal('throw "$1" `x` \\d+ \\\\path', snippets[1].body)
  end)

  it('reads extends directives', function()
    local _, extends = snipmate.parse(snippets_file(table.concat({
      'extends html, javascript',
      'snippet a',
      '\tb',
    }, '\n')))
    assert.are.same({ 'html', 'javascript' }, extends)
  end)

  it('ends a body at the next unindented line', function()
    local snippets = snipmate.parse(snippets_file(table.concat({
      'snippet a',
      '\tbody',
      '# trailing comment',
      'snippet b',
      '\tother',
    }, '\n')))
    assert.are.equal('body', snippets[1].body)
    assert.are.same({ 'a', 'b' }, helpers.prefixes(snippets))
  end)

  it('returns nothing for a file that is not there', function()
    local snippets, extends = snipmate.parse('/nowhere/at/all.snippets')
    assert.are.same({}, snippets)
    assert.are.same({}, extends)
  end)

  it('drops a trigger with no body', function()
    assert.are.same({}, snipmate.parse(snippets_file('snippet empty')))
  end)
end)
