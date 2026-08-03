---Filesystem helpers shared by the parsers.
---
---Every read is a pcall: the files come from other people's plugins, and a
---missing or malformed one must not take down the completion request that
---triggered the read.

local M = {}

---@param path string
---@return string[]?
function M.read_lines(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or nil
end

---Strip what JSON does not allow and VSCode's snippet files are full of:
---`//` and `/* */` comments, and a comma before a closing brace or bracket.
---VSCode *generates* every user snippet file with a comment block at the top,
---and most people leave it there -- so without this, pointing `paths` at
---`~/.config/Code/User/snippets` reads nothing and says nothing.
---
---String-aware, since a body is far more likely to contain `//` than the file
---is to contain a comment. Only run when a plain decode has already failed, so
---a well-formed pack never pays for it.
---@param text string
---@return string
local function strip_json_comments(text)
  local out, index, length = {}, 1, #text
  while index <= length do
    local char = text:sub(index, index)
    if char == '"' then
      local from = index
      index = index + 1
      while index <= length do
        local inner = text:sub(index, index)
        if inner == '\\' then
          index = index + 2
        elseif inner == '"' then
          index = index + 1
          break
        else
          index = index + 1
        end
      end
      out[#out + 1] = text:sub(from, index - 1)
    elseif char == '/' and text:sub(index + 1, index + 1) == '/' then
      index = (text:find('\n', index, true) or length + 1)
    elseif char == '/' and text:sub(index + 1, index + 1) == '*' then
      local stop = text:find('*/', index + 2, true)
      index = stop and stop + 2 or length + 1
    else
      out[#out + 1] = char
      index = index + 1
    end
  end
  -- Whitespace and newlines survived above, so a trailing comma is whatever
  -- sits between the comma and the bracket that closes it.
  return (table.concat(out):gsub(',(%s*[%]}])', '%1'))
end

---@param path string
---@return table?
function M.read_json(path)
  local lines = M.read_lines(path)
  if not lines then
    return nil
  end
  local text = table.concat(lines, '\n')
  local ok, decoded = pcall(vim.json.decode, text, { luanil = { object = true } })
  if not ok then
    ok, decoded = pcall(vim.json.decode, strip_json_comments(text), { luanil = { object = true } })
  end
  return (ok and type(decoded) == 'table') and decoded or nil
end

---A body or description as one string. Anything that is not a string or a
---number is dropped rather than concatenated: JSON arrays come from other
---people's packs, and a `null` (userdata, once decoded) or a nested object
---raises out of table.concat -- which would take down every snippet for that
---filetype, from inside whatever asked for them. An array that yields nothing
---usable is nil, not '': an empty body is a menu entry that inserts nothing.
---@param value string|number|(string|number)[]|nil
---@return string?
function M.joined(value)
  if type(value) == 'table' then
    local strings = {}
    for _, element in ipairs(value) do
      if type(element) == 'string' or type(element) == 'number' then
        strings[#strings + 1] = tostring(element)
      end
    end
    return #strings > 0 and table.concat(strings, '\n') or nil
  elseif type(value) == 'string' then
    return value
  end
  return nil
end

---@param value string|string[]|nil
---@return string[]
function M.list(value)
  if type(value) == 'table' then
    return value
  elseif value ~= nil then
    return { value }
  end
  return {}
end

return M
