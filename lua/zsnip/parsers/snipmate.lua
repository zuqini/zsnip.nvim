---snipmate `.snippets` files: '#' comments, `extends <filetype>` directives,
---`snippet <trigger> [description]` headers, and a body indented one level per
---line. The bodies are already LSP snippet syntax, save for `${VISUAL}` --
---snipmate's own name for the text an operator-pending expansion replaced,
---which the grammar has no variable by. apple/pkl-neovim ships one of these
---and no package.json.

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

---honza/vim-snippets writes the selected text as `${VISUAL}` or `$VISUAL`,
---snipmate's own name for it; the grammar has no variable by that name, so
---left alone it would expand as a tabstop holding its own name rather than
---the selection. Rewritten to the LSP variable that means the same thing --
---which resolves to '' outside a selection -- before the grammar ever sees
---it. A backslash in front marks it as literal, the same as the escapes
---above.
---@param body string
---@return string
local function visual(body)
  -- Two patterns, not one with an optional colon: `(:?[^}]-)` accepts a name
  -- continuation as a default, so `${VISUALX}` was read as `${VISUAL:X}` and
  -- rewritten out from under a snippet that meant an unrelated variable.
  body = body:gsub('(\\?)%$%{VISUAL%}', function(escaped)
    if escaped == '\\' then
      return nil
    end
    return '$TM_SELECTED_TEXT'
  end)
  body = body:gsub('(\\?)%$%{VISUAL(:[^}]*)%}', function(escaped, default)
    if escaped == '\\' then
      return nil
    end
    return '${TM_SELECTED_TEXT' .. default .. '}'
  end)
  -- %f[^%w_], not %f[%W]: Lua's %w does not include '_', so %f[%W] treats it
  -- as a boundary too and would cut $VISUAL out of $VISUAL_x, a different
  -- name entirely.
  return (body:gsub('(\\?)%$VISUAL%f[^%w_]', function(escaped)
    if escaped == '\\' then
      return nil
    end
    return '$TM_SELECTED_TEXT'
  end))
end

---A header is `snippet trigger ["description"] [options]`; the quotes and any
---trailing options word (`b`, `w`, ...) belong to snipmate's syntax, not the
---description itself. An unquoted description has no options to strip, so it
---passes through as written.
---@param raw string
---@return string?
local function clean_description(raw)
  if raw == '' then
    return nil
  end
  return (raw:match('^"(.-)"%s*%a*$')) or raw
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
        body = unescape(visual(table.concat(body, '\n'))),
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
      description = clean_description(next_description)
    elseif inherited then
      flush()
      for _, filetype in ipairs(vim.split(inherited, '%s*,%s*')) do
        if filetype ~= '' then
          extends[#extends + 1] = filetype
        end
      end
    elseif line:match('^%s*$') then
      -- Checked before the indented-body branch below: a separator line that
      -- is only a tab or spaces (ordinary in hand-edited files) still starts
      -- with `^[\t ]` and must not be read as a body line.
      --
      -- Only once a body is under way: a blank line between the header and
      -- the first body line is how the format is often laid out, and counting
      -- it would put an empty line in front of every such expansion.
      if #body > 0 then
        blanks = blanks + 1
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
    else
      -- A comment or anything else unindented ends the body.
      flush()
    end
  end
  flush()

  return snippets, extends
end

return M
