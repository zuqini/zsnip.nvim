---Making a snippet body safe for |vim.snippet.expand()|.
---
---Bodies from VSCode and snipmate packs are already LSP snippet syntax, so
---none of this is translation. It is the gap between what those packs assume
---an editor does and what Neovim's engine actually does:
---
---  - variables outside the TM_* set are unknown to the engine, and an
---    unknown variable becomes a *tabstop holding its own name* rather than a
---    value, which is why `copyright` inserts a literal CURRENT_YEAR;
---  - `${0:text}` is a placeholder on the exit point, and jumping to $0 ends
---    the session instead of selecting the text;
---  - a body the grammar cannot parse raises out of expand(), and
---    vim.lsp.completion deletes the typed word *before* expanding, so the
---    failure takes the word with it.

local M = {}

local has_grammar, grammar = pcall(require, 'vim.lsp._snippet_grammar')

---Whether |vim.snippet.expand()| can parse this body. ~4% of
---friendly-snippets' bodies cannot be, and they are cheaper to drop at load
---time than to fail on at accept time.
---@param body string
---@return boolean
function M.expandable(body)
  return not has_grammar or (pcall(grammar.parse, body))
end

local DATE_FORMAT = {
  CURRENT_YEAR = '%Y',
  CURRENT_YEAR_SHORT = '%y',
  CURRENT_MONTH = '%m',
  CURRENT_MONTH_NAME = '%B',
  CURRENT_MONTH_NAME_SHORT = '%b',
  CURRENT_DATE = '%d',
  CURRENT_DAY_NAME = '%A',
  CURRENT_DAY_NAME_SHORT = '%a',
  CURRENT_HOUR = '%H',
  CURRENT_MINUTE = '%M',
  CURRENT_SECOND = '%S',
  CURRENT_TIMEZONE_OFFSET = '%z',
}

---@return string?, string?
local function comment_parts()
  local commentstring = vim.bo.commentstring
  if commentstring == '' then
    return nil, nil
  end
  local left, right = commentstring:match('^(.-)%%s(.-)$')
  if not left then
    return nil, nil
  end
  return vim.trim(left), vim.trim(right)
end

---@param name string
---@return string?
local function variable(name)
  local format = DATE_FORMAT[name]
  if format then
    return tostring(os.date(format))
  elseif name == 'CURRENT_SECONDS_UNIX' then
    return tostring(os.time())
  elseif name == 'RANDOM' then
    return ('%06d'):format(math.random(0, 999999))
  elseif name == 'RANDOM_HEX' then
    return ('%06x'):format(math.random(0, 0xffffff))
  elseif name == 'UUID' then
    return (('xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'):gsub('[xy]', function(char)
      return ('%x'):format(char == 'x' and math.random(0, 15) or math.random(8, 11))
    end))
  elseif name == 'CLIPBOARD' then
    return table.concat(vim.fn.getreg('+', 1, true), '\n')
  elseif name == 'WORKSPACE_FOLDER' then
    return vim.fn.getcwd()
  elseif name == 'WORKSPACE_NAME' then
    return vim.fn.fnamemodify(vim.fn.getcwd(), ':t')
  elseif name == 'RELATIVE_FILEPATH' then
    return vim.fn.expand('%:.') --[[@as string]]
  elseif name == 'LINE_COMMENT' then
    return (comment_parts())
  elseif name == 'BLOCK_COMMENT_START' or name == 'BLOCK_COMMENT_END' then
    local left, right = comment_parts()
    -- 'commentstring' only describes a block comment when it wraps: a
    -- line-comment buffer has no answer here, and guessing one would emit a
    -- stray `--` where the pack expected `/*`.
    if right == nil or right == '' then
      return nil
    end
    return name == 'BLOCK_COMMENT_START' and left or right
  end
  return nil
end

---Returning nil leaves the whole match alone, which is what both an escaped
---`\${VAR}` and a name we do not know should do -- plenty of bodies contain
---things like LaTeX's `$C$` or a bare `$NAME` that are text, not variables.
---@param escape string
---@param name string
---@return string?
local function substitute(escape, name)
  if escape == '\\' then
    return nil
  end
  local value = variable(name)
  -- The result is re-parsed as snippet text, so a '$' or '}' out of a
  -- clipboard has to stop being syntax.
  return value and (value:gsub('[\\%$}]', '\\%0'))
end

---Resolve the variables Neovim does not know about.
---
---Called per expansion rather than once at load: a body outlives the session
---it was read in, and a stale CURRENT_MINUTE is worse than no caching.
---@param body string
---@return string
function M.resolve(body)
  if not body:find('$', 1, true) then
    return body
  end
  body = body:gsub('(\\?)%${([A-Z_][A-Z_0-9]*)}', substitute)
  return (body:gsub('(\\?)%$([A-Z_][A-Z_0-9]*)', substitute))
end

---Renumber `${0:text}` past the last real tabstop so its default lands in the
---buffer as something you can tab onto; Neovim re-adds the implicit $0 at the
---end of the snippet. Without this the text is inserted unreachable, and a
---body whose only tabstop is $0 gets no session at all.
---@param body string
---@return string
function M.editable_final_tabstop(body)
  if not body:find('${0:', 1, true) then
    return body
  end

  local last = 0
  for index in body:gmatch('%$(%d+)') do
    last = math.max(last, tonumber(index) or 0)
  end
  -- '/' catches ${N/regex/format/}, the one form that names a tabstop without
  -- ever writing it plainly.
  for index in body:gmatch('%${(%d+)[:|}/]') do
    last = math.max(last, tonumber(index) or 0)
  end

  return (body:gsub('%${0:', ('${%d:'):format(last + 1)))
end

---Turn a snippet's body into the text handed to |vim.snippet.expand()|.
---Returns nil when a function body declines to produce one, or when what it
---produced cannot be parsed.
---@param snippet zsnip.Snippet
---@return string?
function M.text(snippet)
  local body = snippet.body
  if type(body) == 'function' then
    local ok, produced = pcall(body)
    if not ok or type(produced) ~= 'string' then
      return nil
    end
    body = M.editable_final_tabstop(produced)
    if not M.expandable(body) then
      return nil
    end
  end
  return M.resolve(body)
end

return M
