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

---@param opts? zsnip.Config
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(DEFAULTS), opts or {})
end

function M.reset()
  M.options = vim.deepcopy(DEFAULTS)
end

return M
