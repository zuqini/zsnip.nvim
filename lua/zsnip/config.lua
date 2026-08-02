---Resolved `setup()` options. Every default is usable on its own, so nothing
---in zsnip requires setup() to have run.

local M = {}

---@type zsnip.Config
local DEFAULTS = {
  extend = {},
  global_filetype = 'all',
  max_items = 100,
  documentation = true,
  command = true,
}

---@type zsnip.Config
M.options = vim.deepcopy(DEFAULTS)

---Bumped whenever `options` is replaced. `extend` and `global_filetype` are
---baked into the registry's per-filetype cache, so it has to notice a late
---setup() and drop what it resolved under the old options. A counter rather
---than a callback keeps the dependency pointing one way: config knows nothing
---about who reads it.
---@type integer
M.generation = 0

---@param opts? zsnip.Config
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(DEFAULTS), opts or {})
  M.generation = M.generation + 1
end

---Restore the defaults. Used by tests.
function M.reset()
  M.options = vim.deepcopy(DEFAULTS)
  M.generation = M.generation + 1
end

return M
