---snipmate `.snippets` files: '#' comments, `extends <filetype>` directives,
---`snippet <trigger> [description]` headers, and a body indented one level per
---line. The bodies are already LSP snippet syntax, so only the container needs
---reading. apple/pkl-neovim ships one of these and no package.json.

local util = require('zsnip.util')

local M = {}

---snipmate escapes a quote or a backtick that the LSP grammar has no meaning
---for, so `thr` would otherwise insert `throw \"message\"` verbatim. Only
---those two: the grammar passes any other stray backslash straight through
---(`\d+` parses to `\d+`), so a wider rule would eat the backslash out of a
---regex, a LaTeX macro or a Windows path.
---@param body string
---@return string
local function unescape(body)
  return (body:gsub('\\(["`])', '%1'))
end

---@param path string
---@return zsnip.Snippet[] snippets
---@return string[] extends Filetypes this file inherits from
function M.parse(path)
  local lines = util.read_lines(path)
  if not lines then
    return {}, {}
  end

  local snippets, extends = {}, {}
  local trigger, description, body, indent, blanks = nil, nil, {}, nil, 0

  local function flush()
    if trigger and #body > 0 then
      snippets[#snippets + 1] = {
        prefix = trigger,
        body = unescape(table.concat(body, '\n')),
        description = description,
      }
    end
    trigger, description, body, indent, blanks = nil, nil, {}, nil, 0
  end

  for _, line in ipairs(lines) do
    local next_trigger, next_description = line:match('^snippet%s+(%S+)%s*(.-)%s*$')
    local inherited = line:match('^extends%s+(.-)%s*$')
    if next_trigger then
      flush()
      trigger = next_trigger
      description = next_description ~= '' and next_description or nil
    elseif inherited then
      flush()
      for _, filetype in ipairs(vim.split(inherited, '%s*,%s*')) do
        if filetype ~= '' then
          extends[#extends + 1] = filetype
        end
      end
    elseif trigger and line:match('^[\t ]') then
      -- The first body line sets the indent the rest is measured against, so
      -- a space-indented file works and deeper nesting keeps its own indent.
      indent = indent or line:match('^[\t ]+')
      -- Held back until a body line follows: blank lines *between* entries
      -- are just spacing, blank lines inside one are part of the snippet.
      for _ = 1, blanks do
        body[#body + 1] = ''
      end
      blanks = 0
      body[#body + 1] = vim.startswith(line, indent) and line:sub(#indent + 1) or line
    elseif line:match('^%s*$') then
      blanks = blanks + 1
    else
      -- A comment or anything else unindented ends the body.
      flush()
    end
  end
  flush()

  return snippets, extends
end

return M
