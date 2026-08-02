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

---@param path string
---@return table?
function M.read_json(path)
  local lines = M.read_lines(path)
  if not lines then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(lines, '\n'), { luanil = { object = true } })
  return (ok and type(decoded) == 'table') and decoded or nil
end

---A body or description as one string. Non-string elements are dropped rather
---than concatenated: JSON arrays come from other people's packs, and a `null`
---(userdata, once decoded) or a nested object raises out of table.concat --
---which would take down every snippet for that filetype, from inside whatever
---asked for them.
---@param value string|string[]|nil
---@return string?
function M.joined(value)
  if type(value) == 'table' then
    local strings = {}
    for _, element in ipairs(value) do
      if type(element) == 'string' then
        strings[#strings + 1] = element
      elseif type(element) == 'number' then
        strings[#strings + 1] = tostring(element)
      end
    end
    return table.concat(strings, '\n')
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
