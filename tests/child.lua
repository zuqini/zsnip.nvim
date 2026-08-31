---Driving a real Neovim through real keystrokes, from the test suite.
---
---`nvim -l` has no main loop, so `nvim_feedkeys(..., 'n')` queues keys nothing
---ever reads, and the 'x' flag runs them in a nested exec where textlock
---forbids a direct |complete()| call. A single menu can still be driven
---in-process through the expression register (`in_insert()` in
---complete_test.lua); what needs a child Neovim started with `-c` is the main
---loop itself -- 'autocomplete' timers, a menu that lives across turns.
---
---The child runs a fragment that calls `emit(key, value)` and then `done()`.
---Whatever it emitted comes back here as a table.

local M = {}

---Injected above the fragment. `press` is the shape every case here needs: put
---the buffer in a known state, type something, let the menu settle, accept.
local PRELUDE = [[
vim.opt.runtimepath:prepend(%q)
local OUT = %q
local results = {}
local finished = false

local function emit(key, value)
  results[key] = value
end

local function done()
  if finished then return end
  finished = true
  vim.fn.writefile({ vim.json.encode(results) }, OUT)
  vim.cmd('qa!')
end

-- A child that hangs would hang the suite; this is the backstop.
vim.defer_fn(done, 20000)

local function lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

---Type `text`, ask for completion with `invoke`, accept the first match, and
---hand the resulting buffer to `callback`. Each step is a deferred turn of the
---main loop because that is what the menu needs to exist at all.
local function press(text, invoke, callback)
  vim.snippet.stop()
  vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'n', false)
  vim.defer_fn(function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '' })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode('i' .. text .. invoke), 'n', false)
    vim.defer_fn(function()
      local offered = {}
      for _, item in ipairs(vim.fn.complete_info({ 'items' }).items or {}) do
        offered[#offered + 1] = item.word
      end
      vim.api.nvim_feedkeys(vim.keycode('<C-n><C-y><Esc>'), 'n', false)
      vim.defer_fn(function()
        callback({ offered = offered, lines = lines() })
      end, 250)
    end, 400)
  end, 100)
end

---Run `cases` one after another, emitting each under its own key.
local function each(cases, invoke, after)
  local index = 0
  local function next_case()
    index = index + 1
    if index > #cases then return after() end
    press(cases[index], invoke, function(result)
      emit(cases[index], result)
      next_case()
    end)
  end
  vim.defer_fn(next_case, 300)
end
]]

---@param fragment string Lua source; must call `done()` when it is finished
---@param root string Repository root, prepended to the child's runtimepath
---@param tempdir string Somewhere to leave the script and its output
---@return table results
---@return string log Whatever the child wrote to stderr
function M.run(fragment, root, tempdir)
  local script = tempdir .. '/child_script.lua'
  local out = tempdir .. '/child_out.json'
  vim.fn.writefile(vim.split(PRELUDE:format(root, out) .. fragment, '\n'), script)

  local result = vim
    .system({ vim.v.progpath, '--headless', '-u', 'NONE', '-c', 'luafile ' .. script }, {
      text = true,
      timeout = 60000,
    })
    :wait()

  local written = vim.fn.filereadable(out) == 1 and vim.fn.readfile(out)[1] or nil
  if not written then
    return {}, (result.stderr or '') .. (result.stdout or '')
  end
  local ok, decoded = pcall(vim.json.decode, written)
  return ok and decoded or {}, result.stderr or ''
end

return M
