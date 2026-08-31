---The shared filesystem seam: every read discovery and the parsers do goes
---through it.
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
  local chunks, buffer, index, length = {}, {}, 1, #text
  -- The comma rewrite below runs on `buffer` alone, not on a string token: a
  -- generated file's `//` header routes a user's `"body": "{ $1, }"` through
  -- here, and the naive version of this rewrote that trailing comma too.
  local function flush()
    if #buffer > 0 then
      chunks[#chunks + 1] = (table.concat(buffer):gsub(',(%s*[%]}])', '%1'))
      buffer = {}
    end
  end
  while index <= length do
    local char = text:sub(index, index)
    if char == '"' then
      flush()
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
      chunks[#chunks + 1] = text:sub(from, index - 1)
    elseif char == '/' and text:sub(index + 1, index + 1) == '/' then
      index = (text:find('\n', index, true) or length + 1)
    elseif char == '/' and text:sub(index + 1, index + 1) == '*' then
      local stop = text:find('*/', index + 2, true)
      index = stop and stop + 2 or length + 1
    else
      buffer[#buffer + 1] = char
      index = index + 1
    end
  end
  flush()
  return table.concat(chunks)
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

---The files under `dir` ending in `suffix`, with the subdirectory each was
---found in (nil at the top level) and its name without the suffix.
---
---`vim.fs.dir` rather than `vim.fn.glob`: a configured path is data, not a
---pattern, and a `[` anywhere in one makes glob() match nothing at all -- for
---that whole directory, silently. It is also the cheaper of the two.
---@param dir string
---@param suffix string
---@param depth integer 1 for the directory itself, 2 to include one level down
---@return { path: string, parent: string?, base: string }[]
function M.files(dir, suffix, depth)
  local found = {}
  local ok, iterator = pcall(vim.fs.dir, dir, { depth = depth, follow = true })
  if not ok then
    return found
  end
  for name, kind in iterator do
    local path = dir .. '/' .. name
    -- `vim.fs.dir` reports a symlink as 'link' rather than resolving it, even
    -- with follow = true -- that flag only decides whether it descends into
    -- one that points at a directory. A stow/dotfiles setup routes every
    -- snippet file through a symlink, so it has to be told apart from one.
    local is_file = kind == 'file' or (kind == 'link' and (vim.uv.fs_stat(path) or {}).type == 'file')
    if is_file and vim.endswith(name, suffix) then
      local parent, base = name:match('^(.*)/([^/]+)$')
      found[#found + 1] = {
        path = vim.fs.normalize(path),
        parent = parent,
        base = (base or name):sub(1, -#suffix - 1),
      }
    end
  end
  return found
end

return M
