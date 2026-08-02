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

---Neither Neovim nor LuaJIT seeds `math.random`, so a UUID built from it is
---the same string on every start -- the one value that must never repeat.
---libuv's CSPRNG needs no seeding and leaves the global generator, which is
---the user's and not ours to reseed, alone.
---@param count integer
---@return integer[]
local function random_bytes(count)
  local ok, bytes = pcall(vim.uv.random, count)
  if not ok or type(bytes) ~= 'string' or #bytes < count then
    local fallback = {}
    for index = 1, count do
      fallback[index] = math.random(0, 255)
    end
    return fallback
  end
  return { bytes:byte(1, count) }
end

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

---Values whose whole point is to differ per use, so a batch must never share
---them: two snippets in one menu holding the same UUID defeats having one.
---Anything added to `variable()` below that must not repeat belongs here.
local VOLATILE = { RANDOM = true, RANDOM_HEX = true, UUID = true }

---@param name string
---@return string?
local function variable(name)
  local format = DATE_FORMAT[name]
  if format then
    return tostring(os.date(format))
  elseif name == 'CURRENT_SECONDS_UNIX' then
    return tostring(os.time())
  elseif name == 'RANDOM' then
    local bytes = random_bytes(3)
    return ('%06d'):format((bytes[1] * 65536 + bytes[2] * 256 + bytes[3]) % 1000000)
  elseif name == 'RANDOM_HEX' then
    local bytes = random_bytes(3)
    return ('%02x%02x%02x'):format(bytes[1], bytes[2], bytes[3])
  elseif name == 'UUID' then
    local bytes = random_bytes(16)
    bytes[7] = 0x40 + (bytes[7] % 0x10) -- version 4
    bytes[9] = 0x80 + (bytes[9] % 0x40) -- variant 1
    return ('%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x')
      :format(unpack(bytes))
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

---Only an *odd* run of backslashes escapes what follows: in `\\$FOO` the pair
---is an escaped backslash and the `$` is still syntax.
---
---Looked up behind a match rather than captured by one. Capturing the run
---needs a leading `(\\*)`, which makes the engine count backslashes at every
---position it scans -- ~20% slower over a filetype of bodies than the `(\\?)`
---it would replace, and that one is already wrong for an even run. A `()`
---position capture costs nothing until something actually matches.
---@param subject string
---@param at integer Position of the `$`
---@return boolean
local function escaped(subject, at)
  local index = at - 1
  while index >= 1 and subject:byte(index) == 92 do -- '\'
    index = index - 1
  end
  return (at - 1 - index) % 2 == 1
end

---Values already resolved, shared until an entry point below starts a new
---batch. An upvalue rather than something `substitute` closes over: it is
---handed to gsub twice per body, and allocating a closure there costs more
---than the sharing saves -- measurably, on a whole filetype of items.
---Resolution is synchronous and never re-enters, so one slot is enough. The
---worst a stray reset can do is make the next lookup miss.
---@type table<string, string|false>
local shared = {}

---The string the gsubs below are walking, so `substitute` can look behind a
---match without a closure over it. An upvalue for the same reason `shared` is.
---@type string
local subject = ''

---Returning nil leaves the whole match alone, which is what both an escaped
---`\${VAR}` and a name we do not know should do -- plenty of bodies contain
---things like LaTeX's `$C$` or a bare `$NAME` that are text, not variables.
---@param at integer
---@param name string
---@return string?
local function substitute(at, name)
  if escaped(subject, at) then
    return nil
  end

  local value
  if VOLATILE[name] then
    value = variable(name)
  else
    value = shared[name]
    if value == nil then
      -- `false`, not nil: an unknown name has to stay a hit, or every `$NAME`
      -- that is plain text is looked up again for every snippet.
      value = variable(name) or false
      shared[name] = value
    end
    value = value or nil
  end

  -- The result is re-parsed as snippet text, so a '$' or '}' out of a
  -- clipboard has to stop being syntax.
  return value and (value:gsub('[\\%$}]', '\\%0'))
end

---@param body string
---@return string
local function resolve(body)
  if not body:find('$', 1, true) then
    return body
  end
  subject = body
  body = body:gsub('()%${([A-Z_][A-Z_0-9]*)}', substitute)
  -- The first pass rewrote it, so the positions the second one reports are
  -- into a different string.
  subject = body
  return (body:gsub('()%$([A-Z_][A-Z_0-9]*)', substitute))
end

---Resolve the variables Neovim does not know about.
---
---Resolved per expansion rather than once at load: a body outlives the session
---it was read in, and a stale CURRENT_MINUTE is worse than no sharing.
---@param body string
---@return string
function M.resolve(body)
  shared = {}
  return resolve(body)
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

  local renumbered = ('${%d:'):format(last + 1)
  return (body:gsub('()%${0:', function(at)
    -- `\${0:` is text the author escaped to keep verbatim, not a tabstop.
    if escaped(body, at) then
      return nil
    end
    return renumbered
  end))
end

---@param snippet zsnip.Snippet
---@return string?
local function text(snippet)
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
  return resolve(body)
end

---Turn a snippet's body into the text handed to |vim.snippet.expand()|.
---Returns nil when a function body declines to produce one, or when what it
---produced cannot be parsed.
---@param snippet zsnip.Snippet
---@return string?
function M.text(snippet)
  shared = {}
  return text(snippet)
end

---Begin a batch and return the function that turns each of its snippets into
---text. The batch shares what it resolves, which is what a single keystroke
---turning a whole filetype into completion items needs: `$CLIPBOARD` is a
---round trip to the clipboard provider, and paying that per snippet puts tens
---of milliseconds on the UI thread.
---
---Call it again for the next batch rather than holding one across keystrokes:
---what a batch shares includes CURRENT_MINUTE.
---@return fun(snippet: zsnip.Snippet): string?
function M.batch()
  shared = {}
  return text
end

return M
