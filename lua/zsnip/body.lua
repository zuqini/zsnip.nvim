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

---Parsing is not the whole test: |vim.snippet.expand()| asserts on two shapes
---the grammar accepts happily, and an assert is as fatal as a parse error at
---the point it fires. Both are decided by walking the top-level children the
---same way expand() does.
---
---  - more than one `$0`: the exit point has to be unambiguous;
---  - two placeholders that disagree about what tabstop N holds --
---    `${1:foo} ${1:bar}` -- because expand() has one value per tabstop.
---@param parsed table Root node from `grammar.parse`
---@return boolean
local function well_formed(parsed)
  local placeholders, exits = {}, 0
  for _, child in ipairs(parsed.data.children) do
    local data = child.data
    if child.type == grammar.NodeType.Placeholder then
      local value = tostring(data.value)
      if placeholders[data.tabstop] and placeholders[data.tabstop] ~= value then
        return false
      end
      placeholders[data.tabstop] = value
    end
    -- Text and variable nodes have no tabstop; the rest all reserve one.
    if data.tabstop == 0 then
      exits = exits + 1
      if exits > 1 then
        return false
      end
    end
  end
  return true
end

---Whether |vim.snippet.expand()| accepts this body. ~4% of friendly-snippets'
---bodies do not parse, and they are cheaper to drop at load time than to fail
---on at accept time -- where the completion engine has already deleted the
---typed word, so the raised error takes the word with it.
---@param body string
---@return boolean
function M.accepted(body)
  if not has_grammar then
    return true
  end
  local ok, parsed = pcall(grammar.parse, body)
  return ok and well_formed(parsed)
end

---Whether the grammar is available to validate a body against, so
---`:checkhealth zsnip` can report the same thing this module decided on.
---@type boolean
M.validates = has_grammar

---|vim.snippet.expand()| splits on `\n` only, so a `\r` left in by a source
---that writes CRLF or classic-Mac line endings -- a JSON pack, a Windows
---clipboard -- lands as a literal control byte in the buffer rather than a
---line break. The one rule both a raw body and a resolved variable value
---have to go through before either reaches the engine.
---@param text string
---@return string
local function normalize_eol(text)
  return (text:gsub('\r\n', '\n'):gsub('\r', '\n'))
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
---@return string? nil for a name zsnip does not know, left as written by the
---caller; '' for a known name this buffer cannot answer, because an
---unresolved variable reaches |vim.snippet.expand()| as a tabstop holding
---its own name.
local function variable(name)
  local format = DATE_FORMAT[name]
  if format then
    return tostring(os.date(format))
  elseif name == 'CURRENT_SECONDS_UNIX' then
    return tostring(os.time())
  elseif name == 'CURRENT_TIMEZONE_OFFSET' then
    -- os.date gives '+0100'; VSCode's variable is '+01:00'. A result that
    -- does not match (a bare 'Z', or an empty string on a platform without
    -- %z) is returned as-is rather than mangled.
    return (tostring(os.date('%z')):gsub('^([%+%-]%d%d)(%d%d)$', '%1:%2'))
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
    -- getreg's list form only splits on '\n', so a Windows copy leaves '\r'
    -- at the end of every line but the last.
    return normalize_eol(table.concat(vim.fn.getreg('+', 1, true), '\n'))
  elseif name == 'WORKSPACE_FOLDER' then
    return vim.fn.getcwd()
  elseif name == 'WORKSPACE_NAME' then
    return vim.fn.fnamemodify(vim.fn.getcwd(), ':t')
  elseif name == 'RELATIVE_FILEPATH' then
    return vim.fn.expand('%:.') --[[@as string]]
  elseif name == 'LINE_COMMENT' then
    return (comment_parts()) or ''
  elseif name == 'BLOCK_COMMENT_START' or name == 'BLOCK_COMMENT_END' then
    local left, right = comment_parts()
    -- 'commentstring' only describes a block comment when it wraps.
    if right == nil or right == '' then
      return ''
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

---@param name string
---@return string?
local function value_of(name)
  if VOLATILE[name] then
    return variable(name)
  end
  local value = shared[name]
  if value == nil then
    -- `false`, not nil: an unknown name has to stay a hit, or every `$NAME`
    -- that is plain text is looked up again for every snippet.
    value = variable(name) or false
    shared[name] = value
  end
  return value or nil
end

---The result is re-parsed as snippet text, so a '$' or '}' out of a clipboard
---has to stop being syntax.
---@param value string
---@return string
local function escape(value)
  return (value:gsub('[\\%$}]', '\\%0'))
end

---Text that must survive |vim.snippet.expand()| verbatim. Same escape as a
---resolved variable, for the same reason: buffer text placed in front of a
---body -- the `(` of a `(req` -- is parsed as part of it.
---@param value string
---@return string
function M.literal(value)
  return escape(value)
end

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
  local value = value_of(name)
  return value and escape(value)
end

