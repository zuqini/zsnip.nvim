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

  -- snipmate's header is `snippet trigger ["description"] [options]`; the
  -- quotes and the options word are syntax, not part of the description.
  it('strips the quotes and a trailing options word from a quoted description', function()
    local snippets = snipmate.parse(snippets_file(table.concat({
      'snippet fun "function" b',
      '\tfunction $1() end',
    }, '\n')))
    assert.are.equal('function', snippets[1].description)
  end)

  it('leaves an unquoted description as written', function()
    local snippets = snipmate.parse(snippets_file(table.concat({
      'snippet div A div element',
      '\t<div>$1</div>',
    }, '\n')))
    assert.are.equal('A div element', snippets[1].description)
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

describe('snipmate.parse on ${VISUAL}', function()
  -- honza/vim-snippets uses this throughout; left alone, the grammar treats
  -- an unknown variable as a tabstop holding its own name, so `${VISUAL}`
  -- would insert the literal word VISUAL instead of the selection.
  it('rewrites ${VISUAL} to the LSP variable for the selection', function()
    local snippets = snipmate.parse(snippets_file('snippet v\n\t${VISUAL}'))
    assert.are.equal('$TM_SELECTED_TEXT', snippets[1].body)
  end)

  it('rewrites bare $VISUAL the same way', function()
    local snippets = snipmate.parse(snippets_file('snippet v\n\t$VISUAL'))
    assert.are.equal('$TM_SELECTED_TEXT', snippets[1].body)
  end)

  it('keeps a default alongside the rewrite', function()
    local snippets = snipmate.parse(snippets_file('snippet v\n\t${VISUAL:fallback}'))
    assert.are.equal('${TM_SELECTED_TEXT:fallback}', snippets[1].body)
  end)

  it('leaves an escaped \\$VISUAL as literal text', function()
    local snippets = snipmate.parse(snippets_file('snippet v\n\t\\$VISUAL'))
    assert.are.equal('\\$VISUAL', snippets[1].body)
  end)

  -- '${VISUALX}' and '$VISUAL_x' are different variable names, not VISUAL
  -- with a default or a boundary -- neither should be touched.
  it('leaves ${VISUALX} alone -- a different variable, not a default', function()
    local snippets = snipmate.parse(snippets_file('snippet v\n\t${VISUALX}'))
    assert.are.equal('${VISUALX}', snippets[1].body)
  end)

  it('leaves $VISUAL_x alone -- a different variable, not a boundary', function()
    local snippets = snipmate.parse(snippets_file('snippet v\n\t$VISUAL_x'))
    assert.are.equal('$VISUAL_x', snippets[1].body)
  end)
end)

describe('the snipmate parser on blank lines', function()
  -- A blank line between the header and the body is how the format is often
  -- laid out. Counted as part of the snippet, it puts an empty line in front
  -- of every such expansion.
  it('ignores one between a header and its body', function()
    local snippets = snipmate.parse(snippets_file('snippet hi\n\n\tfoo\n\tbar'))

    assert.are.equal(1, #snippets)
    assert.are.equal('foo\nbar', snippets[1].body)
  end)

  it('keeps one inside a body', function()
    local snippets = snipmate.parse(snippets_file('snippet hi\n\tfoo\n\n\tbar'))

    assert.are.equal('foo\n\nbar', snippets[1].body)
  end)

  it('keeps blank lines between entries out of both', function()
    local snippets = snipmate.parse(snippets_file('snippet a\n\tone\n\n\nsnippet b\n\n\ttwo'))

    assert.are.equal(2, #snippets)
    assert.are.equal('one', snippets[1].body)
    assert.are.equal('two', snippets[2].body)
  end)

  -- A separator that is only a tab or spaces is ordinary in hand-edited
  -- files; it starts with '^[\t ]' the same as a body line does, so it must
  -- be recognised as blank before the indented-body branch ever sees it.
  it('treats a tab-only separator between entries the same as an empty one', function()
    local snippets = snipmate.parse(snippets_file('snippet a\n\tbody_a\n\t\nsnippet b\n\tbody_b'))

    assert.are.equal(2, #snippets)
    assert.are.equal('body_a', snippets[1].body)
    assert.are.equal('body_b', snippets[2].body)
  end)

  it('treats a whitespace-only interior blank line the same as an empty one', function()
    local snippets = snipmate.parse(snippets_file('snippet hi\n\tfoo\n \t\n\tbar'))

    assert.are.equal('foo\n\nbar', snippets[1].body)
  end)
end)