---Index just past the `}` closing the `{` at `from`, or nil if it never
---closes. Counted rather than matched: a default can hold braces of its own,
---and a `\}` inside one is text.
---@param text string
---@param from integer Index of the `{`
---@return integer?
local function closes_at(text, from)
  local depth, index = 0, from
  while index <= #text do
    local char = text:sub(index, index)
    if char == '\\' then
      index = index + 1
    elseif char == '{' then
      depth = depth + 1
    elseif char == '}' then
      depth = depth - 1
      if depth == 0 then
        return index + 1
      end
    end
    index = index + 1
  end
  return nil
end

---`${VAR:default}` and `${VAR/regex/format/}` -- the two forms whose contents
---have to be found rather than matched, so they are scanned rather than
---gsub'd. Only bodies that hold one pay for the scan; the `find` below is the
---whole cost for the rest.
---
---Both collapse to the plain value. The default is dropped because we have one
---(and |vim.snippet.expand()| would discard it too -- for an unknown name it
---inserts the *name*, not the default). The transform is dropped because
---Neovim implements none: `${TM_FILENAME/(.*)%..*/$1/}` already inserts the
---whole filename today, so a resolved variable behaves the same way.
---@param body string
---@return string
local function resolve_delimited(body)
  local out, index = {}, 1
  while true do
    local at = body:find('%${[A-Z_][A-Z_0-9]*[:/]', index)
    if not at then
      break
    end
    local name = body:match('^%${([A-Z_][A-Z_0-9]*)', at)
    local stop = not escaped(body, at) and closes_at(body, at + 1) or nil
    local value = stop and value_of(name) or nil
    if stop and value then
      out[#out + 1] = body:sub(index, at - 1)
      out[#out + 1] = escape(value)
      index = stop
    else
      -- Past the `$` only: a name we do not know may still contain one we do.
      out[#out + 1] = body:sub(index, at)
      index = at + 1
    end
  end
  if #out == 0 then
    return body
  end
  out[#out + 1] = body:sub(index)
  return table.concat(out)
end

---@param body string
---@return string
local function resolve(body)
  if not body:find('$', 1, true) then
    return body
  end
  body = resolve_delimited(body)
  subject = body
  body = body:gsub('()%${([A-Z_][A-Z_0-9]*)}', substitute)
  -- Each pass rewrote it, so the positions the next one reports are into a
  -- different string.
  subject = body
  -- The frontier keeps the match from stopping at the class's last uppercase
  -- letter: without it $CURRENT_YEARabc reads as $CURRENT_YEAR followed by
  -- literal text `abc`, where the grammar reads one variable, CURRENT_YEARabc.
  return (body:gsub('()%$([A-Z_][A-Z_0-9]*)%f[^%w_]', substitute))
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
  if not body:find('%${0[:|]') then
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

  -- `${0|choices|}` renumbers the same way `${0:default}` does: it is still a
  -- placeholder holding text, just one the engine restricts you to picking.
  return (body:gsub('()%${0([:|])', function(at, delim)
    -- `\${0:` is text the author escaped to keep verbatim, not a tabstop.
    if escaped(body, at) then
      return nil
    end
    return ('${%d%s'):format(last + 1, delim)
  end))
end

---Everything a raw body needs before |vim.snippet.expand()| may be handed it:
---renumber the final tabstop, then accept or reject. Nil is "unusable, drop
---it". The registry does this at load time for a written body and `text()`
---below at call time for a produced one; keeping the pair here is what stops
---the two paths guaranteeing different things.
---@param raw string
---@return string?
function M.normalize(raw)
  local text = M.editable_final_tabstop(normalize_eol(raw))
  return M.accepted(text) and text or nil
end

---resolve(), refusing a body that came back '' -- every variable it held
---answered with nothing, as $BLOCK_COMMENT_START does outside a block
---comment, or $CLIPBOARD with an empty clipboard -- the way M.normalize()
---already refuses an empty body at load time: |vim.snippet.expand()| raises
---on it. M.resolve() stays on the raw one; it is documented to return a string.
---@param body string
---@return string?
local function resolved(body)
  local out = resolve(body)
  return out ~= '' and out or nil
end

---@param snippet zsnip.Snippet
---@return string?
local function text(snippet)
  local raw = snippet.body
  if type(raw) == 'function' then
    local ok, produced = pcall(raw)
    if not ok or type(produced) ~= 'string' then
      return nil
    end
    local normalized = M.normalize(produced)
    return normalized and resolved(normalized) or nil
  end
  -- `filetype` is what the registry stamps on everything it hands out, and
  -- it already normalized a written body at load time. Without it -- a table
  -- built by hand and handed straight to expand_snippet() -- that never ran,
  -- so it has to happen here instead.
  if snippet.filetype == nil then
    local normalized = M.normalize(raw)
    return normalized and resolved(normalized) or nil
  end
  return resolved(raw)
end

---Turn a snippet's body into the text handed to |vim.snippet.expand()|.
---Returns nil when a function body declines to produce one, or when what it
---produced cannot be parsed -- and the same for a string body on a snippet
---the registry never stamped, which is otherwise the one path that skips
---normalization entirely.
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
